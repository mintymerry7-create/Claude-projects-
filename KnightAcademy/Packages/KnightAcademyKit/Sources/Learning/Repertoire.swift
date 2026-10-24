import Foundation
import ChessCore
import OpeningDatabase

public enum RepertoireError: Error, LocalizedError, Equatable {
    case wrongStartPosition
    case emptyImport
    case invalidFEN(String)

    public var errorDescription: String? {
        switch self {
        case .wrongStartPosition: return "The PGN starts from a different position than this repertoire."
        case .emptyImport: return "The PGN contains no moves."
        case .invalidFEN(let s): return "Invalid FEN: \(s)"
        }
    }
}

/// A personal opening repertoire for one colour: a move tree with notes,
/// preferred moves and links to library openings.
public struct Repertoire: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var color: PieceColor
    public var tree: MoveTree
    /// Node ids the user marked as their preferred move in that position.
    public var preferredNodes: [Int]
    public var openingIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(name: String, color: PieceColor, startFEN: String = Position.startFEN, now: Date = Date()) {
        id = UUID()
        self.name = name
        self.color = color
        tree = MoveTree(startFEN: startFEN)
        preferredNodes = []
        openingIDs = []
        createdAt = now
        updatedAt = now
    }

    /// Creates a repertoire rooted at an arbitrary FEN position.
    public static func fromFEN(_ fen: String, name: String, color: PieceColor? = nil) throws -> Repertoire {
        let p: Position
        do { p = try Position(fen: fen) } catch { throw RepertoireError.invalidFEN(error.localizedDescription) }
        return Repertoire(name: name, color: color ?? p.sideToMove, startFEN: p.fen)
    }

    public var isFromStandardStart: Bool { tree.root.fen == Position.start.fen }

    /// Adds the selected lines of a library opening (main line by default).
    @discardableResult
    public mutating func add(opening: Opening, lineIDs: [String]? = nil, maxPly: Int? = nil) throws -> Int {
        guard isFromStandardStart else { throw RepertoireError.wrongStartPosition }
        let wanted = lineIDs.map { ids in opening.lines.filter { ids.contains($0.id) } } ?? [opening.mainLine]
        var added = 0
        for line in wanted {
            let before = tree.count
            let moves = maxPly.map { Array(line.moves.prefix($0)) } ?? line.moves
            try tree.addLine(sans: moves)
            added += tree.count - before
        }
        if !openingIDs.contains(opening.id) { openingIDs.append(opening.id) }
        touch()
        return added
    }

    @discardableResult
    public mutating func addLine(sans: [String], from node: Int = MoveTree.rootID) throws -> Int {
        let id = try tree.addLine(sans: sans, from: node)
        touch()
        return id
    }

    @discardableResult
    public mutating func addMove(_ move: Move, after node: Int) throws -> Int {
        let id = try tree.add(move, after: node)
        touch()
        return id
    }

    public mutating func setNote(_ note: String?, for node: Int) {
        tree.setComment(note, for: node)
        touch()
    }

    /// Marks a node as the preferred move among its siblings (also makes it the main branch).
    public mutating func setPreferred(_ node: Int) {
        guard let parent = tree[node].parent else { return }
        preferredNodes.removeAll { tree[parent].children.contains($0) }
        preferredNodes.append(node)
        tree.promoteToMain(node)
        touch()
    }

    public func isPreferred(_ node: Int) -> Bool { preferredNodes.contains(node) }

    public mutating func deleteNode(_ node: Int) {
        // Preserve preferences by move path since ids are re-packed.
        let preferredPaths = preferredNodes.map { tree.moves(to: $0) }
        tree.delete(node)
        preferredNodes = preferredPaths.compactMap { path in
            var cur = MoveTree.rootID
            for m in path {
                guard let c = tree.child(of: cur, playing: m) else { return nil }
                cur = c
            }
            return cur
        }
        touch()
    }

    /// Merges every game and variation of a PGN into the tree.
    /// - Returns: number of new positions added.
    @discardableResult
    public mutating func importPGN(_ text: String) throws -> Int {
        let games = try PGNParser.parse(text)
        var added = 0
        for g in games {
            guard g.tree.root.fen.split(separator: " ").prefix(4) == tree.root.fen.split(separator: " ").prefix(4) else {
                throw RepertoireError.wrongStartPosition
            }
            func merge(_ src: Int, into dst: Int) throws {
                for c in g.tree[src].children {
                    guard let m = g.tree[c].move else { continue }
                    let before = tree.count
                    let nid = try tree.add(m, after: dst)
                    added += tree.count - before
                    if let comment = g.tree[c].comment, tree[nid].comment == nil { tree.setComment(comment, for: nid) }
                    try merge(c, into: nid)
                }
            }
            try merge(MoveTree.rootID, into: MoveTree.rootID)
        }
        if added == 0 && tree.count == 1 { throw RepertoireError.emptyImport }
        touch()
        return added
    }

    public func exportPGN() -> String {
        var tags = ["Event": name, "White": color == .white ? "Repertoire" : "?", "Black": color == .black ? "Repertoire" : "?"]
        if !isFromStandardStart {
            tags["SetUp"] = "1"
            tags["FEN"] = tree.root.fen
        }
        let game = PGNGame(tags: tags, tree: tree, result: "*")
        return PGNWriter.write(game: game)
    }

    /// Moves the owner must know (their colour to move), keyed like opening cards
    /// so progress is shared with opening courses.
    public var cards: [StudyCard] {
        var out: [StudyCard] = []
        var seen = Set<String>()
        let repertoireID = id.uuidString
        func walk(_ nodeID: Int, _ pos: Position) {
            for c in tree[nodeID].children {
                guard let m = tree[c].move else { continue }
                if pos.sideToMove == color {
                    let key = StudyPlan.cardKey(position: pos, move: m)
                    if seen.insert(key).inserted {
                        out.append(StudyCard(id: key, nodeID: c, move: m, san: tree[c].san,
                                             positionKey: pos.repetitionKey, lineIDs: [repertoireID]))
                    }
                }
                var next = pos
                next.make(m)
                walk(c, next)
            }
        }
        walk(MoveTree.rootID, tree.startPosition)
        return out
    }

    /// Book for practising the repertoire against a bot.
    public var lineCount: Int { tree.allLines.count }

    private mutating func touch() { updatedAt = Date() }
}
