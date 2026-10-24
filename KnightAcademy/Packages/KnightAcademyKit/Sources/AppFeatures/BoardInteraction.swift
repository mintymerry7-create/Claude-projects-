import Foundation
import ChessCore

/// Everything a board needs to draw one frame. Shared by lessons, puzzles,
/// games and analysis so all boards behave identically.
public struct BoardDisplay: Equatable, Sendable {
    public var position: Position
    public var orientation: PieceColor
    public var lastMove: Move?
    public var arrows: [Arrow]
    public var highlights: [Square]
    /// Squares to tint as hints (e.g. the piece to move).
    public var hintSquares: [Square]
    public var interactive: Bool

    public init(position: Position, orientation: PieceColor = .white, lastMove: Move? = nil,
                arrows: [Arrow] = [], highlights: [Square] = [], hintSquares: [Square] = [], interactive: Bool = true) {
        self.position = position
        self.orientation = orientation
        self.lastMove = lastMove
        self.arrows = arrows
        self.highlights = highlights
        self.hintSquares = hintSquares
        self.interactive = interactive
    }

    public var checkSquare: Square? {
        position.isCheck ? position.kingSquare(position.sideToMove) : nil
    }
}

/// Tap/drag selection logic for a board, independent of the UI.
public struct BoardInteraction: Equatable, Sendable {
    public private(set) var selected: Square?
    public private(set) var targets: [Square] = []
    /// A pawn move waiting for the user to choose a promotion piece.
    public private(set) var pendingPromotion: (from: Square, to: Square)?

    public init() {}

    public enum Outcome: Equatable {
        case none
        case selected
        case move(Move)
        case needsPromotion(from: Square, to: Square)
    }

    public mutating func clear() {
        selected = nil
        targets = []
        pendingPromotion = nil
    }

    /// Handles a tap. `side` restricts which pieces may be selected.
    public mutating func tap(_ square: Square, in position: Position, side: PieceColor?) -> Outcome {
        if let from = selected {
            if square == from {
                clear()
                return .none
            }
            if targets.contains(square) {
                return complete(from: from, to: square, in: position)
            }
        }
        if let piece = position[square], piece.color == position.sideToMove, side == nil || piece.color == side {
            selected = square
            targets = position.legalMoves(from: square).map(\.to)
            targets = Array(Set(targets)).sorted()
            return .selected
        }
        clear()
        return .none
    }

    /// Handles a drag from one square to another.
    public mutating func drag(from: Square, to: Square, in position: Position, side: PieceColor?) -> Outcome {
        guard let piece = position[from], piece.color == position.sideToMove, side == nil || piece.color == side else {
            clear()
            return .none
        }
        let legal = position.legalMoves(from: from).map(\.to)
        guard legal.contains(to) else {
            clear()
            return .none
        }
        return complete(from: from, to: to, in: position)
    }

    private mutating func complete(from: Square, to: Square, in position: Position) -> Outcome {
        let candidates = position.legalMoves(from: from).filter { $0.to == to }
        if candidates.count > 1, candidates.allSatisfy({ $0.promotion != nil }) {
            pendingPromotion = (from, to)
            selected = nil
            targets = []
            return .needsPromotion(from: from, to: to)
        }
        clear()
        guard let m = candidates.first else { return .none }
        return .move(m)
    }

    public mutating func choosePromotion(_ kind: PieceKind) -> Move? {
        guard let p = pendingPromotion else { return nil }
        pendingPromotion = nil
        return Move(from: p.from, to: p.to, promotion: kind)
    }

    public static func == (a: BoardInteraction, b: BoardInteraction) -> Bool {
        a.selected == b.selected && a.targets == b.targets
            && a.pendingPromotion?.from == b.pendingPromotion?.from && a.pendingPromotion?.to == b.pendingPromotion?.to
    }
}
