import Foundation
import ChessCore

/// Engine score from the point of view of the side to move.
public enum EngineScore: Hashable, Codable, Sendable, Comparable {
    case centipawns(Int)
    /// Moves to mate; positive = side to move mates, negative = gets mated.
    case mate(Int)

    /// A single comparable number (mates map to large values).
    public var sortValue: Int {
        switch self {
        case .centipawns(let cp): return cp
        case .mate(let m): return m > 0 ? 100_000 - m : -100_000 - m
        }
    }

    public static func < (a: EngineScore, b: EngineScore) -> Bool { a.sortValue < b.sortValue }

    public var negated: EngineScore {
        switch self {
        case .centipawns(let cp): return .centipawns(-cp)
        case .mate(let m): return .mate(-m)
        }
    }

    /// Converts a side-to-move score to White's point of view.
    public func fromWhite(sideToMove: PieceColor) -> EngineScore {
        sideToMove == .white ? self : negated
    }

    /// Lichess-style winning chances in [-1, 1] for the side the score belongs to.
    public var winningChances: Double {
        switch self {
        case .mate(let m): return m > 0 ? 1 : -1
        case .centipawns(let cp):
            let c = Double(max(-1000, min(1000, cp)))
            return 2 / (1 + exp(-0.00368208 * c)) - 1
        }
    }

    /// Short display such as "+0.35" or "#-3".
    public var display: String {
        switch self {
        case .centipawns(let cp): return String(format: "%@%.2f", cp >= 0 ? "+" : "", Double(cp) / 100)
        case .mate(let m): return "#\(m)"
        }
    }
}

public struct EngineLine: Hashable, Sendable {
    public let pv: [Move]
    public let score: EngineScore
    public let depth: Int
    public let multipv: Int

    public init(pv: [Move], score: EngineScore, depth: Int, multipv: Int = 1) {
        self.pv = pv
        self.score = score
        self.depth = depth
        self.multipv = multipv
    }
}

public struct SearchLimit: Hashable, Codable, Sendable {
    public var depth: Int?
    public var moveTimeMs: Int?
    public var nodes: Int?

    public init(depth: Int? = nil, moveTimeMs: Int? = nil, nodes: Int? = nil) {
        self.depth = depth
        self.moveTimeMs = moveTimeMs
        self.nodes = nodes
    }

    public static func depth(_ d: Int) -> SearchLimit { SearchLimit(depth: d) }
    public static func time(_ ms: Int) -> SearchLimit { SearchLimit(moveTimeMs: ms) }
}

public struct SearchRequest: Hashable, Sendable {
    public var position: Position
    public var limit: SearchLimit
    /// 0...20 (Stockfish "Skill Level"); nil = full strength.
    public var skillLevel: Int?
    public var multiPV: Int

    public init(position: Position, limit: SearchLimit, skillLevel: Int? = nil, multiPV: Int = 1) {
        self.position = position
        self.limit = limit
        self.skillLevel = skillLevel
        self.multiPV = max(1, multiPV)
    }
}

public struct SearchResult: Hashable, Sendable {
    public let bestMove: Move
    public let lines: [EngineLine]

    public init(bestMove: Move, lines: [EngineLine]) {
        self.bestMove = bestMove
        self.lines = lines
    }

    /// Score of the principal line from the side to move.
    public var score: EngineScore? { lines.first?.score }
}

public enum EngineError: Error, Equatable, LocalizedError {
    case notRunning
    case noLegalMoves
    case timeout
    case launchFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "The chess engine is not running."
        case .noLegalMoves: return "There are no legal moves in this position."
        case .timeout: return "The engine did not answer in time."
        case .launchFailed(let s): return "The engine could not be started: \(s)"
        case .cancelled: return "The search was cancelled."
        }
    }
}

/// Anything that can choose and evaluate moves.
public protocol ChessEngine: AnyObject, Sendable {
    var displayName: String { get }
    func search(_ request: SearchRequest) async throws -> SearchResult
    func newGame() async
    func shutdown() async
}
