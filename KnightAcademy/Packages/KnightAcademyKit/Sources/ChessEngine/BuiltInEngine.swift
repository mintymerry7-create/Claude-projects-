import Foundation
import ChessCore

/// A compact alpha-beta engine written in Swift. It is the offline fallback
/// when Stockfish is unavailable (e.g. NNUE files not installed) and powers
/// unit tests on every platform. It is a genuine search engine — iterative
/// deepening, quiescence search, MVV-LVA ordering and a tapered
/// piece-square-table evaluation — not a random mover. It is much weaker
/// than Stockfish.
public final class BuiltInEngine: ChessEngine, @unchecked Sendable {
    public let displayName = "Knight (built-in)"
    /// Hashes of positions already played in the current game, to avoid
    /// walking into repetitions when ahead.
    private let lock = NSLock()
    private var gameHistory: [UInt64] = []
    private var rng: RandomNumberGenerator

    public init(seed: UInt64? = nil) {
        rng = seed.map { SeededGenerator(seed: $0) as RandomNumberGenerator } ?? SystemRandomNumberGenerator()
    }

    private func locked<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func setHistory(_ positions: [Position]) {
        let hashes = positions.map(\.zobrist)
        locked { gameHistory = hashes }
    }

    public func newGame() async {
        locked { gameHistory = [] }
    }

    public func shutdown() async {}

    public func search(_ request: SearchRequest) async throws -> SearchResult {
        let legal = request.position.legalMoves()
        guard !legal.isEmpty else { throw EngineError.noLegalMoves }
        let history = locked { gameHistory }

        let skill = request.skillLevel.map { max(0, min(20, $0)) } ?? 20
        let maxDepth = min(request.limit.depth ?? 64, Self.depthCap(forSkill: skill))
        let timeMs = request.limit.moveTimeMs ?? (request.limit.depth == nil ? 1000 : 60_000)
        let deadline = Date().addingTimeInterval(Double(timeMs) / 1000)
        let multiPV = max(request.multiPV, skill < 20 ? 4 : 1)

        let result = try await Task.detached(priority: .userInitiated) {
            var searcher = Searcher(root: request.position, deadline: deadline, history: history)
            return try searcher.run(maxDepth: maxDepth, multiPV: multiPV)
        }.value

        var lines = result
        // Skill handicap: choose among near-best moves within a margin that
        // grows as skill decreases (similar in spirit to Stockfish's Skill Level).
        var best = lines[0].pv[0]
        if skill < 20, lines.count > 1 {
            let margin = Double(20 - skill) * 18
            let top = Double(lines[0].score.sortValue)
            let candidates = lines.filter { top - Double($0.score.sortValue) <= margin && abs($0.score.sortValue) < 90_000 }
            if candidates.count > 1 {
                let pick = locked { Int.random(in: 0..<candidates.count, using: &rng) }
                best = candidates[pick].pv[0]
                if let idx = lines.firstIndex(where: { $0.pv.first == best }), idx > 0 {
                    lines.swapAt(0, idx)
                }
            }
        }
        let trimmed = Array(lines.prefix(request.multiPV)).enumerated().map {
            EngineLine(pv: $0.element.pv, score: $0.element.score, depth: $0.element.depth, multipv: $0.offset + 1)
        }
        return SearchResult(bestMove: best, lines: trimmed)
    }

    static func depthCap(forSkill skill: Int) -> Int {
        let table = [1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 6, 6, 64]
        return table[max(0, min(20, skill))]
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Search

struct Searcher {
    static let mateScore = 100_000
    static let infinity = 1_000_000

    var root: Position
    let deadline: Date
    let history: [UInt64]
    var nodes = 0
    var stopped = false
    var pathHashes: [UInt64] = []
    var pvMoveAtRoot: Move?
    var killers: [[Move?]] = Array(repeating: [nil, nil], count: 128)

    init(root: Position, deadline: Date, history: [UInt64]) {
        self.root = root
        self.deadline = deadline
        self.history = history
    }

    /// Iterative deepening with a full window per root move so that several
    /// lines (multi-PV) are scored exactly.
    mutating func run(maxDepth: Int, multiPV: Int) throws -> [EngineLine] {
        var rootMoves = root.legalMoves()
        var completed: [EngineLine] = []
        var depth = 1
        while depth <= maxDepth {
            var scored: [(Move, Int, [Move])] = []
            var alpha = -Self.infinity
            var p = root
            for m in rootMoves {
                let u = p.make(m)
                pathHashes = [p.zobrist]
                var childPV: [Move] = []
                // Exact scores for the first `multiPV` moves, null-window-ish bound for the rest.
                let lower = scored.count < multiPV ? -Self.infinity : alpha
                let score = -negamax(&p, depth: depth - 1, alpha: -Self.infinity, beta: -lower, ply: 1, pv: &childPV)
                p.unmake(m, u)
                if stopped { break }
                scored.append((m, score, [m] + childPV))
                scored.sort { $0.1 > $1.1 }
                if scored.count >= multiPV { alpha = scored[multiPV - 1].1 }
            }
            if stopped && depth > 1 { break }
            scored.sort { $0.1 > $1.1 }
            completed = scored.map { EngineLine(pv: $0.2, score: Self.toEngineScore($0.1), depth: depth) }
            rootMoves = scored.map(\.0) + rootMoves.filter { m in !scored.contains { $0.0 == m } }
            if let top = scored.first, abs(top.1) >= Self.mateScore - 100 { break }
            if Date() >= deadline || stopped { break }
            depth += 1
        }
        if completed.isEmpty {
            completed = rootMoves.map { EngineLine(pv: [$0], score: .centipawns(0), depth: 0) }
        }
        return completed
    }

    static func toEngineScore(_ s: Int) -> EngineScore {
        if s >= mateScore - 1000 { return .mate((mateScore - s + 1) / 2) }
        if s <= -mateScore + 1000 { return .mate(-(mateScore + s) / 2) }
        return .centipawns(s)
    }

    mutating func checkTime() {
        if nodes & 1023 == 0, Date() >= deadline { stopped = true }
    }

    mutating func negamax(_ p: inout Position, depth: Int, alpha a: Int, beta: Int, ply: Int, pv: inout [Move]) -> Int {
        nodes += 1
        checkTime()
        if stopped { return 0 }
        var alpha = a

        let hash = pathHashes.last ?? p.zobrist
        if p.halfmoveClock >= 100 { return 0 }
        if pathHashes.dropLast().contains(hash) || history.contains(hash) { return 0 }

        let inCheck = p.isCheck
        if depth <= 0 && !inCheck { return quiescence(&p, alpha: alpha, beta: beta, ply: ply) }

        let moves = orderedMoves(p, ply: ply)
        var legalCount = 0
        let us = p.sideToMove
        var best = -Self.infinity
        for m in moves {
            let capture = p.isCapture(m)
            let u = p.make(m)
            if p.isKingAttacked(us) { p.unmake(m, u); continue }
            legalCount += 1
            pathHashes.append(p.zobrist)
            var childPV: [Move] = []
            let ext = inCheck ? 1 : 0
            let score = -negamax(&p, depth: depth - 1 + ext, alpha: -beta, beta: -alpha, ply: ply + 1, pv: &childPV)
            pathHashes.removeLast()
            p.unmake(m, u)
            if stopped { return 0 }
            if score > best {
                best = score
                if score > alpha {
                    alpha = score
                    pv = [m] + childPV
                    if alpha >= beta {
                        if !capture, ply < killers.count {
                            killers[ply][1] = killers[ply][0]
                            killers[ply][0] = m
                        }
                        break
                    }
                }
            }
        }
        if legalCount == 0 { return inCheck ? -Self.mateScore + ply : 0 }
        return best
    }

    mutating func quiescence(_ p: inout Position, alpha a: Int, beta: Int, ply: Int) -> Int {
        nodes += 1
        checkTime()
        if stopped { return 0 }
        var alpha = a
        let standPat = Evaluator.evaluate(p)
        if standPat >= beta { return standPat }
        if standPat > alpha { alpha = standPat }
        if ply > 40 { return standPat }
        let us = p.sideToMove
        let captures = p.pseudoLegalMoves().filter { p.isCapture($0) || $0.promotion == .queen }
            .sorted { mvvLva(p, $0) > mvvLva(p, $1) }
        for m in captures {
            let u = p.make(m)
            if p.isKingAttacked(us) { p.unmake(m, u); continue }
            let score = -quiescence(&p, alpha: -beta, beta: -alpha, ply: ply + 1)
            p.unmake(m, u)
            if stopped { return 0 }
            if score >= beta { return score }
            if score > alpha { alpha = score }
        }
        return alpha
    }

    func mvvLva(_ p: Position, _ m: Move) -> Int {
        let victim = p[m.to]?.kind.value ?? (p.isEnPassant(m) ? 1 : 0)
        let attacker = p[m.from]?.kind.value ?? 0
        return victim * 10 - attacker + (m.promotion == .queen ? 80 : 0)
    }

    func orderedMoves(_ p: Position, ply: Int) -> [Move] {
        let killerMoves = ply < killers.count ? killers[ply] : [nil, nil]
        return p.pseudoLegalMoves().map { m -> (Move, Int) in
            var s = 0
            if p.isCapture(m) { s = 10_000 + mvvLva(p, m) }
            else if m.promotion == .queen { s = 9_000 }
            else if killerMoves[0] == m { s = 8_000 }
            else if killerMoves[1] == m { s = 7_000 }
            return (m, s)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }
}

// MARK: - Evaluation

enum Evaluator {
    static let values: [PieceKind: (mg: Int, eg: Int)] = [
        .pawn: (82, 94), .knight: (337, 281), .bishop: (365, 297),
        .rook: (477, 512), .queen: (1025, 936), .king: (0, 0),
    ]

    // Piece-square tables (White's perspective, a8..h8 first row, i.e. rank 8 at top).
    static let pawnPST: [Int] = [
          0,  0,  0,  0,  0,  0,  0,  0,
         50, 50, 50, 50, 50, 50, 50, 50,
         10, 10, 20, 30, 30, 20, 10, 10,
          5,  5, 10, 25, 25, 10,  5,  5,
          0,  0,  0, 20, 20,  0,  0,  0,
          5, -5,-10,  0,  0,-10, -5,  5,
          5, 10, 10,-20,-20, 10, 10,  5,
          0,  0,  0,  0,  0,  0,  0,  0,
    ]
    static let knightPST: [Int] = [
        -50,-40,-30,-30,-30,-30,-40,-50,
        -40,-20,  0,  0,  0,  0,-20,-40,
        -30,  0, 10, 15, 15, 10,  0,-30,
        -30,  5, 15, 20, 20, 15,  5,-30,
        -30,  0, 15, 20, 20, 15,  0,-30,
        -30,  5, 10, 15, 15, 10,  5,-30,
        -40,-20,  0,  5,  5,  0,-20,-40,
        -50,-40,-30,-30,-30,-30,-40,-50,
    ]
    static let bishopPST: [Int] = [
        -20,-10,-10,-10,-10,-10,-10,-20,
        -10,  0,  0,  0,  0,  0,  0,-10,
        -10,  0,  5, 10, 10,  5,  0,-10,
        -10,  5,  5, 10, 10,  5,  5,-10,
        -10,  0, 10, 10, 10, 10,  0,-10,
        -10, 10, 10, 10, 10, 10, 10,-10,
        -10,  5,  0,  0,  0,  0,  5,-10,
        -20,-10,-10,-10,-10,-10,-10,-20,
    ]
    static let rookPST: [Int] = [
          0,  0,  0,  0,  0,  0,  0,  0,
          5, 10, 10, 10, 10, 10, 10,  5,
         -5,  0,  0,  0,  0,  0,  0, -5,
         -5,  0,  0,  0,  0,  0,  0, -5,
         -5,  0,  0,  0,  0,  0,  0, -5,
         -5,  0,  0,  0,  0,  0,  0, -5,
         -5,  0,  0,  0,  0,  0,  0, -5,
          0,  0,  0,  5,  5,  0,  0,  0,
    ]
    static let queenPST: [Int] = [
        -20,-10,-10, -5, -5,-10,-10,-20,
        -10,  0,  0,  0,  0,  0,  0,-10,
        -10,  0,  5,  5,  5,  5,  0,-10,
         -5,  0,  5,  5,  5,  5,  0, -5,
          0,  0,  5,  5,  5,  5,  0, -5,
        -10,  5,  5,  5,  5,  5,  0,-10,
        -10,  0,  5,  0,  0,  0,  0,-10,
        -20,-10,-10, -5, -5,-10,-10,-20,
    ]
    static let kingMgPST: [Int] = [
        -30,-40,-40,-50,-50,-40,-40,-30,
        -30,-40,-40,-50,-50,-40,-40,-30,
        -30,-40,-40,-50,-50,-40,-40,-30,
        -30,-40,-40,-50,-50,-40,-40,-30,
        -20,-30,-30,-40,-40,-30,-30,-20,
        -10,-20,-20,-20,-20,-20,-20,-10,
         20, 20,  0,  0,  0,  0, 20, 20,
         20, 30, 10,  0,  0, 10, 30, 20,
    ]
    static let kingEgPST: [Int] = [
        -50,-40,-30,-20,-20,-30,-40,-50,
        -30,-20,-10,  0,  0,-10,-20,-30,
        -30,-10, 20, 30, 30, 20,-10,-30,
        -30,-10, 30, 40, 40, 30,-10,-30,
        -30,-10, 30, 40, 40, 30,-10,-30,
        -30,-10, 20, 30, 30, 20,-10,-30,
        -30,-30,  0,  0,  0,  0,-30,-30,
        -50,-30,-30,-30,-30,-30,-30,-50,
    ]

    static func tableIndex(_ sq: Int, _ color: PieceColor) -> Int {
        // Tables list rank 8 first. For White, rank r maps to row 7 - r.
        let file = sq & 7, rank = sq >> 3
        return color == .white ? (7 - rank) * 8 + file : rank * 8 + file
    }

    /// Static evaluation in centipawns from the side to move.
    static func evaluate(_ p: Position) -> Int {
        var mg = 0, eg = 0, phase = 0
        var bishops = [0, 0]
        for i in 0..<64 {
            guard let piece = p.board[i] else { continue }
            let sign = piece.color == .white ? 1 : -1
            let idx = tableIndex(i, piece.color)
            let v = values[piece.kind]!
            var pst = 0
            switch piece.kind {
            case .pawn: pst = pawnPST[idx]
            case .knight: pst = knightPST[idx]; phase += 1
            case .bishop: pst = bishopPST[idx]; phase += 1; bishops[piece.color == .white ? 0 : 1] += 1
            case .rook: pst = rookPST[idx]; phase += 2
            case .queen: pst = queenPST[idx]; phase += 4
            case .king:
                mg += sign * kingMgPST[idx]
                eg += sign * kingEgPST[idx]
                continue
            }
            mg += sign * (v.mg + pst)
            eg += sign * (v.eg + pst)
        }
        if bishops[0] >= 2 { mg += 30; eg += 50 }
        if bishops[1] >= 2 { mg -= 30; eg -= 50 }
        let ph = min(phase, 24)
        let score = (mg * ph + eg * (24 - ph)) / 24
        return p.sideToMove == .white ? score + 10 : -score + 10
    }
}

// MARK: - Zobrist hashing

extension Position {
    static let zobristTable: [UInt64] = {
        var g = SeededGenerator(seed: 0x5EED_C0FF_EE12_3457)
        return (0..<(12 * 64 + 1 + 16 + 8)).map { _ in g.next() }
    }()

    /// 64-bit position hash (placement, side, castling, en passant file).
    public var zobrist: UInt64 {
        let t = Self.zobristTable
        var h: UInt64 = 0
        for i in 0..<64 {
            guard let p = board[i] else { continue }
            let pi = (p.kind.rawValue - 1) + (p.color == .white ? 0 : 6)
            h ^= t[pi * 64 + i]
        }
        if sideToMove == .black { h ^= t[768] }
        h ^= t[769 + Int(castling.rawValue)]
        if let ep = enPassant { h ^= t[785 + ep.file] }
        return h
    }
}
