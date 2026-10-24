import Foundation

public enum PieceColor: String, Codable, CaseIterable, Hashable, Sendable {
    case white, black

    public var opposite: PieceColor { self == .white ? .black : .white }
    /// Rank direction pawns of this color move in.
    public var forward: Int { self == .white ? 1 : -1 }
    public var displayName: String { self == .white ? "White" : "Black" }
}

public enum PieceKind: Int, Codable, CaseIterable, Hashable, Sendable {
    case pawn = 1, knight, bishop, rook, queen, king

    /// SAN letter ("" for pawns).
    public var sanLetter: String {
        switch self {
        case .pawn: return ""
        case .knight: return "N"
        case .bishop: return "B"
        case .rook: return "R"
        case .queen: return "Q"
        case .king: return "K"
        }
    }

    /// Lowercase FEN letter.
    public var fenLetter: Character {
        switch self {
        case .pawn: return "p"
        case .knight: return "n"
        case .bishop: return "b"
        case .rook: return "r"
        case .queen: return "q"
        case .king: return "k"
        }
    }

    public init?(letter: Character) {
        switch letter.lowercased() {
        case "p": self = .pawn
        case "n": self = .knight
        case "b": self = .bishop
        case "r": self = .rook
        case "q": self = .queen
        case "k": self = .king
        default: return nil
        }
    }

    /// Conventional material value in pawns.
    public var value: Int {
        switch self {
        case .pawn: return 1
        case .knight, .bishop: return 3
        case .rook: return 5
        case .queen: return 9
        case .king: return 0
        }
    }

    public var name: String {
        switch self {
        case .pawn: return "pawn"
        case .knight: return "knight"
        case .bishop: return "bishop"
        case .rook: return "rook"
        case .queen: return "queen"
        case .king: return "king"
        }
    }

    public static let promotionChoices: [PieceKind] = [.queen, .rook, .bishop, .knight]
}

public struct Piece: Hashable, Codable, Sendable, CustomStringConvertible {
    public let color: PieceColor
    public let kind: PieceKind

    public init(_ color: PieceColor, _ kind: PieceKind) {
        self.color = color
        self.kind = kind
    }

    public var fenCharacter: Character {
        color == .white ? Character(kind.fenLetter.uppercased()) : kind.fenLetter
    }

    public init?(fenCharacter c: Character) {
        guard let kind = PieceKind(letter: c) else { return nil }
        self.init(c.isUppercase ? .white : .black, kind)
    }

    /// Asset name, e.g. "wK", "bN".
    public var assetName: String {
        (color == .white ? "w" : "b") + (kind == .pawn ? "P" : kind.sanLetter)
    }

    public var description: String { "\(color.displayName) \(kind.name)" }
}

/// A board square, 0 = a1 ... 63 = h8.
public struct Square: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let index: Int

    public init(_ index: Int) {
        precondition((0..<64).contains(index), "square index out of range")
        self.index = index
    }

    public init?(file: Int, rank: Int) {
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        self.index = rank * 8 + file
    }

    public init?(_ name: String) {
        let chars = Array(name.lowercased())
        guard chars.count == 2,
              let f = chars[0].asciiValue, let r = chars[1].asciiValue,
              f >= 97, f <= 104, r >= 49, r <= 56 else { return nil }
        self.index = Int(r - 49) * 8 + Int(f - 97)
    }

    public var file: Int { index & 7 }
    public var rank: Int { index >> 3 }
    public var fileLetter: Character { Character(UnicodeScalar(97 + file)!) }
    public var name: String { "\(fileLetter)\(rank + 1)" }
    public var description: String { name }
    public var isLight: Bool { (file + rank) % 2 == 1 }

    public func offset(file df: Int, rank dr: Int) -> Square? {
        Square(file: file + df, rank: rank + dr)
    }

    public static func < (lhs: Square, rhs: Square) -> Bool { lhs.index < rhs.index }

    public static let all: [Square] = (0..<64).map(Square.init)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let sq = Square(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid square \(s)")
        }
        self = sq
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}

/// A move in coordinate form. Everything else (capture, castling, en passant)
/// is derived from the position it is played in.
public struct Move: Hashable, Codable, Sendable, CustomStringConvertible {
    public let from: Square
    public let to: Square
    public let promotion: PieceKind?

    public init(from: Square, to: Square, promotion: PieceKind? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    /// Parses UCI notation such as "e2e4" or "e7e8q".
    public init?(uci: String) {
        let s = uci.lowercased()
        guard s.count == 4 || s.count == 5,
              let from = Square(String(s.prefix(2))),
              let to = Square(String(s.dropFirst(2).prefix(2))) else { return nil }
        var promo: PieceKind?
        if s.count == 5 {
            guard let p = PieceKind(letter: s.last!), p != .pawn, p != .king else { return nil }
            promo = p
        }
        self.init(from: from, to: to, promotion: promo)
    }

    public var uci: String {
        from.name + to.name + (promotion.map { String($0.fenLetter) } ?? "")
    }

    public var description: String { uci }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let m = Move(uci: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid move \(s)")
        }
        self = m
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(uci)
    }
}

public struct CastlingRights: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let whiteKingside = CastlingRights(rawValue: 1)
    public static let whiteQueenside = CastlingRights(rawValue: 2)
    public static let blackKingside = CastlingRights(rawValue: 4)
    public static let blackQueenside = CastlingRights(rawValue: 8)
    public static let all: CastlingRights = [.whiteKingside, .whiteQueenside, .blackKingside, .blackQueenside]

    public static func kingside(_ c: PieceColor) -> CastlingRights { c == .white ? .whiteKingside : .blackKingside }
    public static func queenside(_ c: PieceColor) -> CastlingRights { c == .white ? .whiteQueenside : .blackQueenside }
}
