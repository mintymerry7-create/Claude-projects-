import Foundation
import ChessCore

/// Strength settings for a computer opponent. These are engine settings,
/// not calibrated ratings; the app never shows an Elo for them.
public struct BotProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    /// Stockfish "Skill Level" 0...20.
    public var skillLevel: Int
    /// Maximum search depth (nil = limited by time only).
    public var depth: Int?
    public var moveTimeMs: Int
    public var symbol: String

    public init(id: String, name: String, summary: String, skillLevel: Int, depth: Int?, moveTimeMs: Int, symbol: String) {
        self.id = id
        self.name = name
        self.summary = summary
        self.skillLevel = skillLevel
        self.depth = depth
        self.moveTimeMs = moveTimeMs
        self.symbol = symbol
    }

    public var limit: SearchLimit { SearchLimit(depth: depth, moveTimeMs: moveTimeMs) }

    public static let beginner = BotProfile(
        id: "beginner", name: "Beginner", summary: "Shallow search with frequent inaccuracies. Ideal for your first games.",
        skillLevel: 0, depth: 1, moveTimeMs: 100, symbol: "leaf")
    public static let easy = BotProfile(
        id: "easy", name: "Easy", summary: "Sees simple threats but misses deeper tactics.",
        skillLevel: 3, depth: 3, moveTimeMs: 200, symbol: "tortoise")
    public static let intermediate = BotProfile(
        id: "intermediate", name: "Intermediate", summary: "Punishes loose pieces and plays sensible plans.",
        skillLevel: 8, depth: 6, moveTimeMs: 400, symbol: "figure.walk")
    public static let advanced = BotProfile(
        id: "advanced", name: "Advanced", summary: "Strong tactical play with occasional imprecision.",
        skillLevel: 14, depth: 10, moveTimeMs: 800, symbol: "hare")
    public static let expert = BotProfile(
        id: "expert", name: "Expert", summary: "Full-strength engine limited only by thinking time.",
        skillLevel: 20, depth: nil, moveTimeMs: 1500, symbol: "bolt")

    public static let presets: [BotProfile] = [.beginner, .easy, .intermediate, .advanced, .expert]

    public static func custom(skillLevel: Int, depth: Int?, moveTimeMs: Int) -> BotProfile {
        BotProfile(id: "custom", name: "Custom", summary: "Skill \(skillLevel)" + (depth.map { ", depth \($0)" } ?? "") + ", \(moveTimeMs) ms per move.",
                   skillLevel: max(0, min(20, skillLevel)), depth: depth, moveTimeMs: max(50, moveTimeMs), symbol: "slider.horizontal.3")
    }
}

/// An opening book built from a move tree (an opening course or a personal
/// repertoire). Positions are matched by repetition key, so transpositions work.
public struct OpeningBook: Sendable {
    public let tree: MoveTree
    private let index: [String: [Int]]

    public init(tree: MoveTree) {
        self.tree = tree
        var idx: [String: [Int]] = [:]
        for node in tree.nodes where !node.children.isEmpty {
            if let key = (try? Position(fen: node.fen))?.repetitionKey { idx[key, default: []].append(node.id) }
        }
        index = idx
    }

    /// Book moves with weights (the main move is preferred 3:1).
    public func moves(for position: Position) -> [(move: Move, weight: Int, nodeID: Int)] {
        guard let nodes = index[position.repetitionKey] else { return [] }
        var out: [(Move, Int, Int)] = []
        for n in nodes {
            for (i, c) in tree[n].children.enumerated() {
                guard let m = tree[c].move, !out.contains(where: { $0.0 == m }) else { continue }
                out.append((m, i == 0 ? 3 : 1, c))
            }
        }
        return out
    }

    public func contains(_ position: Position) -> Bool { index[position.repetitionKey] != nil }

    public func choose<G: RandomNumberGenerator>(for position: Position, using rng: inout G) -> Move? {
        let options = moves(for: position)
        let total = options.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var r = Int.random(in: 0..<total, using: &rng)
        for o in options {
            if r < o.weight { return o.move }
            r -= o.weight
        }
        return options.first?.move
    }
}

public enum BotMoveSource: Hashable, Sendable {
    case book
    case engine(EngineScore?)
}

public struct BotMove: Hashable, Sendable {
    public let move: Move
    public let source: BotMoveSource
}

/// Chooses moves for a computer opponent: book first (when a repertoire is
/// set), then the engine with the profile's strength settings.
public final class BotPlayer: @unchecked Sendable {
    public let engine: ChessEngine
    public var profile: BotProfile
    public var book: OpeningBook?
    private var rng = SystemRandomNumberGenerator()

    public init(engine: ChessEngine, profile: BotProfile, book: OpeningBook? = nil) {
        self.engine = engine
        self.profile = profile
        self.book = book
    }

    public func chooseMove(in game: ChessGame) async throws -> BotMove {
        let position = game.position
        if let book, let m = book.choose(for: position, using: &rng), position.isLegal(m) {
            return BotMove(move: m, source: .book)
        }
        if let builtIn = engine as? BuiltInEngine { builtIn.setHistory(Array(game.positions.dropLast())) }
        let result = try await engine.search(SearchRequest(position: position, limit: profile.limit, skillLevel: profile.skillLevel))
        return BotMove(move: result.bestMove, source: .engine(result.score))
    }

    /// A hint for the human player: the engine's best move at full strength.
    public func hint(for position: Position, timeMs: Int = 600) async throws -> SearchResult {
        try await engine.search(SearchRequest(position: position, limit: SearchLimit(depth: 14, moveTimeMs: timeMs)))
    }
}
