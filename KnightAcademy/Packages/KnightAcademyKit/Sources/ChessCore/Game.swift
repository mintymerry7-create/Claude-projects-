import Foundation

public enum GameResult: String, Codable, Sendable, Hashable {
    case whiteWins = "1-0"
    case blackWins = "0-1"
    case draw = "1/2-1/2"

    public static func win(for color: PieceColor) -> GameResult { color == .white ? .whiteWins : .blackWins }

    public var winner: PieceColor? {
        switch self {
        case .whiteWins: return .white
        case .blackWins: return .black
        case .draw: return nil
        }
    }
}

public enum GameEndReason: String, Codable, Sendable, Hashable {
    case checkmate, stalemate, threefoldRepetition, fiftyMoveRule, insufficientMaterial
    case resignation, timeout, agreement

    public var displayName: String {
        switch self {
        case .checkmate: return "Checkmate"
        case .stalemate: return "Stalemate"
        case .threefoldRepetition: return "Threefold repetition"
        case .fiftyMoveRule: return "Fifty-move rule"
        case .insufficientMaterial: return "Insufficient material"
        case .resignation: return "Resignation"
        case .timeout: return "Time out"
        case .agreement: return "Draw by agreement"
        }
    }
}

public struct GameOutcome: Codable, Sendable, Hashable {
    public let result: GameResult
    public let reason: GameEndReason

    public init(result: GameResult, reason: GameEndReason) {
        self.result = result
        self.reason = reason
    }

    public var summary: String {
        switch result {
        case .draw: return "Draw · \(reason.displayName)"
        case .whiteWins: return "White wins · \(reason.displayName)"
        case .blackWins: return "Black wins · \(reason.displayName)"
        }
    }
}

/// A game in progress: start position, played moves, derived positions,
/// SAN history, redo stack and outcome detection. Value type.
public struct ChessGame: Sendable, Hashable {
    public private(set) var startPosition: Position
    public private(set) var moves: [Move] = []
    public private(set) var sanMoves: [String] = []
    /// positions[0] is the start; positions[i] follows moves[i-1].
    public private(set) var positions: [Position]
    public private(set) var redoStack: [Move] = []
    /// Outcome set by an external event (resignation, timeout, agreement).
    public private(set) var declaredOutcome: GameOutcome?

    public init(startPosition: Position = .start) {
        self.startPosition = startPosition
        self.positions = [startPosition]
    }

    public init(fen: String) throws {
        self.init(startPosition: try Position(fen: fen))
    }

    public var position: Position { positions[positions.count - 1] }
    public var sideToMove: PieceColor { position.sideToMove }
    public var lastMove: Move? { moves.last }
    public var plyCount: Int { moves.count }
    public var canUndo: Bool { !moves.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty && outcome == nil }

    public var outcome: GameOutcome? {
        if let declaredOutcome { return declaredOutcome }
        return Self.automaticOutcome(position: position, history: positions)
    }

    public var isOver: Bool { outcome != nil }

    static func automaticOutcome(position: Position, history: [Position]) -> GameOutcome? {
        if !position.hasLegalMoves {
            return position.isCheck
                ? GameOutcome(result: .win(for: position.sideToMove.opposite), reason: .checkmate)
                : GameOutcome(result: .draw, reason: .stalemate)
        }
        if position.hasInsufficientMaterial { return GameOutcome(result: .draw, reason: .insufficientMaterial) }
        if position.halfmoveClock >= 100 { return GameOutcome(result: .draw, reason: .fiftyMoveRule) }
        let key = position.repetitionKey
        // Only positions since the last irreversible move can repeat.
        let window = history.suffix(position.halfmoveClock + 1)
        if window.filter({ $0.repetitionKey == key }).count >= 3 {
            return GameOutcome(result: .draw, reason: .threefoldRepetition)
        }
        return nil
    }

    // MARK: Mutation

    /// Plays a legal move. Clears the redo stack unless the move equals the next redo move.
    @discardableResult
    public mutating func play(_ move: Move) throws -> String {
        guard outcome == nil else { throw ChessError.illegalMove("game is over") }
        let pos = position
        guard pos.isLegal(move) else { throw ChessError.illegalMove(move.uci) }
        let san = pos.san(for: move)
        var next = pos
        next.make(move)
        moves.append(move)
        sanMoves.append(san)
        positions.append(next)
        if redoStack.last == move { redoStack.removeLast() } else { redoStack.removeAll() }
        return san
    }

    @discardableResult
    public mutating func play(san: String) throws -> Move {
        let m = try position.move(fromSAN: san)
        try play(m)
        return m
    }

    @discardableResult
    public mutating func undo() -> Move? {
        guard let m = moves.popLast() else { return nil }
        sanMoves.removeLast()
        positions.removeLast()
        redoStack.append(m)
        declaredOutcome = nil
        return m
    }

    @discardableResult
    public mutating func redo() -> Move? {
        guard let m = redoStack.last else { return nil }
        do { try play(m) } catch { return nil }
        return m
    }

    public mutating func resign(_ color: PieceColor) {
        guard outcome == nil else { return }
        declaredOutcome = GameOutcome(result: .win(for: color.opposite), reason: .resignation)
    }

    public mutating func agreeDraw() {
        guard outcome == nil else { return }
        declaredOutcome = GameOutcome(result: .draw, reason: .agreement)
    }

    /// Flag fall. If the opponent cannot possibly mate, the game is drawn (FIDE 6.9).
    public mutating func timeout(_ color: PieceColor) {
        guard outcome == nil else { return }
        let winner = color.opposite
        if Self.cannotMate(position, color: winner) {
            declaredOutcome = GameOutcome(result: .draw, reason: .timeout)
        } else {
            declaredOutcome = GameOutcome(result: .win(for: winner), reason: .timeout)
        }
    }

    static func cannotMate(_ p: Position, color: PieceColor) -> Bool {
        let pieces = p.pieces(of: color).map(\.1.kind).filter { $0 != .king }
        if pieces.isEmpty { return true }
        if pieces.count == 1 && (pieces[0] == .bishop || pieces[0] == .knight) { return true }
        return false
    }

    // MARK: Notation

    /// Numbered SAN movetext such as "1. e4 e5 2. Nf3".
    public var movetext: String {
        Notation.movetext(sans: sanMoves, startPosition: startPosition)
    }

    public func pgn(tags: [String: String] = [:]) -> String {
        var all = tags
        all["Result"] = outcome?.result.rawValue ?? "*"
        if startPosition != .start && startPosition.fen != Position.startFEN {
            all["SetUp"] = "1"
            all["FEN"] = startPosition.fen
        }
        return PGNWriter.write(tags: all, movetext: movetext, result: all["Result"] ?? "*")
    }
}

public enum Notation {
    /// Builds numbered movetext from SAN moves.
    public static func movetext(sans: [String], startPosition: Position) -> String {
        var out: [String] = []
        var number = startPosition.fullmoveNumber
        var white = startPosition.sideToMove == .white
        for (i, san) in sans.enumerated() {
            if white {
                out.append("\(number). \(san)")
            } else {
                out.append(i == 0 ? "\(number)... \(san)" : san)
                number += 1
            }
            white.toggle()
        }
        return out.joined(separator: " ")
    }

    /// Label for the move at `ply` (0-based) from the standard start: "1.", "1...".
    public static func moveNumberLabel(ply: Int, startPosition: Position = .start) -> String {
        let offset = startPosition.sideToMove == .white ? 0 : 1
        let p = ply + offset
        let number = startPosition.fullmoveNumber + p / 2
        return p % 2 == 0 ? "\(number)." : "\(number)..."
    }

    /// Plays a SAN sequence from a position, returning the moves.
    public static func moves(fromSANs sans: [String], start: Position = .start) throws -> [Move] {
        var p = start
        var out: [Move] = []
        for s in sans {
            let m = try p.move(fromSAN: s)
            p.make(m)
            out.append(m)
        }
        return out
    }

    /// Splits movetext like "1. e4 e5 2. Nf3" into SAN tokens.
    public static func sanTokens(fromMovetext text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .compactMap { token -> String? in
                var t = token
                if let dot = t.lastIndex(of: ".") { t = String(t[t.index(after: dot)...]) }
                if t.isEmpty || ["1-0", "0-1", "1/2-1/2", "*"].contains(t) { return nil }
                return t
            }
    }
}
