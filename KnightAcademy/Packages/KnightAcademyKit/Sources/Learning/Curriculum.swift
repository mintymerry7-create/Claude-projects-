import Foundation
import ChessCore
import OpeningDatabase

/// A step in a fundamentals lesson: an explanation on a board, optionally
/// followed by a move task.
public struct LessonStep: Codable, Hashable, Sendable {
    public let text: String
    public let fen: String
    public let arrows: [Arrow]
    public let highlights: [Square]
    /// When present, the learner must play the solution. Alternates learner
    /// move / reply in UCI; replies are played automatically.
    public let solution: [String]?
    /// Extra first moves that are also correct (e.g. two ways to mate).
    public let alternatives: [String]?
    public let hint: String?
    public let success: String?

    public var isTask: Bool { !(solution?.isEmpty ?? true) }
    public var position: Position { (try? Position(fen: fen)) ?? .start }

    public var solutionMoves: [Move] { (solution ?? []).compactMap(Move.init(uci:)) }
    public var acceptedFirstMoves: [Move] {
        (solutionMoves.prefix(1) + (alternatives ?? []).compactMap(Move.init(uci:)))
    }
}

public struct Lesson: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let difficulty: Difficulty
    /// Puzzle themes this lesson teaches (used for adaptive recommendations).
    public let themes: [String]
    public let steps: [LessonStep]

    public var taskCount: Int { steps.filter(\.isTask).count }
}

public struct LessonModule: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let symbol: String
    public let lessons: [Lesson]
}

public struct Curriculum: Codable, Sendable {
    public let modules: [LessonModule]

    public var allLessons: [Lesson] { modules.flatMap(\.lessons) }

    public func lesson(id: String) -> Lesson? { allLessons.first { $0.id == id } }

    public func module(containing lessonID: String) -> LessonModule? {
        modules.first { $0.lessons.contains { $0.id == lessonID } }
    }

    public static func loadBundled() throws -> Curriculum {
        guard let url = Bundle.module.url(forResource: "curriculum", withExtension: "json") else {
            throw OpeningDatabaseError.resourceMissing
        }
        return try JSONDecoder().decode(Curriculum.self, from: Data(contentsOf: url))
    }

    public static let shared: Curriculum = (try? loadBundled()) ?? Curriculum(modules: [])
}

/// A tactical puzzle. The first move of `solution` is the learner's; moves
/// alternate learner / opponent.
public struct Puzzle: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let fen: String
    public let solution: [String]
    public let themes: [String]
    /// 1 (easiest) ... 5 (hardest), derived from solution length and move type.
    public let level: Int
    /// The opponent's move that led to the puzzle position, if known.
    public let lastMove: String?

    public init(id: String, fen: String, solution: [String], themes: [String], level: Int, lastMove: String?) {
        self.id = id
        self.fen = fen
        self.solution = solution
        self.themes = themes
        self.level = level
        self.lastMove = lastMove
    }

    public var position: Position { (try? Position(fen: fen)) ?? .start }
    public var solutionMoves: [Move] { solution.compactMap(Move.init(uci:)) }
    public var learnerColor: PieceColor { position.sideToMove }
    public var learnerMoveCount: Int { (solution.count + 1) / 2 }

    public var primaryTheme: String {
        let order = ["mateIn1", "mateIn2", "mateIn3", "backRankMate", "smotheredMate", "fork", "pin", "skewer",
                     "discoveredAttack", "promotion", "sacrifice", "hangingPiece", "advantage"]
        return order.first { themes.contains($0) } ?? themes.first ?? "advantage"
    }

    public static func displayName(forTheme t: String) -> String {
        switch t {
        case "mate": return "Checkmate"
        case "mateIn1": return "Mate in 1"
        case "mateIn2": return "Mate in 2"
        case "mateIn3": return "Mate in 3"
        case "backRankMate": return "Back-rank mate"
        case "smotheredMate": return "Smothered mate"
        case "fork": return "Fork"
        case "pin": return "Pin"
        case "skewer": return "Skewer"
        case "discoveredAttack": return "Discovered attack"
        case "promotion": return "Promotion"
        case "sacrifice": return "Sacrifice"
        case "hangingPiece": return "Hanging piece"
        case "deflection": return "Deflection"
        case "removingTheDefender": return "Removing the defender"
        default: return "Winning advantage"
        }
    }

    /// Short explanation shown after solving, derived from the themes.
    public var explanation: String {
        var parts: [String] = []
        if themes.contains("mate") {
            parts.append("The solution forces checkmate — always look at checks first.")
        }
        if themes.contains("fork") { parts.append("One piece attacks two targets at once; the opponent cannot save both.") }
        if themes.contains("pin") { parts.append("A pinned piece cannot move without exposing something more valuable behind it.") }
        if themes.contains("skewer") { parts.append("A valuable piece is attacked and must move, exposing the piece behind it.") }
        if themes.contains("discoveredAttack") { parts.append("Moving one piece unmasks an attack by another.") }
        if themes.contains("hangingPiece") { parts.append("An undefended piece can simply be taken.") }
        if themes.contains("sacrifice") { parts.append("Giving material first leads to a bigger gain.") }
        if themes.contains("promotion") { parts.append("The passed pawn reaches the last rank.") }
        if parts.isEmpty { parts.append("This move wins decisive material or position; any other move lets the advantage slip.") }
        return parts.joined(separator: " ")
    }
}

public enum PuzzleLibrary {
    public static func loadBundled() throws -> [Puzzle] {
        guard let url = Bundle.module.url(forResource: "puzzles", withExtension: "json") else {
            throw OpeningDatabaseError.resourceMissing
        }
        return try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
    }

    public static let shared: [Puzzle] = (try? loadBundled()) ?? []

    public static var allThemes: [String] {
        let preferred = ["mateIn1", "mateIn2", "mateIn3", "backRankMate", "fork", "pin", "skewer",
                         "discoveredAttack", "hangingPiece", "sacrifice", "promotion", "advantage"]
        let present = Set(shared.flatMap(\.themes))
        return preferred.filter(present.contains)
    }
}
