import Foundation

extension Position {

    /// Standard Algebraic Notation for a legal move, including +/# suffix.
    public func san(for move: Move) -> String {
        guard let piece = self[move.from] else { return move.uci }
        var s: String
        if isCastling(move) {
            s = move.to.file == 6 ? "O-O" : "O-O-O"
        } else if piece.kind == .pawn {
            s = ""
            if isCapture(move) { s += "\(move.from.fileLetter)x" }
            s += move.to.name
            if let promo = move.promotion { s += "=\(promo.sanLetter)" }
        } else {
            s = piece.kind.sanLetter
            let rivals = legalMoves().filter {
                $0.to == move.to && $0.from != move.from && self[$0.from] == piece
            }
            if !rivals.isEmpty {
                let sameFile = rivals.contains { $0.from.file == move.from.file }
                let sameRank = rivals.contains { $0.from.rank == move.from.rank }
                if !sameFile {
                    s.append(move.from.fileLetter)
                } else if !sameRank {
                    s += String(move.from.rank + 1)
                } else {
                    s += move.from.name
                }
            }
            if isCapture(move) { s += "x" }
            s += move.to.name
        }
        var after = self
        after.make(move)
        if after.isCheck { s += after.hasLegalMoves ? "+" : "#" }
        return s
    }

    /// Parses SAN leniently: accepts check marks, annotation glyphs,
    /// "0-0", missing "=" in promotions and "e.p." suffixes.
    public func move(fromSAN raw: String) throws -> Move {
        var text = raw.trimmingCharacters(in: .whitespaces)
        for suffix in ["e.p.", "ep"] where text.hasSuffix(suffix) && text.count > 4 {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        while let last = text.last, "+#!?".contains(last) { text.removeLast() }
        guard !text.isEmpty else { throw ChessError.invalidSAN(raw) }

        let legal = legalMoves()
        let castleText = text.replacingOccurrences(of: "0", with: "O")
        if castleText == "O-O" || castleText == "O-O-O" {
            let kingside = castleText == "O-O"
            if let m = legal.first(where: { isCastling($0) && ($0.to.file == 6) == kingside }) { return m }
            throw ChessError.illegalMove(raw)
        }

        // Also accept plain UCI input (e.g. from engines or tests).
        if let m = Move(uci: text), self[m.from] != nil {
            if legal.contains(m) { return m }
        }

        var chars = Array(text)
        var promotion: PieceKind?
        if chars.count >= 3, let last = chars.last, "QRBNqrbn".contains(last) {
            let prev = chars[chars.count - 2]
            if prev == "=" || ((prev == "8" || prev == "1") && last.isUppercase) {
                promotion = PieceKind(letter: last)
                chars.removeLast()
                if chars.last == "=" { chars.removeLast() }
            }
        }

        var kind: PieceKind = .pawn
        if let first = chars.first, "NBRQK".contains(first) {
            kind = PieceKind(letter: first)!
            chars.removeFirst()
        }
        chars.removeAll { $0 == "x" || $0 == "-" || $0 == ":" }
        guard chars.count >= 2,
              let target = Square(String(chars.suffix(2))) else { throw ChessError.invalidSAN(raw) }
        let disamb = chars.dropLast(2)
        var fromFile: Int?, fromRank: Int?
        for c in disamb {
            if let a = c.asciiValue, (97...104).contains(a) { fromFile = Int(a - 97) }
            else if let d = c.wholeNumberValue, (1...8).contains(d) { fromRank = d - 1 }
            else { throw ChessError.invalidSAN(raw) }
        }

        let candidates = legal.filter { m in
            guard m.to == target, let p = self[m.from], p.kind == kind else { return false }
            if let f = fromFile, m.from.file != f { return false }
            if let r = fromRank, m.from.rank != r { return false }
            return m.promotion == promotion
        }
        // King moves written as "Kg1" for castling are not accepted on purpose (SAN uses O-O).
        let nonCastle = candidates.filter { !(kind == .king && isCastling($0)) }
        if nonCastle.count == 1 { return nonCastle[0] }
        if nonCastle.isEmpty { throw ChessError.illegalMove(raw) }
        throw ChessError.ambiguousSAN(raw)
    }

    /// Plays a SAN move and returns the resulting position.
    public func playing(san: String) throws -> Position {
        let m = try move(fromSAN: san)
        var p = self
        p.make(m)
        return p
    }
}
