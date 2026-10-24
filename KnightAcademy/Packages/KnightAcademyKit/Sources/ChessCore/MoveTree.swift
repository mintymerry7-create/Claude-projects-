import Foundation

/// A tree of moves (main line + variations) starting from a root position.
/// Nodes are stored flat with integer ids so the tree is Codable and cheap to
/// diff in SwiftUI. Node 0 is the root (no move). The first child of a node is
/// its main continuation.
public struct MoveTree: Codable, Hashable, Sendable {

    public struct Node: Codable, Hashable, Sendable, Identifiable {
        public let id: Int
        public let parent: Int?
        public let move: Move?
        public let san: String
        /// FEN of the position after this node's move (root: start FEN).
        public let fen: String
        public let ply: Int
        public var children: [Int]
        public var comment: String?
        public var nags: [Int]

        public var isRoot: Bool { parent == nil }
    }

    public private(set) var nodes: [Node]
    public static let rootID = 0

    public init(startFEN: String = Position.startFEN) {
        let fen = (try? Position(fen: startFEN))?.fen ?? startFEN
        nodes = [Node(id: 0, parent: nil, move: nil, san: "", fen: fen, ply: 0, children: [], comment: nil, nags: [])]
    }

    public var root: Node { nodes[0] }
    public var startPosition: Position { (try? Position(fen: nodes[0].fen)) ?? .start }
    public subscript(id: Int) -> Node { nodes[id] }
    public var count: Int { nodes.count }

    public func position(at id: Int) -> Position {
        (try? Position(fen: nodes[id].fen)) ?? .start
    }

    /// Adds a move as a child of `parent`, reusing an existing child with the
    /// same move. Throws if the move is illegal.
    @discardableResult
    public mutating func add(_ move: Move, after parent: Int) throws -> Int {
        if let existing = nodes[parent].children.first(where: { nodes[$0].move == move }) { return existing }
        let pos = position(at: parent)
        guard pos.isLegal(move) else { throw ChessError.illegalMove(move.uci) }
        let san = pos.san(for: move)
        var next = pos
        next.make(move)
        let id = nodes.count
        nodes.append(Node(id: id, parent: parent, move: move, san: san, fen: next.fen,
                          ply: nodes[parent].ply + 1, children: [], comment: nil, nags: []))
        nodes[parent].children.append(id)
        return id
    }

    @discardableResult
    public mutating func add(san: String, after parent: Int) throws -> Int {
        let m = try position(at: parent).move(fromSAN: san)
        return try add(m, after: parent)
    }

    /// Adds a whole line of SAN moves from `parent`; returns the last node id.
    @discardableResult
    public mutating func addLine(sans: [String], from parent: Int = MoveTree.rootID) throws -> Int {
        var cur = parent
        for s in sans { cur = try add(san: s, after: cur) }
        return cur
    }

    public mutating func setComment(_ comment: String?, for id: Int) {
        nodes[id].comment = (comment?.isEmpty ?? true) ? nil : comment
    }

    public mutating func addNAG(_ nag: Int, for id: Int) {
        if !nodes[id].nags.contains(nag) { nodes[id].nags.append(nag) }
    }

    /// Makes `id` the first (main) child of its parent.
    public mutating func promoteToMain(_ id: Int) {
        guard let p = nodes[id].parent, let idx = nodes[p].children.firstIndex(of: id), idx > 0 else { return }
        nodes[p].children.remove(at: idx)
        nodes[p].children.insert(id, at: 0)
    }

    /// Removes a node and its subtree. Ids of remaining nodes are re-packed.
    public mutating func delete(_ id: Int) {
        guard id != Self.rootID else { return }
        var doomed = Set<Int>()
        var stack = [id]
        while let n = stack.popLast() {
            doomed.insert(n)
            stack.append(contentsOf: nodes[n].children)
        }
        var rebuilt = MoveTree(startFEN: nodes[0].fen)
        rebuilt.nodes[0].comment = nodes[0].comment
        func copy(_ old: Int, into newParent: Int) {
            for c in nodes[old].children where !doomed.contains(c) {
                guard let m = nodes[c].move, let nid = try? rebuilt.add(m, after: newParent) else { continue }
                rebuilt.nodes[nid].comment = nodes[c].comment
                rebuilt.nodes[nid].nags = nodes[c].nags
                copy(c, into: nid)
            }
        }
        copy(Self.rootID, into: Self.rootID)
        self = rebuilt
    }

    /// Node ids from the root (exclusive) to `id` (inclusive).
    public func path(to id: Int) -> [Int] {
        var out: [Int] = []
        var cur: Int? = id
        while let c = cur, c != Self.rootID {
            out.append(c)
            cur = nodes[c].parent
        }
        return out.reversed()
    }

    public func sans(to id: Int) -> [String] { path(to: id).map { nodes[$0].san } }
    public func moves(to id: Int) -> [Move] { path(to: id).compactMap { nodes[$0].move } }

    /// Main line from a node following first children.
    public func mainline(from id: Int = MoveTree.rootID) -> [Int] {
        var out: [Int] = []
        var cur = id
        while let next = nodes[cur].children.first {
            out.append(next)
            cur = next
        }
        return out
    }

    public var leaves: [Int] { nodes.filter { $0.children.isEmpty && !$0.isRoot }.map(\.id) }

    /// All root-to-leaf lines as node-id paths, main line first.
    public var allLines: [[Int]] {
        var out: [[Int]] = []
        func walk(_ id: Int, _ acc: [Int]) {
            let n = nodes[id]
            if n.children.isEmpty {
                if !acc.isEmpty { out.append(acc) }
                return
            }
            for c in n.children { walk(c, acc + [c]) }
        }
        walk(Self.rootID, [])
        return out
    }

    public func child(of id: Int, playing move: Move) -> Int? {
        nodes[id].children.first { nodes[$0].move == move }
    }

    /// Finds a node whose position matches (repetition key), preferring shallow nodes.
    public func node(matching position: Position) -> Int? {
        let key = position.repetitionKey
        return nodes.sorted { $0.ply < $1.ply }.first {
            ((try? Position(fen: $0.fen))?.repetitionKey) == key
        }?.id
    }

    public var maxPly: Int { nodes.map(\.ply).max() ?? 0 }
}
