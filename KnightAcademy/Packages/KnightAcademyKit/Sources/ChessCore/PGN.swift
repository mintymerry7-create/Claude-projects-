import Foundation

public enum PGNError: Error, Equatable, LocalizedError {
    case empty
    case unterminatedComment
    case unbalancedVariation
    case badTag(String)
    case badFEN(String)
    case illegalMove(san: String, moveNumber: String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "No moves or games were found."
        case .unterminatedComment: return "A comment “{” is never closed."
        case .unbalancedVariation: return "Variation parentheses do not match."
        case .badTag(let t): return "Malformed tag: \(t)"
        case .badFEN(let f): return "The FEN tag is invalid: \(f)"
        case let .illegalMove(san, number): return "Illegal or unreadable move “\(san)” at \(number)"
        }
    }
}

/// One game from a PGN file.
public struct PGNGame: Sendable, Hashable {
    public var tags: [String: String]
    public var tree: MoveTree
    public var result: String

    public init(tags: [String: String], tree: MoveTree, result: String) {
        self.tags = tags
        self.tree = tree
        self.result = result
    }

    public var startPosition: Position { tree.startPosition }
    public var mainlineSANs: [String] { tree.mainline().map { tree[$0].san } }
    public var title: String {
        if let opening = tags["Opening"] { return opening }
        let w = tags["White"] ?? "?", b = tags["Black"] ?? "?"
        return (w == "?" && b == "?") ? (tags["Event"] ?? "Imported game") : "\(w) – \(b)"
    }

    /// The main line as a playable game.
    public func mainlineGame() throws -> ChessGame {
        var g = ChessGame(startPosition: startPosition)
        for id in tree.mainline() {
            if let m = tree[id].move { try g.play(m) }
        }
        return g
    }
}

public enum PGNParser {

    enum Token: Equatable {
        case tag(String, String)
        case moveNumber(String)
        case san(String)
        case nag(Int)
        case comment(String)
        case open, close
        case result(String)
    }

    /// Parses one or more games. Variations, comments and NAGs are kept.
    public static func parse(_ text: String) throws -> [PGNGame] {
        let tokens = try tokenize(text)
        var games: [PGNGame] = []
        var i = 0
        while i < tokens.count {
            var tags: [String: String] = [:]
            while i < tokens.count, case let .tag(k, v) = tokens[i] {
                tags[k] = v
                i += 1
            }
            var body: [Token] = []
            var result = "*"
            while i < tokens.count {
                if case .tag = tokens[i] { break }
                if case let .result(r) = tokens[i] {
                    result = r
                    i += 1
                    break
                }
                body.append(tokens[i])
                i += 1
            }
            if tags.isEmpty && body.isEmpty { continue }
            games.append(try buildGame(tags: tags, body: body, result: result))
        }
        guard !games.isEmpty else { throw PGNError.empty }
        return games
    }

    /// Convenience: the first game.
    public static func parseFirst(_ text: String) throws -> PGNGame {
        try parse(text)[0]
    }

    private static func buildGame(tags: [String: String], body: [Token], result: String) throws -> PGNGame {
        var startFEN = Position.startFEN
        if let fen = tags["FEN"] {
            guard (try? Position(fen: fen)) != nil else { throw PGNError.badFEN(fen) }
            startFEN = fen
        }
        var tree = MoveTree(startFEN: startFEN)
        var current = MoveTree.rootID
        var previous = MoveTree.rootID
        var stack: [(Int, Int)] = []
        var lastNumber = "start"
        var pendingComment: String?

        for tok in body {
            switch tok {
            case .moveNumber(let n):
                lastNumber = n
            case .san(let san):
                let pos = tree.position(at: current)
                let move: Move
                do { move = try pos.move(fromSAN: san) } catch {
                    throw PGNError.illegalMove(san: san, moveNumber: lastNumber == "start" ? "the first move" : "move \(lastNumber)")
                }
                let id = try tree.add(move, after: current)
                if let c = pendingComment { tree.setComment(c, for: id); pendingComment = nil }
                previous = current
                current = id
            case .nag(let n):
                if current != MoveTree.rootID { tree.addNAG(n, for: current) }
            case .comment(let c):
                let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { break }
                if current == MoveTree.rootID {
                    tree.setComment(trimmed, for: MoveTree.rootID)
                } else {
                    let existing = tree[current].comment
                    tree.setComment(existing.map { $0 + " " + trimmed } ?? trimmed, for: current)
                }
            case .open:
                stack.append((current, previous))
                current = previous
            case .close:
                guard let (c, p) = stack.popLast() else { throw PGNError.unbalancedVariation }
                current = c
                previous = p
            case .tag, .result:
                break
            }
        }
        guard stack.isEmpty else { throw PGNError.unbalancedVariation }
        return PGNGame(tags: tags, tree: tree, result: tags["Result"] ?? result)
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        func peek(_ k: Int = 0) -> Character? { i + k < chars.count ? chars[i + k] : nil }

        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            switch c {
            case "[":
                var j = i + 1
                var inQuote = false
                while j < chars.count {
                    if chars[j] == "\\" && inQuote { j += 2; continue }
                    if chars[j] == "\"" { inQuote.toggle() }
                    if chars[j] == "]" && !inQuote { break }
                    j += 1
                }
                guard j < chars.count else { throw PGNError.badTag(String(chars[i..<min(chars.count, i + 40)])) }
                let inner = String(chars[(i + 1)..<j]).trimmingCharacters(in: .whitespaces)
                guard let sp = inner.firstIndex(of: " ") else { throw PGNError.badTag(inner) }
                let key = String(inner[..<sp])
                var value = String(inner[sp...]).trimmingCharacters(in: .whitespaces)
                guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { throw PGNError.badTag(inner) }
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                tokens.append(.tag(key, value))
                i = j + 1
            case "{":
                guard let end = chars[(i + 1)...].firstIndex(of: "}") else { throw PGNError.unterminatedComment }
                tokens.append(.comment(String(chars[(i + 1)..<end])))
                i = end + 1
            case ";":
                var j = i + 1
                while j < chars.count && chars[j] != "\n" { j += 1 }
                tokens.append(.comment(String(chars[(i + 1)..<j])))
                i = j
            case "%" where i == 0 || chars[i - 1] == "\n":
                while i < chars.count && chars[i] != "\n" { i += 1 }
            case "(":
                tokens.append(.open); i += 1
            case ")":
                tokens.append(.close); i += 1
            case "$":
                var j = i + 1
                while j < chars.count, chars[j].isNumber { j += 1 }
                if let n = Int(String(chars[(i + 1)..<j])) { tokens.append(.nag(n)) }
                i = j
            default:
                var j = i
                while j < chars.count, !chars[j].isWhitespace, !"{}()[];$".contains(chars[j]) { j += 1 }
                var word = String(chars[i..<j])
                i = max(j, i + 1)
                if ["1-0", "0-1", "1/2-1/2", "*", "½-½"].contains(word) {
                    tokens.append(.result(word == "½-½" ? "1/2-1/2" : word))
                    continue
                }
                // Move numbers: "12." "12..." possibly glued to the move: "12.e4"
                if let first = word.first, first.isNumber {
                    let digits = word.prefix { $0.isNumber }
                    let rest = word.dropFirst(digits.count)
                    if rest.hasPrefix(".") {
                        tokens.append(.moveNumber(String(digits)))
                        word = String(rest.drop { $0 == "." })
                        if word.isEmpty { continue }
                    } else if word.hasPrefix("0-0") {
                        // castling written with zeros, fall through
                    } else {
                        continue
                    }
                }
                // Trailing glyphs like "e4!?" become NAGs.
                var glyph = ""
                while let l = word.last, "!?".contains(l) { glyph = String(l) + glyph; word.removeLast() }
                if !word.isEmpty { tokens.append(.san(word)) }
                if let nag = glyphNAG[glyph] { tokens.append(.nag(nag)) }
            }
        }
        return tokens
    }

    static let glyphNAG: [String: Int] = ["!": 1, "?": 2, "!!": 3, "??": 4, "!?": 5, "?!": 6]
}

public enum PGNWriter {
    static let tagOrder = ["Event", "Site", "Date", "Round", "White", "Black", "Result"]

    public static func write(tags: [String: String], movetext: String, result: String) -> String {
        var lines: [String] = []
        var t = tags
        for k in tagOrder {
            let v = t.removeValue(forKey: k) ?? (k == "Result" ? result : "?")
            lines.append("[\(k) \"\(escape(v))\"]")
        }
        for k in t.keys.sorted() { lines.append("[\(k) \"\(escape(t[k]!))\"]") }
        lines.append("")
        lines.append(wrap(movetext.isEmpty ? result : movetext + " " + result))
        return lines.joined(separator: "\n") + "\n"
    }

    public static func write(game: PGNGame) -> String {
        write(tags: game.tags, movetext: movetext(for: game.tree), result: game.result)
    }

    /// Movetext for a tree including variations and comments.
    public static func movetext(for tree: MoveTree) -> String {
        var parts: [String] = []
        if let c = tree.root.comment { parts.append("{\(c)}") }
        let start = tree.startPosition
        func label(_ node: MoveTree.Node, forceNumber: Bool) -> String {
            let l = Notation.moveNumberLabel(ply: node.ply - 1, startPosition: start)
            let isWhite = !l.hasSuffix("...")
            return (isWhite || forceNumber) ? l + " " : ""
        }
        func emit(node id: Int, forceNumber: Bool) {
            let n = tree[id]
            var s = label(n, forceNumber: forceNumber) + n.san
            for nag in n.nags { s += " $\(nag)" }
            parts.append(s)
            if let c = n.comment { parts.append("{\(c)}") }
        }
        func walk(from id: Int, force initial: Bool) {
            var cur = id
            var force = initial
            while let main = tree[cur].children.first {
                emit(node: main, forceNumber: force)
                force = tree[main].comment != nil
                let alts = tree[cur].children.dropFirst()
                for alt in alts {
                    parts.append("(")
                    emit(node: alt, forceNumber: true)
                    walk(from: alt, force: tree[alt].comment != nil)
                    parts.append(")")
                    force = true
                }
                cur = main
            }
        }
        walk(from: MoveTree.rootID, force: true)
        return parts.joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(")
            .replacingOccurrences(of: " )", with: ")")
    }

    private static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "\\\"") }

    static func wrap(_ text: String, width: Int = 80) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.count + word.count + 1 > width, !line.isEmpty {
                lines.append(line)
                line = String(word)
            } else {
                line += line.isEmpty ? String(word) : " " + word
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}
