import Foundation

enum Geometry {
    static let knightDeltas = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    static let kingDeltas = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    static let rookDirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    static let bishopDirs = [(1, 1), (1, -1), (-1, 1), (-1, -1)]

    static let knightTargets: [[Int]] = (0..<64).map { targets(from: $0, deltas: knightDeltas) }
    static let kingTargets: [[Int]] = (0..<64).map { targets(from: $0, deltas: kingDeltas) }

    /// rays[square][direction] = squares in that direction, nearest first.
    static let rookRays: [[[Int]]] = (0..<64).map { sq in rookDirs.map { ray(from: sq, dir: $0) } }
    static let bishopRays: [[[Int]]] = (0..<64).map { sq in bishopDirs.map { ray(from: sq, dir: $0) } }

    private static func targets(from sq: Int, deltas: [(Int, Int)]) -> [Int] {
        let f = sq & 7, r = sq >> 3
        return deltas.compactMap { d in
            let nf = f + d.0, nr = r + d.1
            return (0..<8).contains(nf) && (0..<8).contains(nr) ? nr * 8 + nf : nil
        }
    }

    private static func ray(from sq: Int, dir: (Int, Int)) -> [Int] {
        var out: [Int] = []
        var f = (sq & 7) + dir.0, r = (sq >> 3) + dir.1
        while (0..<8).contains(f) && (0..<8).contains(r) {
            out.append(r * 8 + f)
            f += dir.0; r += dir.1
        }
        return out
    }
}

extension Position {

    /// Whether `square` is attacked by any piece of `color`.
    public func isAttacked(_ square: Square, by color: PieceColor) -> Bool {
        let sq = square.index
        // Pawns: a pawn of `color` attacks sq if it sits diagonally "behind" it.
        let pr = (sq >> 3) - color.forward
        if (0..<8).contains(pr) {
            for df in [-1, 1] {
                let pf = (sq & 7) + df
                if (0..<8).contains(pf), board[pr * 8 + pf] == Piece(color, .pawn) { return true }
            }
        }
        for t in Geometry.knightTargets[sq] where board[t] == Piece(color, .knight) { return true }
        for t in Geometry.kingTargets[sq] where board[t] == Piece(color, .king) { return true }
        for ray in Geometry.rookRays[sq] {
            for t in ray {
                if let p = board[t] {
                    if p.color == color && (p.kind == .rook || p.kind == .queen) { return true }
                    break
                }
            }
        }
        for ray in Geometry.bishopRays[sq] {
            for t in ray {
                if let p = board[t] {
                    if p.color == color && (p.kind == .bishop || p.kind == .queen) { return true }
                    break
                }
            }
        }
        return false
    }

    /// Squares of pieces of `color` that attack `square`.
    public func attackers(of square: Square, by color: PieceColor) -> [Square] {
        var out: [Square] = []
        for (sq, piece) in pieces(of: color) where attacks(from: sq, piece: piece).contains(square) {
            out.append(sq)
        }
        return out
    }

    /// Squares attacked by the piece standing on `from` (ignores pins/legality).
    public func attacks(from: Square, piece: Piece? = nil) -> [Square] {
        guard let p = piece ?? self[from] else { return [] }
        let sq = from.index
        var out: [Int] = []
        switch p.kind {
        case .pawn:
            let r = (sq >> 3) + p.color.forward
            if (0..<8).contains(r) {
                for df in [-1, 1] {
                    let f = (sq & 7) + df
                    if (0..<8).contains(f) { out.append(r * 8 + f) }
                }
            }
        case .knight: out = Geometry.knightTargets[sq]
        case .king: out = Geometry.kingTargets[sq]
        case .bishop, .rook, .queen:
            var rays: [[Int]] = []
            if p.kind != .bishop { rays += Geometry.rookRays[sq] }
            if p.kind != .rook { rays += Geometry.bishopRays[sq] }
            for ray in rays {
                for t in ray {
                    out.append(t)
                    if board[t] != nil { break }
                }
            }
        }
        return out.map(Square.init)
    }

    /// Pseudo-legal moves (may leave own king in check). Castling is fully checked.
    public func pseudoLegalMoves() -> [Move] {
        var moves: [Move] = []
        moves.reserveCapacity(48)
        let us = sideToMove
        for i in 0..<64 {
            guard let p = board[i], p.color == us else { continue }
            let from = Square(i)
            switch p.kind {
            case .pawn: addPawnMoves(from: i, color: us, into: &moves)
            case .knight:
                for t in Geometry.knightTargets[i] where board[t]?.color != us {
                    moves.append(Move(from: from, to: Square(t)))
                }
            case .king:
                for t in Geometry.kingTargets[i] where board[t]?.color != us {
                    moves.append(Move(from: from, to: Square(t)))
                }
                addCastling(from: i, color: us, into: &moves)
            case .bishop, .rook, .queen:
                var rays: [[Int]] = []
                if p.kind != .bishop { rays += Geometry.rookRays[i] }
                if p.kind != .rook { rays += Geometry.bishopRays[i] }
                for ray in rays {
                    for t in ray {
                        if let q = board[t] {
                            if q.color != us { moves.append(Move(from: from, to: Square(t))) }
                            break
                        }
                        moves.append(Move(from: from, to: Square(t)))
                    }
                }
            }
        }
        return moves
    }

    private func addPawnMoves(from i: Int, color: PieceColor, into moves: inout [Move]) {
        let dir = color.forward
        let rank = i >> 3, file = i & 7
        let startRank = color == .white ? 1 : 6
        let promoRank = color == .white ? 7 : 0
        let from = Square(i)

        func add(_ to: Int) {
            if to >> 3 == promoRank {
                for k in PieceKind.promotionChoices { moves.append(Move(from: from, to: Square(to), promotion: k)) }
            } else {
                moves.append(Move(from: from, to: Square(to)))
            }
        }

        let one = i + 8 * dir
        if (0..<64).contains(one), board[one] == nil {
            add(one)
            let two = i + 16 * dir
            if rank == startRank, board[two] == nil { add(two) }
        }
        let nr = rank + dir
        guard (0..<8).contains(nr) else { return }
        for df in [-1, 1] {
            let nf = file + df
            guard (0..<8).contains(nf) else { continue }
            let t = nr * 8 + nf
            if let q = board[t], q.color != color {
                add(t)
            } else if let ep = enPassant, ep.index == t {
                add(t)
            }
        }
    }

    private func addCastling(from i: Int, color: PieceColor, into moves: inout [Move]) {
        let home = color == .white ? 4 : 60
        guard i == home else { return }
        let them = color.opposite
        if castling.contains(.kingside(color)),
           board[home + 1] == nil, board[home + 2] == nil,
           board[home + 3] == Piece(color, .rook),
           !isAttacked(Square(home), by: them),
           !isAttacked(Square(home + 1), by: them),
           !isAttacked(Square(home + 2), by: them) {
            moves.append(Move(from: Square(home), to: Square(home + 2)))
        }
        if castling.contains(.queenside(color)),
           board[home - 1] == nil, board[home - 2] == nil, board[home - 3] == nil,
           board[home - 4] == Piece(color, .rook),
           !isAttacked(Square(home), by: them),
           !isAttacked(Square(home - 1), by: them),
           !isAttacked(Square(home - 2), by: them) {
            moves.append(Move(from: Square(home), to: Square(home - 2)))
        }
    }

    /// All legal moves for the side to move.
    public func legalMoves() -> [Move] {
        var scratch = self
        let us = sideToMove
        return pseudoLegalMoves().filter { m in
            let u = scratch.make(m)
            let ok = !scratch.isKingAttacked(us)
            scratch.unmake(m, u)
            return ok
        }
    }

    public func legalMoves(from square: Square) -> [Move] {
        legalMoves().filter { $0.from == square }
    }

    public var hasLegalMoves: Bool { !legalMoves().isEmpty }
    public var isCheckmate: Bool { isCheck && !hasLegalMoves }
    public var isStalemate: Bool { !isCheck && !hasLegalMoves }

    /// Dead positions recognised by FIDE practice: K v K, K+minor v K,
    /// and kings with bishops all on one square colour.
    public var hasInsufficientMaterial: Bool {
        var minors: [(Piece, Square)] = []
        for i in 0..<64 {
            guard let p = board[i], p.kind != .king else { continue }
            switch p.kind {
            case .pawn, .rook, .queen: return false
            default: minors.append((p, Square(i)))
            }
        }
        if minors.count <= 1 { return true }
        if minors.allSatisfy({ $0.0.kind == .bishop }) {
            let colors = Set(minors.map { $0.1.isLight })
            return colors.count == 1
        }
        return false
    }

    /// Counts leaf nodes of the legal move tree (for rules verification).
    public func perft(_ depth: Int) -> Int {
        if depth == 0 { return 1 }
        let moves = legalMoves()
        if depth == 1 { return moves.count }
        var p = self
        var n = 0
        for m in moves {
            let u = p.make(m)
            n += p.perft(depth - 1)
            p.unmake(m, u)
        }
        return n
    }
}
