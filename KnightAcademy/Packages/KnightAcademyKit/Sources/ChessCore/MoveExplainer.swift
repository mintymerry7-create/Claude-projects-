import Foundation

/// Produces factual, board-derived explanations of a move: development,
/// center control, king safety, captures, checks, threats and pins.
/// Used when a lesson has no hand-written annotation for a move.
public enum MoveExplainer {

    public struct Explanation: Hashable, Sendable {
        public let sentences: [String]
        /// Squares worth highlighting (e.g. attacked pieces, controlled center squares).
        public let highlights: [Square]
        /// Arrows (from, to) illustrating threats created by the move.
        public let arrows: [Arrow]

        public var text: String { sentences.joined(separator: " ") }
    }

    static let center: Set<Square> = Set(["d4", "e4", "d5", "e5"].compactMap(Square.init))

    public static func explain(_ move: Move, in position: Position) -> Explanation {
        guard let piece = position[move.from], position.isLegal(move) else {
            return Explanation(sentences: [], highlights: [], arrows: [])
        }
        var s: [String] = []
        var highlights: [Square] = []
        var arrows: [Arrow] = []
        var after = position
        after.make(move)
        let us = piece.color, them = us.opposite
        let homeRank = us == .white ? 0 : 7

        if position.isCastling(move) {
            s.append("Castles \(move.to.file == 6 ? "kingside" : "queenside"): the king gets to safety and the rook joins the game.")
        } else if let captured = capturedPiece(move, position) {
            s.append("Captures the \(captured.kind.name) on \(position.isEnPassant(move) ? "\(move.to.name) en passant" : move.to.name).")
            if !after.attackers(of: move.to, by: them).isEmpty, captured.kind.value < piece.kind.value, captured.kind != .king {
                s.append("The \(piece.kind.name) can be recaptured, so check the exchange carefully.")
            }
        } else if piece.kind == .pawn {
            if let promo = move.promotion {
                s.append("Promotes the pawn to a \(promo.name).")
            } else if center.contains(move.to) {
                s.append("Puts a pawn in the center, claiming space and controlling key squares.")
            } else if [Square("g3"), Square("b3"), Square("g6"), Square("b6")].contains(move.to)
                        && abs(move.to.rank - move.from.rank) == 1 {
                s.append("Prepares a fianchetto: the bishop can develop to the long diagonal.")
            } else if [2, 3, 4, 5].contains(move.to.file) {
                s.append("Supports the fight for the center with a pawn.")
            } else {
                s.append("Gains space on the \(move.to.file < 4 ? "queenside" : "kingside").")
            }
        } else if (piece.kind == .knight || piece.kind == .bishop) && move.from.rank == homeRank {
            s.append("Develops the \(piece.kind.name) to \(move.to.name).")
        } else if piece.kind == .queen && position.fullmoveNumber <= 6 {
            s.append("Brings the queen out early; make sure it cannot be chased around with tempo.")
        } else if piece.kind == .rook && isOpenFile(move.to.file, in: after) {
            s.append("Puts the rook on the open \(move.to.fileLetter)-file.")
        } else {
            s.append("Moves the \(piece.kind.name) to \(move.to.name).")
        }

        if piece.kind == .bishop, isLongDiagonal(move.to) {
            s.append("The bishop now eyes the long diagonal.")
        }

        let attacked = after.attacks(from: move.to)
        let centerHits = attacked.filter { center.contains($0) }
        if piece.kind != .pawn || !center.contains(move.to), !centerHits.isEmpty, piece.kind != .king {
            s.append("It controls \(centerHits.map(\.name).sorted().joined(separator: " and ")).")
            highlights += centerHits
        }

        if after.isCheck {
            s.append(after.hasLegalMoves ? "Check!" : "Checkmate!")
        } else {
            // Direct threats against undefended or more valuable pieces.
            let targets = attacked.compactMap { sq -> (Square, Piece)? in
                guard let t = after[sq], t.color == them, t.kind != .king else { return nil }
                let defended = !after.attackers(of: sq, by: them).isEmpty
                return (!defended || t.kind.value > piece.kind.value) ? (sq, t) : nil
            }
            if targets.count >= 2 {
                s.append("It forks \(targets.map { "the \($0.1.kind.name) on \($0.0.name)" }.joined(separator: " and ")).")
            } else if let t = targets.first {
                s.append("It attacks the \(t.1.kind.name) on \(t.0.name).")
            }
            for t in targets.prefix(2) {
                arrows.append(Arrow(from: move.to, to: t.0, kind: .threat))
                highlights.append(t.0)
            }
            if let pin = pinCreated(by: move.to, in: after, attacker: us) {
                s.append("It pins the \(pin.pinned.kind.name) on \(pin.square.name) to the \(pin.behind.kind.name).")
                arrows.append(Arrow(from: move.to, to: pin.square, kind: .threat))
            }
        }

        if position.fullmoveNumber <= 10, piece.kind != .pawn, piece.kind != .king,
           move.from.rank != homeRank, !position.isCapture(move), !after.isCheck,
           position.attackers(of: move.from, by: them).isEmpty,
           (piece.kind == .knight || piece.kind == .bishop) {
            s.append("Moving the same piece twice in the opening costs time unless it achieves something concrete.")
        }

        return Explanation(sentences: s, highlights: Array(Set(highlights)), arrows: arrows)
    }

    /// A short imperative instruction such as "Play pawn to d4." or
    /// "Capture on d5 with the knight." used above the board in lessons.
    public static func instruction(for move: Move, in position: Position) -> String {
        guard let piece = position[move.from] else { return "Play \(move.uci)." }
        if position.isCastling(move) {
            return move.to.file == 6 ? "Castle kingside." : "Castle queenside."
        }
        if let promo = move.promotion {
            return position.isCapture(move)
                ? "Capture on \(move.to.name) and promote to a \(promo.name)."
                : "Promote the pawn on \(move.to.name) to a \(promo.name)."
        }
        if position.isCapture(move) {
            return "Capture on \(move.to.name) with the \(piece.kind.name)."
        }
        return "Play \(piece.kind.name) to \(move.to.name)."
    }

    static func capturedPiece(_ move: Move, _ p: Position) -> Piece? {
        if let c = p[move.to] { return c }
        if p.isEnPassant(move), let mover = p[move.from] { return Piece(mover.color.opposite, .pawn) }
        return nil
    }

    static func isOpenFile(_ file: Int, in p: Position) -> Bool {
        !(0..<8).contains { p.board[$0 * 8 + file]?.kind == .pawn }
    }

    static func isLongDiagonal(_ sq: Square) -> Bool {
        sq.file == sq.rank || sq.file + sq.rank == 7
    }

    struct Pin { let square: Square; let pinned: Piece; let behind: Piece }

    /// Detects a slider on `from` pinning an enemy piece to its king or queen.
    static func pinCreated(by from: Square, in p: Position, attacker: PieceColor) -> Pin? {
        guard let slider = p[from], [.bishop, .rook, .queen].contains(slider.kind) else { return nil }
        var dirs: [(Int, Int)] = []
        if slider.kind != .bishop { dirs += Geometry.rookDirs }
        if slider.kind != .rook { dirs += Geometry.bishopDirs }
        for d in dirs {
            var first: (Square, Piece)?
            var cur = from.offset(file: d.0, rank: d.1)
            while let sq = cur {
                if let piece = p[sq] {
                    if first == nil {
                        guard piece.color != attacker else { break }
                        first = (sq, piece)
                    } else {
                        if piece.color != attacker, piece.kind.value > first!.1.kind.value || piece.kind == .king,
                           first!.1.kind != .king {
                            return Pin(square: first!.0, pinned: first!.1, behind: piece)
                        }
                        break
                    }
                }
                cur = sq.offset(file: d.0, rank: d.1)
            }
        }
        return nil
    }
}

/// A board arrow for lessons and analysis.
public struct Arrow: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case suggestion, threat, engine, plan }
    public let from: Square
    public let to: Square
    public let kind: Kind

    public init(from: Square, to: Square, kind: Kind = .suggestion) {
        self.from = from
        self.to = to
        self.kind = kind
    }
}
