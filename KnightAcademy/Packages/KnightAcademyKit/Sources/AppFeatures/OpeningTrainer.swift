import Foundation
import Observation
import ChessCore
import OpeningDatabase
import Learning

public enum TrainerMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The app shows each move with an explanation; the learner plays it along.
    case learn
    /// The learner must find the moves from memory; graded with spaced repetition.
    case memory

    public var id: String { rawValue }
    public var displayName: String { self == .learn ? "Learn" : "Play from memory" }
}

public enum TrainerFeedback: Equatable, Sendable {
    case idle
    case correct(san: String)
    /// A different move that is also part of the plan (another branch).
    case alternative(san: String)
    case incorrect(san: String, hint: String)
    case revealed(san: String)
    case lineComplete(name: String)
    case sessionComplete
}

/// Drives "Learn" and "Play from memory" for an opening study plan.
/// Lines are studied one at a time; any move that exists in the plan is
/// accepted (branches are explicit alternatives), other moves are mistakes.
@Observable
public final class OpeningTrainer {
    public let plan: StudyPlan
    public let mode: TrainerMode
    public private(set) var nodeID: Int = MoveTree.rootID
    public private(set) var feedback: TrainerFeedback = .idle
    public private(set) var hintLevel = 0
    public private(set) var mistakesHere = 0
    public private(set) var currentLine: StudyLine?
    public private(set) var completedLineIDs: [String] = []
    public private(set) var queue: [StudyLine]
    public private(set) var gradedCount = 0
    public private(set) var correctCount = 0
    /// Learner moves shown in learn mode.
    public private(set) var learnedCount = 0
    /// Root of the session ("practice from here").
    public let startNodeID: Int

    /// Called when a card is graded (memory mode). The app persists it.
    @ObservationIgnored public var onGrade: ((StudyCard, RecallGrade, Position) -> Void)?
    /// Called whenever the position changes, for resume support.
    @ObservationIgnored public var onProgress: ((_ sans: [String]) -> Void)?

    private let cardsByNode: [Int: StudyCard]

    public init(plan: StudyPlan, mode: TrainerMode, startNodeID: Int = MoveTree.rootID,
                prioritise cardIDs: Set<String> = []) {
        self.plan = plan
        self.mode = mode
        self.startNodeID = startNodeID
        var map: [Int: StudyCard] = [:]
        for c in plan.cards { map[c.nodeID] = c }
        cardsByNode = map
        // Lines through the start node, lines with prioritised (due/new) cards first.
        let through = plan.lines.filter { line in
            startNodeID == MoveTree.rootID || plan.nodeLines[startNodeID]?.contains(line.id) == true
        }
        if cardIDs.isEmpty {
            queue = through
        } else {
            let lineIDsWithPriority = Set(plan.cards.filter { cardIDs.contains($0.id) }.flatMap(\.lineIDs))
            queue = through.filter { lineIDsWithPriority.contains($0.id) } + through.filter { !lineIDsWithPriority.contains($0.id) }
        }
        startNextLine()
    }

    // MARK: State

    public var position: Position { plan.tree.position(at: nodeID) }
    public var learnerSide: PieceColor { plan.learnerSide }
    public var lastMove: Move? { plan.tree[nodeID].move }
    public var note: String? { plan.notes[nodeID] }
    public var plyInLine: Int { plan.tree[nodeID].ply }
    public var isFinished: Bool { feedback == .sessionComplete }
    public var totalLines: Int { completedLineIDs.count + queue.count + (currentLine == nil ? 0 : 1) }

    /// The next move of the current line, if the current node lies on it.
    public var nextLineMove: Move? {
        guard let line = currentLine else { return nil }
        let path = plan.tree.path(to: line.leafNodeID)
        let ply = plan.tree[nodeID].ply
        guard ply < path.count else { return nil }
        if ply > 0 && path[ply - 1] != nodeID { return nil }
        return plan.tree[path[ply]].move
    }

    public var isLearnerTurn: Bool {
        position.sideToMove == learnerSide && nextLineMove != nil && feedback != .sessionComplete
    }

    public var isOpponentTurn: Bool {
        position.sideToMove != learnerSide && nextLineMove != nil && feedback != .sessionComplete
    }

    /// Board decorations for the current state.
    public var display: BoardDisplay {
        var arrows: [Arrow] = []
        var hints: [Square] = []
        if let next = nextLineMove, isLearnerTurn {
            if mode == .learn {
                arrows.append(Arrow(from: next.from, to: next.to, kind: .suggestion))
            } else {
                if hintLevel >= 1 { hints.append(next.from) }
                if hintLevel >= 2 { arrows.append(Arrow(from: next.from, to: next.to, kind: .suggestion)) }
            }
        }
        return BoardDisplay(position: position, orientation: learnerSide, lastMove: lastMove,
                            arrows: arrows, hintSquares: hints, interactive: isLearnerTurn)
    }

    /// Explanation for the move just played (hand-written note or generated).
    public var explanation: String? {
        if let n = note { return n }
        guard let m = lastMove, let parent = plan.tree[nodeID].parent else { return nil }
        let e = MoveExplainer.explain(m, in: plan.tree.position(at: parent))
        return e.text.isEmpty ? nil : e.text
    }

    /// In learn mode: the explanation of the move the learner is about to play.
    public var upcomingExplanation: String? {
        guard mode == .learn, isLearnerTurn, let m = nextLineMove, let child = plan.tree.child(of: nodeID, playing: m) else { return nil }
        if let n = plan.notes[child] { return n }
        return MoveExplainer.explain(m, in: position).text
    }

    // MARK: Actions

    /// Submits a learner move.
    @discardableResult
    public func submit(_ move: Move) -> TrainerFeedback {
        guard isLearnerTurn, let expected = nextLineMove else { return feedback }
        let pos = position
        let san = pos.san(for: move)
        if move == expected {
            grade(nodeChild: plan.tree.child(of: nodeID, playing: move), correct: true)
            advance(to: plan.tree.child(of: nodeID, playing: move)!)
            feedback = .correct(san: san)
        } else if let child = plan.tree.child(of: nodeID, playing: move) {
            // Another branch of the plan: accept and follow it.
            grade(nodeChild: child, correct: true)
            if let line = lineThrough(child) { switchLine(to: line) }
            advance(to: child)
            feedback = .alternative(san: san)
        } else {
            mistakesHere += 1
            feedback = .incorrect(san: san, hint: Self.hintText(for: expected, in: pos))
            return feedback
        }
        checkLineEnd()
        return feedback
    }

    /// Plays the opponent's move of the current line.
    @discardableResult
    public func playOpponentMove() -> Move? {
        guard isOpponentTurn, let m = nextLineMove, let child = plan.tree.child(of: nodeID, playing: m) else { return nil }
        advance(to: child)
        checkLineEnd()
        return m
    }

    /// Shows a stronger hint: 1 = piece, 2 = arrow, 3 = reveal (plays the move).
    public func hint() {
        guard isLearnerTurn, let expected = nextLineMove else { return }
        hintLevel = min(3, hintLevel + 1)
        if hintLevel == 3 {
            let san = position.san(for: expected)
            grade(nodeChild: plan.tree.child(of: nodeID, playing: expected), correct: false)
            advance(to: plan.tree.child(of: nodeID, playing: expected)!)
            feedback = .revealed(san: san)
            checkLineEnd()
        }
    }

    /// In learn mode: play the shown move for the learner.
    public func playShownMove() {
        guard mode == .learn, let m = nextLineMove else { return }
        if isLearnerTurn { submit(m) } else { playOpponentMove() }
    }

    /// Steps back to the learner's previous decision in the current line.
    public func undo() {
        var cur = nodeID
        while cur != startNodeID, let parent = plan.tree[cur].parent {
            cur = parent
            if plan.tree.position(at: cur).sideToMove == learnerSide { break }
        }
        nodeID = cur
        hintLevel = 0
        mistakesHere = 0
        feedback = .idle
        onProgress?(plan.tree.sans(to: nodeID))
    }

    public func restartLine() {
        nodeID = startNodeID
        hintLevel = 0
        mistakesHere = 0
        feedback = .idle
    }

    public func continueAfterLine() {
        if case .lineComplete = feedback { startNextLine() }
    }

    // MARK: Internals

    private func startNextLine() {
        if let line = currentLine { completedLineIDs.append(line.id) }
        guard !queue.isEmpty else {
            currentLine = nil
            feedback = .sessionComplete
            return
        }
        currentLine = queue.removeFirst()
        nodeID = startNodeID
        hintLevel = 0
        mistakesHere = 0
        feedback = .idle
    }

    private func switchLine(to line: StudyLine) {
        guard line.id != currentLine?.id else { return }
        if let cur = currentLine { queue.insert(cur, at: 0) }
        queue.removeAll { $0.id == line.id }
        currentLine = line
    }

    private func lineThrough(_ node: Int) -> StudyLine? {
        let ids = plan.nodeLines[node] ?? []
        return queue.first { ids.contains($0.id) } ?? plan.lines.first { ids.contains($0.id) }
    }

    private func advance(to child: Int) {
        nodeID = child
        hintLevel = 0
        mistakesHere = 0
        onProgress?(plan.tree.sans(to: nodeID))
    }

    private func checkLineEnd() {
        if nextLineMove == nil, let line = currentLine {
            feedback = .lineComplete(name: line.line.name)
            if queue.isEmpty {
                completedLineIDs.append(line.id)
                currentLine = nil
                feedback = .sessionComplete
            }
        }
    }

    private func grade(nodeChild: Int?, correct: Bool) {
        guard let child = nodeChild, let card = cardsByNode[child] else { return }
        if mode == .learn {
            learnedCount += 1
            return
        }
        let g: RecallGrade
        if !correct || mistakesHere >= 2 || hintLevel >= 3 {
            g = .again
        } else if mistakesHere == 1 || hintLevel >= 1 {
            g = .hard
        } else {
            g = .good
        }
        gradedCount += 1
        if g != .again { correctCount += 1 }
        onGrade?(card, g, position)
    }

    /// A non-revealing hint that names the kind of move expected.
    public static func hintText(for move: Move, in position: Position) -> String {
        guard let piece = position[move.from] else { return "Try again." }
        if position.isCastling(move) { return "Think about king safety." }
        var after = position
        after.make(move)
        if after.isCheck { return "Look for a check." }
        if position.isCapture(move) { return "Look for a capture." }
        if piece.kind == .pawn && [3, 4].contains(move.to.file) { return "Fight for the center with a pawn." }
        if piece.kind == .pawn { return "A pawn move is needed here." }
        let home = piece.color == .white ? 0 : 7
        if (piece.kind == .knight || piece.kind == .bishop) && move.from.rank == home {
            return "Develop a \(piece.kind == .knight ? "knight" : "bishop")."
        }
        return "Think about your \(piece.kind.name)."
    }
}
