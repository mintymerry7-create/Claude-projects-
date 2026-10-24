import XCTest
import ChessCore
import ChessEngine
import OpeningDatabase
import Learning
@testable import AppFeatures

final class BoardInteractionTests: XCTestCase {
    func testTapSelectThenMove() {
        var b = BoardInteraction()
        let p = Position.start
        XCTAssertEqual(b.tap(Square("e2")!, in: p, side: .white), .selected)
        XCTAssertEqual(Set(b.targets), [Square("e3")!, Square("e4")!])
        XCTAssertEqual(b.tap(Square("e4")!, in: p, side: .white), .move(Move(uci: "e2e4")!))
        XCTAssertNil(b.selected)
        // Opponent pieces cannot be selected.
        XCTAssertEqual(b.tap(Square("e7")!, in: p, side: .white), .none)
        // Tapping the same square deselects.
        _ = b.tap(Square("g1")!, in: p, side: .white)
        XCTAssertEqual(b.tap(Square("g1")!, in: p, side: .white), .none)
        XCTAssertNil(b.selected)
    }

    func testPromotionNeedsChoice() throws {
        var b = BoardInteraction()
        let p = try Position(fen: "8/P6k/8/8/8/8/8/K7 w - - 0 1")
        XCTAssertEqual(b.drag(from: Square("a7")!, to: Square("a8")!, in: p, side: .white),
                       .needsPromotion(from: Square("a7")!, to: Square("a8")!))
        XCTAssertEqual(b.choosePromotion(.knight), Move(uci: "a7a8n"))
        XCTAssertEqual(b.drag(from: Square("a7")!, to: Square("b8")!, in: p, side: .white), .none, "illegal drag")
    }
}

final class TrainerTests: XCTestCase {
    func plan(_ id: String, _ settings: DepthSettings = .beginner, side: PieceColor? = nil) throws -> StudyPlan {
        StudyPlanBuilder.build(opening: try XCTUnwrap(OpeningDatabase.shared.opening(id: id)), settings: settings, side: side)
    }

    func testMemoryModeGradesAndAdvances() throws {
        let p = try plan("italian-giuoco-piano")
        let t = OpeningTrainer(plan: p, mode: .memory)
        var grades: [(String, RecallGrade)] = []
        t.onGrade = { card, g, _ in grades.append((card.san, g)) }
        XCTAssertTrue(t.isLearnerTurn)
        XCTAssertEqual(t.submit(Move(uci: "e2e4")!), .correct(san: "e4"))
        XCTAssertTrue(t.isOpponentTurn)
        XCTAssertEqual(t.playOpponentMove(), Move(uci: "e7e5"))
        // Wrong move then right move -> graded hard.
        if case .incorrect(_, let hint) = t.submit(Move(uci: "d2d4")!) {
            XCTAssertEqual(hint, "Develop a knight.")
        } else { XCTFail() }
        XCTAssertEqual(t.submit(Move(uci: "g1f3")!), .correct(san: "Nf3"))
        t.playOpponentMove()
        // Hints all the way -> revealed and graded again.
        t.hint(); t.hint()
        XCTAssertEqual(t.display.hintSquares, [Square("f1")!])
        XCTAssertEqual(t.display.arrows.count, 1)
        t.hint()
        XCTAssertEqual(t.feedback, .revealed(san: "Bc4"))
        t.playOpponentMove()
        XCTAssertEqual(t.submit(Move(uci: "e1g1")!).isIncorrect, true)
        XCTAssertEqual(grades.map(\.1), [.good, .hard, .again])
        // Finish the 8-ply line: reveal 4.c3, then Black's last move ends it.
        t.hint(); t.hint(); t.hint()
        XCTAssertEqual(t.feedback, .revealed(san: "c3"))
        t.playOpponentMove()
        XCTAssertEqual(t.feedback, .sessionComplete)
    }

    func testAlternativeBranchIsAccepted() throws {
        let p = try plan("open-sicilian", .intermediate)
        let t = OpeningTrainer(plan: p, mode: .memory)
        t.playOpponentMove() // 1.e4
        t.submit(Move(uci: "c7c5")!)
        t.playOpponentMove(); t.submit(Move(uci: "d7d6")!)
        t.playOpponentMove(); t.submit(Move(uci: "c5d4")!)
        t.playOpponentMove(); t.submit(Move(uci: "g8f6")!)
        t.playOpponentMove()
        // Main line ends at 5.Nc3; the plan contains 5...a6, 5...g6 etc. as branches.
        XCTAssertNotNil(t.currentLine)
    }

    func testLearnModeShowsMovesWithoutGrading() throws {
        let p = try plan("ruy-lopez-closed")
        let t = OpeningTrainer(plan: p, mode: .learn)
        var graded = 0
        t.onGrade = { _, _, _ in graded += 1 }
        XCTAssertEqual(t.display.arrows.first.map { Move(from: $0.from, to: $0.to) }, Move(uci: "e2e4"))
        XCTAssertNotNil(t.upcomingExplanation)
        while !t.isFinished { t.playShownMove(); if case .lineComplete = t.feedback { t.continueAfterLine() } }
        XCTAssertEqual(graded, 0)
        XCTAssertEqual(t.learnedCount, 4)
    }

    func testBlackSideAndUndo() throws {
        let p = try plan("caro-kann-classical")
        let t = OpeningTrainer(plan: p, mode: .memory)
        XCTAssertFalse(t.isLearnerTurn)
        t.playOpponentMove()
        XCTAssertEqual(t.display.orientation, .black)
        t.submit(Move(uci: "c7c6")!)
        t.playOpponentMove()
        t.undo()
        XCTAssertEqual(t.position.sideToMove, .black)
        XCTAssertEqual(t.plyInLine, 1)
    }
}

private extension TrainerFeedback {
    var isIncorrect: Bool { if case .incorrect = self { return true }; return false }
}

final class SessionTests: XCTestCase {
    func testPuzzleSessionFlow() throws {
        let puzzle = Puzzle(id: "t1", fen: "r6k/6pp/7N/8/2Q5/8/8/6K1 w - - 0 1",
                            solution: ["c4g8", "a8g8", "h6f7"], themes: ["mate", "mateIn2", "smotheredMate"], level: 3, lastMove: nil)
        let s = PuzzleSession(puzzle: puzzle)
        var finished: (Bool, Bool)?
        s.onFinish = { _, solved, first, _ in finished = (solved, first) }
        XCTAssertEqual(s.submit(Move(uci: "h6f7")!), .wrong(san: "Nf7+"))
        s.retry()
        XCTAssertEqual(s.submit(Move(uci: "c4g8")!), .solving)
        XCTAssertTrue(s.needsReply)
        XCTAssertEqual(s.playReply(), Move(uci: "a8g8"))
        XCTAssertEqual(s.submit(Move(uci: "h6f7")!), .solved(firstTry: false))
        XCTAssertEqual(finished?.0, true)
        XCTAssertEqual(finished?.1, false)
        XCTAssertTrue(s.position.isCheckmate)
    }

    func testPuzzleAcceptsAlternativeMate() throws {
        let puzzle = Puzzle(id: "t2", fen: "7k/8/6K1/8/5Q2/8/8/8 w - - 0 1", solution: ["f4f8"], themes: ["mate", "mateIn1"], level: 1, lastMove: nil)
        let s = PuzzleSession(puzzle: puzzle)
        XCTAssertEqual(s.submit(Move(uci: "f4b8")!), .solved(firstTry: true))
    }

    func testLessonSessionRunsAllSteps() throws {
        let lesson = try XCTUnwrap(Curriculum.shared.lesson(id: "tactics-forks"))
        let s = LessonSession(lesson: lesson)
        var completed: [Int] = []
        var done = false
        s.onStepCompleted = { completed.append($0) }
        s.onFinished = { _ in done = true }
        while !done {
            guard let step = s.step else { break }
            if step.isTask {
                if s.feedback == .awaitingMove {
                    // Wrong move first.
                    let wrong = s.position.legalMoves().first { !step.acceptedFirstMoves.contains($0) }!
                    if case .wrong = s.submit(wrong) { s.retry() }
                }
                while s.feedback == .awaitingMove {
                    let idx = s.solutionIndex
                    s.submit(step.solutionMoves[idx])
                }
            }
            s.next()
        }
        XCTAssertTrue(done)
        XCTAssertEqual(Set(completed), Set(0..<lesson.steps.count))
    }

    func testReviewSession() throws {
        var d = UserData()
        let fen = Position.startFEN
        d.recordReview(cardID: "\(Position.start.repetitionKey)|e2e4", grade: .again, openingID: "x", san: "e4", fen: fen,
                       now: Date().addingTimeInterval(-7200))
        d.recordReview(cardID: "\(Position.start.repetitionKey)|d2d4", grade: .good, openingID: "x", san: "d4", fen: fen)
        let s = ReviewSession(cards: d.dueReviews(), allReviews: Array(d.reviews.values))
        var graded: [RecallGrade] = []
        s.onGrade = { _, g in graded.append(g) }
        XCTAssertEqual(s.remaining, 1)
        XCTAssertEqual(s.submit(Move(uci: "d2d4")!), .alsoKnown(san: "d4"))
        XCTAssertEqual(s.submit(Move(uci: "e2e4")!), .correct(san: "e4", grade: .good))
        s.next()
        XCTAssertTrue(s.isFinished)
        XCTAssertEqual(graded, [.good])
    }
}

@MainActor
final class GameSessionTests: XCTestCase {
    func testBotRepliesAndGameCanBeSaved() async throws {
        let setup = GameSetup(bot: .beginner, playerColor: .white)
        let s = try GameSession(setup: setup, engine: BuiltInEngine(seed: 5))
        s.start()
        XCTAssertTrue(s.isPlayerTurn)
        XCTAssertTrue(s.play(Move(uci: "e2e4")!))
        XCTAssertFalse(s.play(Move(uci: "d2d4")!), "not the player's turn")
        try await waitForPlayerTurn(s)
        XCTAssertEqual(s.game.plyCount, 2)
        s.undo()
        XCTAssertEqual(s.game.plyCount, 0)
        s.resign()
        XCTAssertEqual(s.outcome?.reason, .resignation)
        let saved = try XCTUnwrap(s.savedGame(openingName: nil))
        XCTAssertEqual(saved.result, "0-1")
        XCTAssertEqual(saved.playerScore, 0)
        XCTAssertNoThrow(try PGNParser.parseFirst(saved.pgn))
    }

    func testBotFollowsBookThenEngine() async throws {
        let opening = try XCTUnwrap(OpeningDatabase.shared.opening(id: "sicilian-najdorf"))
        let plan = StudyPlanBuilder.build(opening: opening, settings: .beginner)
        let setup = GameSetup(bot: .easy, playerColor: .white, book: plan.tree, bookName: opening.name, playerBook: plan.tree)
        let s = try GameSession(setup: setup, engine: BuiltInEngine(seed: 9))
        s.start()
        s.play(Move(uci: "e2e4")!)
        try await waitForPlayerTurn(s)
        XCTAssertEqual(s.game.lastMove, Move(uci: "c7c5"), "book reply")
        s.play(Move(uci: "b1c3")!) // leaves the course's main line
        XCTAssertNotNil(s.message)
        XCTAssertEqual(s.leftBookAtPly, 2)
        try await waitForPlayerTurn(s)
        XCTAssertEqual(s.game.plyCount, 4)
    }

    func testBotPlaysFirstAsWhite() async throws {
        let s = try GameSession(setup: GameSetup(bot: .beginner, playerColor: .black), engine: BuiltInEngine(seed: 2))
        s.start()
        try await waitForPlayerTurn(s)
        XCTAssertEqual(s.game.plyCount, 1)
        XCTAssertEqual(s.display.orientation, .black)
    }

    func testClockAndTimeout() async throws {
        var c = ChessClock(control: TimeControl(minutes: 1, incrementSeconds: 2))
        let t0 = Date()
        c.start(.white, now: t0)
        XCTAssertEqual(c.remaining(.white, now: t0.addingTimeInterval(10)), 50_000)
        c.press(.white, now: t0.addingTimeInterval(10))
        XCTAssertEqual(c.remaining(.white, now: t0.addingTimeInterval(20)), 52_000)
        XCTAssertEqual(c.flagged(now: t0.addingTimeInterval(80)), .black)
    }

    func testReplayNavigation() async throws {
        var g = ChessGame()
        for m in ["e4", "e5", "Nf3"] { try g.play(san: m) }
        var r = GameReplay(game: g)
        XCTAssertEqual(r.ply, 3)
        r.back(); r.back()
        XCTAssertEqual(r.lastMove, Move(uci: "e2e4"))
        r.toStart()
        XCTAssertEqual(r.position, .start)
        r.goTo(99)
        XCTAssertEqual(r.ply, 3)
    }

    private func waitForPlayerTurn(_ s: GameSession, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !s.isPlayerTurn && !s.isFinished {
            if Date() > deadline { return XCTFail("bot did not move") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    func makeModel() -> AppModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ka-\(UUID().uuidString)/userdata.json")
        return AppModel(store: UserDataStore(url: url))
    }

    func testCourseTrainingPersistsProgressAcrossDepthChanges() async throws {
        let m = makeModel()
        let opening = try XCTUnwrap(m.db.opening(id: "italian-giuoco-piano"))
        m.startCourse(opening, settings: .beginner)
        let t = try XCTUnwrap(m.makeTrainer(openingID: opening.id, mode: .memory))
        t.submit(Move(uci: "e2e4")!)
        t.playOpponentMove()
        t.submit(Move(uci: "g1f3")!)
        XCTAssertEqual(m.data.reviews.count, 2)
        XCTAssertEqual(m.data.courses[opening.id]?.resumePath, ["e4", "e5", "Nf3"])
        XCTAssertEqual(m.data.resume?.targetID, opening.id)
        XCTAssertEqual(m.courses.first?.counts.learning, 2)

        m.updateCourse(opening.id, settings: .advanced)
        XCTAssertEqual(m.data.reviews.count, 2, "depth change keeps progress")
        XCTAssertGreaterThan(try XCTUnwrap(m.plan(for: opening.id)).cards.count, 4)
        XCTAssertEqual(m.courses.first?.counts.learning, 2)

        // Activity merges into one entry per session.
        XCTAssertEqual(m.data.activity.filter { $0.kind == .openingStudy }.count, 1)
        XCTAssertEqual(m.practisedToday, 2)
        XCTAssertEqual(m.streak, 1)

        // Everything is on disk.
        let reloaded = UserDataStore(url: m.store.url)
        XCTAssertEqual(reloaded.data.reviews.count, 2)
    }

    func testRepertoireDrillUsesSharedCards() async throws {
        let m = makeModel()
        var rep = try m.createRepertoire(name: "Mine", color: .white)
        try rep.addLine(sans: ["e4", "e5", "Nf3", "Nc6", "Bc4"])
        m.save(repertoire: rep)
        let t = try XCTUnwrap(m.makeRepertoireTrainer(rep.id, mode: .memory))
        t.submit(Move(uci: "e2e4")!)
        XCTAssertEqual(m.data.reviews.values.first?.context, "Mine")
        let editor = try XCTUnwrap(m.makeRepertoireEditor(rep.id))
        editor.forward()
        editor.setNote("King's pawn")
        XCTAssertEqual(m.data.repertoires.first?.tree[1].comment, "King's pawn")
    }

    func testOnboardingAndGreeting() async {
        let m = makeModel()
        XCTAssertFalse(m.data.hasCompletedOnboarding)
        m.completeOnboarding(name: "Alex", level: .intermediate)
        XCTAssertTrue(m.greeting().hasSuffix(", Alex"))
        XCTAssertEqual(m.settings.level, .intermediate)
    }
}
