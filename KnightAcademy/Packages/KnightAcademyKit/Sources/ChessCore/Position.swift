import Foundation

public enum FENError: Error, Equatable, LocalizedError {
    case wrongFieldCount(Int)
    case badBoard(String)
    case badSideToMove(String)
    case badCastling(String)
    case badEnPassant(String)
    case badCounter(String)
    case illegalPosition(String)

    public var errorDescription: String? {
        switch self {
        case .wrongFieldCount(let n): return "A FEN needs 4–6 fields, found \(n)."
        case .badBoard(let s): return "Invalid piece placement: \(s)"
        case .badSideToMove(let s): return "Invalid side to move: \(s)"
        case .badCastling(let s): return "Invalid castling field: \(s)"
        case .badEnPassant(let s): return "Invalid en passant square: \(s)"
        case .badCounter(let s): return "Invalid move counter: \(s)"
        case .illegalPosition(let s): return "Illegal position: \(s)"
        }
    }
}

/// Information needed to take a move back.
public struct UndoState: Sendable {
    let captured: Piece?
    let capturedSquare: Square
    let castling: CastlingRights
    let enPassant: Square?
    let halfmoveClock: Int
    let fullmoveNumber: Int
    let movedPiece: Piece
}

/// A complete chess position: placement, side to move, castling rights,
/// en passant target and move counters.
public struct Position: Hashable, Sendable {
    public internal(set) var board: [Piece?]
    public internal(set) var sideToMove: PieceColor
    public internal(set) var castling: CastlingRights
    /// Target square of a pawn that just advanced two squares (pseudo, may not be capturable).
    public internal(set) var enPassant: Square?
    public internal(set) var halfmoveClock: Int
    public internal(set) var fullmoveNumber: Int

    public static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    public static let start: Position = try! Position(fen: startFEN)

    public init(board: [Piece?], sideToMove: PieceColor, castling: CastlingRights,
                enPassant: Square?, halfmoveClock: Int = 0, fullmoveNumber: Int = 1) {
        precondition(board.count == 64)
        self.board = board
        self.sideToMove = sideToMove
        self.castling = castling
        self.enPassant = enPassant
        self.halfmoveClock = halfmoveClock
        self.fullmoveNumber = fullmoveNumber
    }

    public subscript(_ sq: Square) -> Piece? { board[sq.index] }

    // MARK: FEN

    /// Parses FEN. The counters may be omitted (EPD style). The position is
    /// validated for basic legality (one king each, no pawns on back ranks,
    /// side not to move is not in check).
    public init(fen: String) throws {
        let fields = fen.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard (4...6).contains(fields.count) else { throw FENError.wrongFieldCount(fields.count) }

        var board = [Piece?](repeating: nil, count: 64)
        let ranks = fields[0].split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8 else { throw FENError.badBoard(fields[0]) }
        for (i, rankText) in ranks.enumerated() {
            let rank = 7 - i
            var file = 0
            for c in rankText {
                if let d = c.wholeNumberValue, (1...8).contains(d) {
                    file += d
                } else if let p = Piece(fenCharacter: c) {
                    guard file < 8 else { throw FENError.badBoard(fields[0]) }
                    board[rank * 8 + file] = p
                    file += 1
                } else {
                    throw FENError.badBoard(fields[0])
                }
                guard file <= 8 else { throw FENError.badBoard(fields[0]) }
            }
            guard file == 8 else { throw FENError.badBoard(fields[0]) }
        }

        let side: PieceColor
        switch fields[1] {
        case "w": side = .white
        case "b": side = .black
        default: throw FENError.badSideToMove(fields[1])
        }

        var castling: CastlingRights = []
        if fields[2] != "-" {
            for c in fields[2] {
                switch c {
                case "K": castling.insert(.whiteKingside)
                case "Q": castling.insert(.whiteQueenside)
                case "k": castling.insert(.blackKingside)
                case "q": castling.insert(.blackQueenside)
                default: throw FENError.badCastling(fields[2])
                }
            }
        }

        var ep: Square?
        if fields[3] != "-" {
            guard let sq = Square(fields[3]), sq.rank == (side == .white ? 5 : 2) else {
                throw FENError.badEnPassant(fields[3])
            }
            ep = sq
        }

        var half = 0, full = 1
        if fields.count >= 5 {
            guard let h = Int(fields[4]), h >= 0 else { throw FENError.badCounter(fields[4]) }
            half = h
        }
        if fields.count == 6 {
            guard let f = Int(fields[5]), f >= 1 else { throw FENError.badCounter(fields[5]) }
            full = f
        }

        self.init(board: board, sideToMove: side, castling: castling, enPassant: ep,
                  halfmoveClock: half, fullmoveNumber: full)
        try validate()
        sanitizeCastlingAndEnPassant()
    }

    private func validate() throws {
        for color in PieceColor.allCases {
            let kings = board.filter { $0 == Piece(color, .king) }.count
            guard kings == 1 else { throw FENError.illegalPosition("\(color.displayName) must have exactly one king") }
        }
        for i in 0..<8 where board[i]?.kind == .pawn || board[56 + i]?.kind == .pawn {
            throw FENError.illegalPosition("pawns cannot stand on the first or last rank")
        }
        if isKingAttacked(sideToMove.opposite) {
            throw FENError.illegalPosition("the side not to move is in check")
        }
    }

    /// Drops castling rights whose king/rook are not on their home squares and
    /// en passant squares without a pawn that could have just moved there.
    private mutating func sanitizeCastlingAndEnPassant() {
        let checks: [(CastlingRights, Int, Int, PieceColor)] = [
            (.whiteKingside, 4, 7, .white), (.whiteQueenside, 4, 0, .white),
            (.blackKingside, 60, 63, .black), (.blackQueenside, 60, 56, .black),
        ]
        for (right, k, r, c) in checks where castling.contains(right) {
            if board[k] != Piece(c, .king) || board[r] != Piece(c, .rook) { castling.remove(right) }
        }
        if let ep = enPassant {
            let mover = sideToMove.opposite
            let pawnSq = ep.index - 8 * mover.forward
            let originSq = ep.index + 8 * mover.forward
            if board[pawnSq] != Piece(mover, .pawn) || board[ep.index] != nil || board[originSq] != nil {
                enPassant = nil
            }
        }
    }

    /// FEN string. The en passant square is only written when an en passant
    /// capture is actually legal (same convention as python-chess / lichess).
    public var fen: String {
        "\(placementFEN) \(sideToMove == .white ? "w" : "b") \(castlingFEN) \(legalEnPassant?.name ?? "-") \(halfmoveClock) \(fullmoveNumber)"
    }

    public var placementFEN: String {
        var out = ""
        for rank in stride(from: 7, through: 0, by: -1) {
            var empty = 0
            for file in 0..<8 {
                if let p = board[rank * 8 + file] {
                    if empty > 0 { out += String(empty); empty = 0 }
                    out.append(p.fenCharacter)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { out += String(empty) }
            if rank > 0 { out += "/" }
        }
        return out
    }

    var castlingFEN: String {
        var s = ""
        if castling.contains(.whiteKingside) { s += "K" }
        if castling.contains(.whiteQueenside) { s += "Q" }
        if castling.contains(.blackKingside) { s += "k" }
        if castling.contains(.blackQueenside) { s += "q" }
        return s.isEmpty ? "-" : s
    }

    /// Key identifying the position for repetition and opening lookups
    /// (placement, side, castling, legal en passant).
    public var repetitionKey: String {
        "\(placementFEN) \(sideToMove == .white ? "w" : "b") \(castlingFEN) \(legalEnPassant?.name ?? "-")"
    }

    /// The en passant square only if some legal move captures en passant.
    public var legalEnPassant: Square? {
        guard let ep = enPassant else { return nil }
        let capturesEP = legalMoves().contains { $0.to == ep && self[$0.from]?.kind == .pawn }
        return capturesEP ? ep : nil
    }

    // MARK: Queries

    public func kingSquare(_ color: PieceColor) -> Square? {
        let king = Piece(color, .king)
        guard let i = board.firstIndex(of: king) else { return nil }
        return Square(i)
    }

    public var isCheck: Bool { isKingAttacked(sideToMove) }

    public func isKingAttacked(_ color: PieceColor) -> Bool {
        guard let k = kingSquare(color) else { return false }
        return isAttacked(k, by: color.opposite)
    }

    public func pieces(of color: PieceColor) -> [(Square, Piece)] {
        board.indices.compactMap { i in
            guard let p = board[i], p.color == color else { return nil }
            return (Square(i), p)
        }
    }

    /// Material in conventional pawn units.
    public func material(_ color: PieceColor) -> Int {
        board.reduce(0) { $0 + (($1?.color == color) ? $1!.kind.value : 0) }
    }

    // MARK: Make / unmake

    /// Plays a move in place. The move must be legal (or at least pseudo-legal
    /// when used by move generation); use `play(_:)` for checked input.
    @discardableResult
    public mutating func make(_ move: Move) -> UndoState {
        let from = move.from.index, to = move.to.index
        let piece = board[from]!
        var captured = board[to]
        var capturedSquare = move.to
        let undo0 = (castling, enPassant, halfmoveClock, fullmoveNumber)

        if piece.kind == .pawn, let ep = enPassant, ep.index == to, captured == nil {
            let capIdx = to - 8 * piece.color.forward
            captured = board[capIdx]
            capturedSquare = Square(capIdx)
            board[capIdx] = nil
        }

        board[from] = nil
        board[to] = move.promotion.map { Piece(piece.color, $0) } ?? piece

        if piece.kind == .king, abs(to - from) == 2 {
            let rank = from & ~7
            if to > from {
                board[rank + 5] = board[rank + 7]; board[rank + 7] = nil
            } else {
                board[rank + 3] = board[rank]; board[rank] = nil
            }
        }

        if piece.kind == .king {
            castling.remove(.kingside(piece.color))
            castling.remove(.queenside(piece.color))
        }
        for idx in [from, to] {
            switch idx {
            case 0: castling.remove(.whiteQueenside)
            case 7: castling.remove(.whiteKingside)
            case 56: castling.remove(.blackQueenside)
            case 63: castling.remove(.blackKingside)
            default: break
            }
        }

        if piece.kind == .pawn, abs(to - from) == 16 {
            enPassant = Square((from + to) / 2)
        } else {
            enPassant = nil
        }

        halfmoveClock = (piece.kind == .pawn || captured != nil) ? 0 : halfmoveClock + 1
        if piece.color == .black { fullmoveNumber += 1 }
        sideToMove = sideToMove.opposite

        return UndoState(captured: captured, capturedSquare: capturedSquare,
                         castling: undo0.0, enPassant: undo0.1,
                         halfmoveClock: undo0.2, fullmoveNumber: undo0.3, movedPiece: piece)
    }

    public mutating func unmake(_ move: Move, _ undo: UndoState) {
        let from = move.from.index, to = move.to.index
        sideToMove = sideToMove.opposite
        board[from] = undo.movedPiece
        board[to] = nil
        if let cap = undo.captured { board[undo.capturedSquare.index] = cap }
        if undo.movedPiece.kind == .king, abs(to - from) == 2 {
            let rank = from & ~7
            if to > from {
                board[rank + 7] = board[rank + 5]; board[rank + 5] = nil
            } else {
                board[rank] = board[rank + 3]; board[rank + 3] = nil
            }
        }
        castling = undo.castling
        enPassant = undo.enPassant
        halfmoveClock = undo.halfmoveClock
        fullmoveNumber = undo.fullmoveNumber
    }

    /// Returns the position after a legal move, or throws.
    public func playing(_ move: Move) throws -> Position {
        guard isLegal(move) else { throw ChessError.illegalMove(move.uci) }
        var p = self
        p.make(move)
        return p
    }

    public func isLegal(_ move: Move) -> Bool { legalMoves().contains(move) }

    // MARK: Move classification

    public func isCapture(_ move: Move) -> Bool {
        if board[move.to.index] != nil { return true }
        return isEnPassant(move)
    }

    public func isEnPassant(_ move: Move) -> Bool {
        guard let p = board[move.from.index], p.kind == .pawn, let ep = enPassant else { return false }
        return move.to == ep && move.from.file != move.to.file && board[move.to.index] == nil
    }

    public func isCastling(_ move: Move) -> Bool {
        guard let p = board[move.from.index], p.kind == .king else { return false }
        return abs(move.to.index - move.from.index) == 2
    }

    public func givesCheck(_ move: Move) -> Bool {
        var p = self
        p.make(move)
        return p.isCheck
    }
}

public enum ChessError: Error, Equatable, LocalizedError {
    case illegalMove(String)
    case invalidSAN(String)
    case ambiguousSAN(String)

    public var errorDescription: String? {
        switch self {
        case .illegalMove(let m): return "Illegal move: \(m)"
        case .invalidSAN(let m): return "Could not read move “\(m)”."
        case .ambiguousSAN(let m): return "Ambiguous move “\(m)”."
        }
    }
}
