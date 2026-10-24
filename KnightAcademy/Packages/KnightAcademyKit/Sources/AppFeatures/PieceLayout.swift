import Foundation
import ChessCore

/// Gives pieces stable identities across positions so the board can animate
/// them sliding from square to square instead of redrawing.
public struct PieceLayout: Equatable, Sendable {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: Int
        public var square: Square
        public var piece: Piece
    }

    public private(set) var items: [Item] = []
    public private(set) var position: Position
    private var nextID = 0

    public init(position: Position) {
        self.position = position
        rebuild(from: position)
    }

    /// Moves to `newPosition`. If `move` explains the change, identities are
    /// carried along (including castling rooks, en passant and promotion);
    /// otherwise unchanged squares keep their identity.
    public mutating func update(to newPosition: Position, via move: Move?) {
        update(to: newPosition, candidates: [move].compactMap { $0 })
    }

    /// Tries each candidate as a forward move, then as an undone move.
    /// Pass the new and the previous "last move" so both moves and take-backs animate.
    public mutating func update(to newPosition: Position, candidates: [Move]) {
        guard newPosition != position else { return }
        for m in candidates where position.isLegal(m) {
            var expected = position
            expected.make(m)
            if expected.placementFEN == newPosition.placementFEN {
                apply(m, from: position)
                position = newPosition
                return
            }
        }
        for m in candidates where newPosition.isLegal(m) {
            var forward = newPosition
            forward.make(m)
            if forward.placementFEN == position.placementFEN {
                reverse(m, to: newPosition)
                position = newPosition
                return
            }
        }
        diff(to: newPosition)
        position = newPosition
    }

    private mutating func rebuild(from p: Position) {
        items = []
        for sq in Square.all {
            if let piece = p[sq] { items.append(Item(id: newID(), square: sq, piece: piece)) }
        }
    }

    private mutating func newID() -> Int {
        nextID += 1
        return nextID
    }

    private mutating func apply(_ m: Move, from p: Position) {
        // Remove captured piece (including en passant).
        var captureSquare: Square? = p[m.to] != nil ? m.to : nil
        if p.isEnPassant(m), let mover = p[m.from] {
            captureSquare = Square(m.to.index - 8 * mover.color.forward)
        }
        if let c = captureSquare { items.removeAll { $0.square == c } }
        if let i = items.firstIndex(where: { $0.square == m.from }) {
            items[i].square = m.to
            if let promo = m.promotion { items[i].piece = Piece(items[i].piece.color, promo) }
        }
        if p.isCastling(m) {
            let rank = m.from.rank
            let (rookFrom, rookTo) = m.to.file == 6 ? (7, 5) : (0, 3)
            if let i = items.firstIndex(where: { $0.square == Square(file: rookFrom, rank: rank)! }) {
                items[i].square = Square(file: rookTo, rank: rank)!
            }
        }
    }

    private mutating func reverse(_ m: Move, to p: Position) {
        if let i = items.firstIndex(where: { $0.square == m.to }) {
            items[i].square = m.from
            if m.promotion != nil, let original = p[m.from] { items[i].piece = original }
        }
        if p.isCastling(m) {
            let rank = m.from.rank
            let (rookHome, rookNow) = m.to.file == 6 ? (7, 5) : (0, 3)
            if let i = items.firstIndex(where: { $0.square == Square(file: rookNow, rank: rank)! }) {
                items[i].square = Square(file: rookHome, rank: rank)!
            }
        }
        // Restore whatever else differs (the captured piece).
        for sq in Square.all {
            if let piece = p[sq], !items.contains(where: { $0.square == sq }) {
                items.append(Item(id: newID(), square: sq, piece: piece))
            }
        }
    }

    private mutating func diff(to p: Position) {
        var kept: [Item] = []
        for sq in Square.all {
            guard let piece = p[sq] else { continue }
            if let existing = items.first(where: { $0.square == sq && $0.piece == piece }) {
                kept.append(existing)
            } else {
                kept.append(Item(id: newID(), square: sq, piece: piece))
            }
        }
        items = kept
    }

    public static func == (a: PieceLayout, b: PieceLayout) -> Bool { a.items == b.items }
}
