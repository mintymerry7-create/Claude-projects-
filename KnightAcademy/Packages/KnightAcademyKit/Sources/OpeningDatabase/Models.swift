import Foundation
import ChessCore

public enum Difficulty: String, Codable, CaseIterable, Comparable, Sendable, Identifiable {
    case beginner, intermediate, advanced

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
    private var order: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Difficulty, b: Difficulty) -> Bool { a.order < b.order }
}

public enum LineKind: String, Codable, Sendable, CaseIterable {
    case main, key, sideline, trap

    public var displayName: String {
        switch self {
        case .main: return "Main line"
        case .key: return "Key variation"
        case .sideline: return "Sideline"
        case .trap: return "Trap"
        }
    }
}

public struct OpeningLine: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: LineKind
    /// SAN moves from the standard starting position.
    public let moves: [String]
    /// Hand-written annotations keyed by 1-based ply.
    public let notes: [String: String]
    public let description: String
    public let eco: String?
    /// For traps: the side that sets the trap.
    public let trapper: PieceColor?

    public init(id: String, name: String, kind: LineKind, moves: [String], notes: [String: String] = [:],
                description: String = "", eco: String? = nil, trapper: PieceColor? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.moves = moves
        self.notes = notes
        self.description = description
        self.eco = eco
        self.trapper = trapper
    }

    public func note(atPly ply: Int) -> String? { notes[String(ply)] }
    public var plyCount: Int { moves.count }
}

public struct KeyPosition: Codable, Hashable, Sendable {
    public let ply: Int
    public let title: String
    public let text: String
}

/// One opening course with its lines and teaching content.
public struct Opening: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let aliases: [String]
    public let eco: String
    public let family: String
    public let group: String
    /// The side that "plays" this opening (whose repertoire it belongs to).
    public let side: PieceColor
    public let difficulty: Difficulty
    public let summary: String
    public let ideas: [String]
    public let tactics: [String]
    public let whitePlans: [String]
    public let blackPlans: [String]
    public let mistakes: [String]
    public let keyPositions: [KeyPosition]
    public let canonicalName: String
    public let canonicalPly: Int
    /// FEN of the position that defines the opening.
    public let fen: String
    public let lines: [OpeningLine]
    public let source: String

    public init(id: String, name: String, aliases: [String], eco: String, family: String, group: String,
                side: PieceColor, difficulty: Difficulty, summary: String, ideas: [String], tactics: [String],
                whitePlans: [String], blackPlans: [String], mistakes: [String], keyPositions: [KeyPosition],
                canonicalName: String, canonicalPly: Int, fen: String, lines: [OpeningLine], source: String) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.eco = eco
        self.family = family
        self.group = group
        self.side = side
        self.difficulty = difficulty
        self.summary = summary
        self.ideas = ideas
        self.tactics = tactics
        self.whitePlans = whitePlans
        self.blackPlans = blackPlans
        self.mistakes = mistakes
        self.keyPositions = keyPositions
        self.canonicalName = canonicalName
        self.canonicalPly = canonicalPly
        self.fen = fen
        self.lines = lines
        self.source = source
    }

    public var mainLine: OpeningLine { lines.first { $0.kind == .main } ?? lines[0] }
    public var keyVariations: [OpeningLine] { lines.filter { $0.kind == .key } }
    public var traps: [OpeningLine] { lines.filter { $0.kind == .trap } }
    public var sidelines: [OpeningLine] { lines.filter { $0.kind == .sideline } }

    /// Moves that define the opening (up to the canonical position).
    public var definingMoves: [String] { Array(mainLine.moves.prefix(canonicalPly)) }

    public var definingMovetext: String {
        Notation.movetext(sans: definingMoves, startPosition: .start)
    }

    public var mainLineMovetext: String {
        Notation.movetext(sans: mainLine.moves, startPosition: .start)
    }

    public var position: Position { (try? Position(fen: fen)) ?? .start }

    /// Searchable text (name, aliases, ECO, family, line names).
    var searchBlob: String {
        ([name, eco, family, group, canonicalName] + aliases + lines.filter { $0.kind != .sideline }.map(\.name))
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

struct OpeningFile: Codable {
    let version: Int
    let openings: [Opening]
}
