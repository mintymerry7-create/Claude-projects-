import Foundation
import ChessCore

public enum MoveClassification: String, Codable, Hashable, Sendable, CaseIterable {
    case book, best, good, inaccuracy, mistake, blunder

    public var symbol: String {
        switch self {
        case .book: return "📖"
        case .best: return "★"
        case .good: return ""
        case .inaccuracy: return "?!"
        case .mistake: return "?"
        case .blunder: return "??"
        }
    }

    public var displayName: String { rawValue.capitalized }
}

public struct MoveAnalysis: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { ply }
    public let ply: Int
    public let move: Move
    public let san: String
    public let mover: PieceColor
    /// Evaluations from White's point of view.
    public let evalBefore: EngineScore
    public let evalAfter: EngineScore
    public let bestMove: Move?
    public let bestSAN: String?
    /// Engine's suggested continuation (SAN) from the position before the move.
    public let bestLine: [String]
    public let classification: MoveClassification
    /// Loss of winning chances for the mover, 0...2.
    public let winChanceLoss: Double
    public let comment: String
}

public struct GameAnalysis: Codable, Hashable, Sendable {
    public let moves: [MoveAnalysis]
    public let whiteAccuracy: Double
    public let blackAccuracy: Double
    public let engineName: String
    public let depth: Int

    public func count(_ c: MoveClassification, for color: PieceColor) -> Int {
        moves.filter { $0.mover == color && $0.classification == c }.count
    }

    /// The biggest mistakes, largest first.
    public var keyMoments: [MoveAnalysis] {
        moves.filter { [.mistake, .blunder].contains($0.classification) }
            .sorted { $0.winChanceLoss > $1.winChanceLoss }
    }
}

/// Reviews a finished game move by move with an engine.
public struct GameAnalyzer: Sendable {
    public let engine: ChessEngine
    public let depth: Int
    public let moveTimeMs: Int

    public init(engine: ChessEngine, depth: Int = 12, moveTimeMs: Int = 400) {
        self.engine = engine
        self.depth = depth
        self.moveTimeMs = moveTimeMs
    }

    /// - Parameters:
    ///   - bookPlies: plies at the start that came from opening theory and are labelled "book".
    ///   - progress: called with 0...1 as positions are evaluated.
    public func analyze(_ game: ChessGame, bookPlies: Int = 0,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> GameAnalysis {
        let positions = game.positions
        var evals: [(score: EngineScore, best: Move?, line: [Move])] = []
        for (i, pos) in positions.enumerated() {
            try Task.checkCancellation()
            if !pos.hasLegalMoves {
                // Terminal: mated side to move scores -mate 0; stalemate is 0.
                evals.append((pos.isCheck ? .mate(0) : .centipawns(0), nil, []))
            } else if pos.hasInsufficientMaterial {
                evals.append((.centipawns(0), nil, []))
            } else {
                let r = try await engine.search(SearchRequest(position: pos, limit: SearchLimit(depth: depth, moveTimeMs: moveTimeMs)))
                evals.append((r.score ?? .centipawns(0), r.bestMove, r.lines.first?.pv ?? [r.bestMove]))
            }
            progress?(Double(i + 1) / Double(positions.count))
        }

        var analyses: [MoveAnalysis] = []
        for ply in 0..<game.moves.count {
            let before = positions[ply]
            let mover = before.sideToMove
            let move = game.moves[ply]
            // Mover's point of view.
            let sBefore = evals[ply].score
            var sAfter = evals[ply + 1].score.negated
            if case .mate(0) = evals[ply + 1].score { sAfter = .mate(1) }
            let loss = max(0, sBefore.winningChances - sAfter.winningChances)
            let best = evals[ply].best
            let bestSAN = best.map { before.san(for: $0) }
            let classification: MoveClassification
            if ply < bookPlies {
                classification = .book
            } else if move == best {
                classification = .best
            } else if loss >= 0.3 {
                classification = .blunder
            } else if loss >= 0.2 {
                classification = .mistake
            } else if loss >= 0.1 {
                classification = .inaccuracy
            } else {
                classification = .good
            }
            let comment = Self.comment(classification: classification, before: sBefore, after: sAfter, bestSAN: bestSAN)
            analyses.append(MoveAnalysis(
                ply: ply, move: move, san: game.sanMoves[ply], mover: mover,
                evalBefore: sBefore.fromWhite(sideToMove: mover),
                evalAfter: sAfter.fromWhite(sideToMove: mover),
                bestMove: best, bestSAN: bestSAN,
                bestLine: Self.sanLine(evals[ply].line, from: before),
                classification: classification, winChanceLoss: loss, comment: comment))
        }

        return GameAnalysis(moves: analyses,
                            whiteAccuracy: Self.accuracy(analyses.filter { $0.mover == .white }),
                            blackAccuracy: Self.accuracy(analyses.filter { $0.mover == .black }),
                            engineName: engine.displayName, depth: depth)
    }

    static func comment(classification: MoveClassification, before: EngineScore, after: EngineScore, bestSAN: String?) -> String {
        let best = bestSAN.map { " \($0) was stronger." } ?? ""
        if case .mate(let m) = before, m > 0 {
            if case .mate(let n) = after, n > 0 { return classification == .best ? "Keeps the forced mate." : "Still mating, but slower." + best }
            return "Missed a forced mate in \(m)." + best
        }
        if case .mate(let n) = after, n < 0 { return "Allows a forced mate." + best }
        switch classification {
        case .book: return "Opening theory."
        case .best: return "The engine's top choice."
        case .good: return "A solid move."
        case .inaccuracy: return "Inaccuracy." + best
        case .mistake:
            return before.winningChances > 0.5 ? "Mistake — this lets the advantage slip." + best : "Mistake." + best
        case .blunder:
            return before.winningChances > 0.3 ? "Blunder — a winning position is thrown away." + best : "Blunder." + best
        }
    }

    static func sanLine(_ moves: [Move], from start: Position, limit: Int = 6) -> [String] {
        var p = start
        var out: [String] = []
        for m in moves.prefix(limit) {
            guard p.isLegal(m) else { break }
            out.append(p.san(for: m))
            p.make(m)
        }
        return out
    }

    /// Lichess-style move accuracy averaged over a player's moves.
    static func accuracy(_ moves: [MoveAnalysis]) -> Double {
        guard !moves.isEmpty else { return 100 }
        let values = moves.map { m -> Double in
            let lossPercent = m.winChanceLoss * 50
            return max(0, min(100, 103.1668 * exp(-0.04354 * lossPercent) - 3.1669))
        }
        return values.reduce(0, +) / Double(values.count)
    }
}
