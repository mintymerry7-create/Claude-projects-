import Foundation
import Observation
import ChessCore
import OpeningDatabase
import Learning

/// Edits a repertoire: navigate the tree, add moves from the board, notes,
/// preferred moves, PGN import/export.
@Observable
public final class RepertoireEditor {
    public private(set) var repertoire: Repertoire
    public private(set) var nodeID: Int = MoveTree.rootID
    public private(set) var errorMessage: String?
    @ObservationIgnored public var onChange: ((Repertoire) -> Void)?

    public init(repertoire: Repertoire) {
        self.repertoire = repertoire
    }

    public var tree: MoveTree { repertoire.tree }
    public var position: Position { tree.position(at: nodeID) }
    public var node: MoveTree.Node { tree[nodeID] }
    public var children: [MoveTree.Node] { node.children.map { tree[$0] } }
    public var pathSANs: [String] { tree.sans(to: nodeID) }
    public var isOwnMove: Bool { position.sideToMove == repertoire.color }

    public var display: BoardDisplay {
        let arrows = node.children.compactMap { id -> Arrow? in
            guard let m = tree[id].move else { return nil }
            return Arrow(from: m.from, to: m.to, kind: repertoire.isPreferred(id) || id == node.children.first ? .plan : .suggestion)
        }
        return BoardDisplay(position: position, orientation: repertoire.color, lastMove: node.move, arrows: arrows)
    }

    /// Plays a move on the board: follows an existing branch or adds a new one.
    public func play(_ move: Move) {
        if let existing = tree.child(of: nodeID, playing: move) {
            nodeID = existing
            return
        }
        do {
            nodeID = try repertoire.addMove(move, after: nodeID)
            changed()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func goTo(_ id: Int) { if id < tree.count { nodeID = id } }
    public func back() { if let p = node.parent { nodeID = p } }
    public func forward() { if let c = node.children.first { nodeID = c } }
    public func toStart() { nodeID = MoveTree.rootID }

    public func setNote(_ text: String) {
        repertoire.setNote(text, for: nodeID)
        changed()
    }

    public func markPreferred() {
        guard nodeID != MoveTree.rootID else { return }
        repertoire.setPreferred(nodeID)
        changed()
    }

    public func deleteCurrent() {
        guard nodeID != MoveTree.rootID else { return }
        let parentPath = tree.moves(to: node.parent ?? MoveTree.rootID)
        repertoire.deleteNode(nodeID)
        // Re-find the parent after id re-packing.
        var cur = MoveTree.rootID
        for m in parentPath { cur = tree.child(of: cur, playing: m) ?? cur }
        nodeID = cur
        changed()
    }

    public func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        repertoire.name = trimmed
        changed()
    }

    public func add(opening: Opening, lineIDs: [String]? = nil) {
        do {
            try repertoire.add(opening: opening, lineIDs: lineIDs)
            changed()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Imports PGN text. Returns the number of new positions.
    @discardableResult
    public func importPGN(_ text: String) -> Int? {
        do {
            let n = try repertoire.importPGN(text)
            errorMessage = nil
            changed()
            return n
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func exportPGN() -> String { repertoire.exportPGN() }

    public func clearError() { errorMessage = nil }

    private func changed() { onChange?(repertoire) }
}
