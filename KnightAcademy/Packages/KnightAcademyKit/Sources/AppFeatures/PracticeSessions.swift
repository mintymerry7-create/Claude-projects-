import Foundation
import Observation
import ChessCore
import Learning

// MARK: - Spaced-repetition review

public enum ReviewFeedback: Equatable, Sendable {
    case waiting
    case correct(san: String, grade: RecallGrade)
    case incorrect(san: String, hint: String)
    case alsoKnown(san: String)
    case revealed(san: String)
}

/// Reviews due cards from all openings and repertoires: each card shows the
/// position and asks for the move.
@Observable
public final class ReviewSession {
    public private(set) var cards: [ReviewState]
    public private(set) var index = 0
    public private(set) var feedback: ReviewFeedback = .waiting
    public private(set) var mistakes = 0
    public private(set) var hintLevel = 0
    public private(set) var results: [RecallGrade] = []
    /// Moves known in a position (from other cards), accepted without penalty.
    private let knownMoves: [String: Set<String>]

    @ObservationIgnored public var onGrade: ((ReviewState, RecallGrade) -> Void)?

    public init(cards: [ReviewState], allReviews: [ReviewState] = []) {
        self.cards = cards.filter { $0.fen != nil && $0.moveUCI != nil }
        var known: [String: Set<String>] = [:]
        for r in allReviews + cards {
            guard let fen = r.fen, let pos = try? Position(fen: fen), let m = r.moveUCI else { continue }
            known[pos.repetitionKey, default: []].insert(m)
        }
        knownMoves = known
    }

    public var current: ReviewState? { index < cards.count ? cards[index] : nil }
    public var isFinished: Bool { current == nil }
    public var position: Position? { current?.fen.flatMap { try? Position(fen: $0) } }
    public var expected: Move? { current?.moveUCI.flatMap(Move.init(uci:)) }
    public var remaining: Int { max(0, cards.count - index) }
    public var accuracy: Double {
        results.isEmpty ? 0 : Double(results.filter(\.isCorrect).count) / Double(results.count)
    }

    public var display: BoardDisplay? {
        guard let p = position else { return nil }
        var hints: [Square] = []
        var arrows: [Arrow] = []
        if let e = expected {
            if hintLevel >= 1 { hints.append(e.from) }
            if hintLevel >= 2 { arrows.append(Arrow(from: e.from, to: e.to)) }
        }
        let answered: Bool = { if case .waiting = feedback { return false }; if case .incorrect = feedback { return false }; if case .alsoKnown = feedback { return false }; return true }()
        return BoardDisplay(position: p, orientation: p.sideToMove, arrows: arrows, hintSquares: hints, interactive: !answered)
    }

    @discardableResult
    public func submit(_ move: Move) -> ReviewFeedback {
        guard let card = current, let pos = position, let exp = expected else { return feedback }
        let san = pos.san(for: move)
        if move == exp {
            let g: RecallGrade = mistakes >= 2 ? .again : (mistakes == 1 || hintLevel > 0) ? .hard : .good
            finish(card, g)
            feedback = .correct(san: san, grade: g)
        } else if knownMoves[pos.repetitionKey]?.contains(move.uci) == true {
            feedback = .alsoKnown(san: san)
        } else {
            mistakes += 1
            feedback = .incorrect(san: san, hint: OpeningTrainer.hintText(for: exp, in: pos))
        }
        return feedback
    }

    public func hint() {
        guard let card = current, let pos = position, let exp = expected else { return }
        hintLevel += 1
        if hintLevel >= 3 {
            finish(card, .again)
            feedback = .revealed(san: pos.san(for: exp))
        }
    }

    public func next() {
        guard current != nil else { return }
        index += 1
        mistakes = 0
        hintLevel = 0
        feedback = .waiting
    }

    private func finish(_ card: ReviewState, _ grade: RecallGrade) {
        results.append(grade)
        onGrade?(card, grade)
    }
}

// MARK: - Puzzles

public enum PuzzleState: Equatable, Sendable {
    case solving
    case wrong(san: String)
    case solved(firstTry: Bool)
    case failed
}

@Observable
public final class PuzzleSession {
    public let puzzle: Puzzle
    public private(set) var position: Position
    public private(set) var step = 0
    public private(set) var state: PuzzleState = .solving
    public private(set) var lastMove: Move?
    public private(set) var mistakes = 0
    public private(set) var hintLevel = 0

    @ObservationIgnored public var onFinish: ((Puzzle, _ solved: Bool, _ firstTry: Bool, _ usedHint: Bool) -> Void)?

    public init(puzzle: Puzzle) {
        self.puzzle = puzzle
        position = puzzle.position
        lastMove = puzzle.lastMove.flatMap(Move.init(uci:))
    }

    public var learnerColor: PieceColor { puzzle.learnerColor }
    public var expected: Move? { step < puzzle.solutionMoves.count ? puzzle.solutionMoves[step] : nil }
    public var isLearnerTurn: Bool {
        if case .solved = state { return false }
        if case .failed = state { return false }
        return position.sideToMove == learnerColor && expected != nil
    }

    public var display: BoardDisplay {
        var hints: [Square] = []
        var arrows: [Arrow] = []
        if isLearnerTurn, let e = expected {
            if hintLevel >= 1 { hints.append(e.from) }
            if hintLevel >= 2 { arrows.append(Arrow(from: e.from, to: e.to)) }
        }
        return BoardDisplay(position: position, orientation: learnerColor, lastMove: lastMove,
                            arrows: arrows, hintSquares: hints, interactive: isLearnerTurn)
    }

    /// Submits a learner move; on success the opponent reply is played automatically.
    @discardableResult
    public func submit(_ move: Move) -> PuzzleState {
        guard isLearnerTurn, let exp = expected else { return state }
        var accepted = move == exp
        // A different move that also mates immediately is equally correct.
        if !accepted, position.isLegal(move) {
            var test = position
            test.make(move)
            if test.isCheckmate { accepted = true }
        }
        guard accepted else {
            mistakes += 1
            state = .wrong(san: position.san(for: move))
            return state
        }
        apply(move)
        if step >= puzzle.solutionMoves.count || position.isCheckmate {
            complete(solved: true)
        } else {
            state = .solving
        }
        return state
    }

    /// The opponent reply after a correct move (call after a short UI delay).
    @discardableResult
    public func playReply() -> Move? {
        guard case .solving = state, position.sideToMove != learnerColor, let m = expected else { return nil }
        apply(m)
        return m
    }

    public var needsReply: Bool {
        if case .solving = state { return position.sideToMove != learnerColor && expected != nil }
        return false
    }

    public func hint() {
        guard isLearnerTurn else { return }
        hintLevel = min(2, hintLevel + 1)
    }

    /// Gives up and shows the solution.
    public func revealSolution() {
        switch state {
        case .solved, .failed: return
        default: break
        }
        while let m = expected {
            apply(m)
        }
        complete(solved: false)
    }

    public func retry() {
        if case .wrong = state { state = .solving }
    }

    private func apply(_ m: Move) {
        position.make(m)
        lastMove = m
        step += 1
    }

    private func complete(solved: Bool) {
        let firstTry = solved && mistakes == 0 && hintLevel == 0
        state = solved ? .solved(firstTry: firstTry) : .failed
        onFinish?(puzzle, solved, firstTry, hintLevel > 0)
    }
}

// MARK: - Fundamentals lessons

public enum LessonFeedback: Equatable, Sendable {
    case reading
    case awaitingMove
    case wrong(san: String)
    case correct(message: String)
    case finished
}

@Observable
public final class LessonSession {
    public let lesson: Lesson
    public private(set) var stepIndex: Int
    public private(set) var position: Position
    public private(set) var solutionIndex = 0
    public private(set) var feedback: LessonFeedback = .reading
    public private(set) var lastMove: Move?
    public private(set) var mistakes = 0
    public private(set) var showHint = false

    @ObservationIgnored public var onStepCompleted: ((Int) -> Void)?
    @ObservationIgnored public var onFinished: ((Int) -> Void)?

    public init(lesson: Lesson, startStep: Int = 0) {
        self.lesson = lesson
        let index = min(max(0, startStep), max(0, lesson.steps.count - 1))
        stepIndex = index
        position = lesson.steps.isEmpty ? .start : lesson.steps[index].position
        feedback = lesson.steps.isEmpty ? .finished : (lesson.steps[index].isTask ? .awaitingMove : .reading)
    }

    public var step: LessonStep? { stepIndex < lesson.steps.count ? lesson.steps[stepIndex] : nil }
    public var progress: Double { lesson.steps.isEmpty ? 1 : Double(stepIndex) / Double(lesson.steps.count) }
    public var isLastStep: Bool { stepIndex >= lesson.steps.count - 1 }

    public var display: BoardDisplay {
        guard let s = step else { return BoardDisplay(position: position) }
        let awaiting = feedback == .awaitingMove || { if case .wrong = feedback { return true }; return false }()
        var hints: [Square] = []
        if showHint, awaiting, let m = expectedMove { hints = [m.from, m.to] }
        // Task arrows only illustrate the starting position.
        let arrows = s.isTask ? (solutionIndex == 0 ? s.arrows : []) : s.arrows
        return BoardDisplay(position: position, orientation: s.position.sideToMove, lastMove: lastMove,
                            arrows: arrows, highlights: s.highlights, hintSquares: hints, interactive: awaiting)
    }

    private var expectedMove: Move? {
        guard let s = step, solutionIndex < s.solutionMoves.count else { return nil }
        return s.solutionMoves[solutionIndex]
    }

    @discardableResult
    public func submit(_ move: Move) -> LessonFeedback {
        guard let s = step, s.isTask, let exp = expectedMove else { return feedback }
        let accepted = move == exp || (solutionIndex == 0 && s.acceptedFirstMoves.contains(move))
        guard accepted else {
            mistakes += 1
            feedback = .wrong(san: position.san(for: move))
            return feedback
        }
        position.make(move)
        lastMove = move
        solutionIndex += 1
        showHint = false
        // Alternative first move: the remaining scripted moves no longer apply.
        if move != exp || solutionIndex >= s.solutionMoves.count {
            feedback = .correct(message: s.success ?? "Well done!")
            onStepCompleted?(stepIndex)
            return feedback
        }
        // Scripted reply.
        let reply = s.solutionMoves[solutionIndex]
        if position.isLegal(reply) {
            position.make(reply)
            lastMove = reply
            solutionIndex += 1
        }
        if solutionIndex >= s.solutionMoves.count {
            feedback = .correct(message: s.success ?? "Well done!")
            onStepCompleted?(stepIndex)
        } else {
            feedback = .awaitingMove
        }
        return feedback
    }

    public func requestHint() { showHint = true }

    public func retry() {
        if case .wrong = feedback { feedback = .awaitingMove }
    }

    /// Advances to the next step (reading steps complete on "Continue").
    public func next() {
        guard let s = step else { return }
        if !s.isTask { onStepCompleted?(stepIndex) }
        if case .awaitingMove = feedback, s.isTask { return }
        if case .wrong = feedback { return }
        if isLastStep {
            feedback = .finished
            onFinished?(mistakes)
            return
        }
        stepIndex += 1
        let ns = lesson.steps[stepIndex]
        position = ns.position
        lastMove = nil
        solutionIndex = 0
        showHint = false
        feedback = ns.isTask ? .awaitingMove : .reading
    }

    public func previous() {
        guard stepIndex > 0 else { return }
        stepIndex -= 1
        let ns = lesson.steps[stepIndex]
        position = ns.position
        lastMove = nil
        solutionIndex = 0
        showHint = false
        feedback = ns.isTask ? .awaitingMove : .reading
    }
}
