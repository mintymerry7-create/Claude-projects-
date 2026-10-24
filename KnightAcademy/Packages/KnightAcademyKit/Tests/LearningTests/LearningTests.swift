import XCTest
import ChessCore
import OpeningDatabase
@testable import Learning

final class SM2Tests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    func testIntervalsGrowWithCorrectAnswers() {
        var s = ReviewState(id: "c", due: t0)
        XCTAssertEqual(s.status, .new)
        s = SM2.review(s, grade: .good, now: t0, calendar: cal)
        XCTAssertEqual(s.intervalDays, 1)
        XCTAssertEqual(s.status, .learning)
        s = SM2.review(s, grade: .good, now: t0, calendar: cal)
        XCTAssertEqual(s.intervalDays, 6)
        XCTAssertEqual(s.status, .reviewing)
        s = SM2.review(s, grade: .good, now: t0, calendar: cal)
        XCTAssertEqual(s.intervalDays, 15) // 6 * 2.5 = 15
        s = SM2.review(s, grade: .easy, now: t0, calendar: cal)
        XCTAssertGreaterThanOrEqual(s.intervalDays, 21)
        XCTAssertEqual(s.status, .mastered)
        XCTAssertEqual(s.consecutiveCorrect, 4)
        XCTAssertEqual(s.accuracy, 1)
        XCTAssertEqual(s.due, cal.date(byAdding: .day, value: s.intervalDays, to: cal.startOfDay(for: t0)))
    }

    func testEaseFactorFollowsSM2Formula() {
        var s = ReviewState(id: "c", due: t0)
        s = SM2.review(s, grade: .good, now: t0)   // q=4: EF += 0
        XCTAssertEqual(s.easeFactor, 2.5, accuracy: 1e-9)
        s = SM2.review(s, grade: .easy, now: t0)   // q=5: EF += 0.1
        XCTAssertEqual(s.easeFactor, 2.6, accuracy: 1e-9)
        s = SM2.review(s, grade: .hard, now: t0)   // q=3: EF -= 0.14
        XCTAssertEqual(s.easeFactor, 2.46, accuracy: 1e-9)
        for _ in 0..<20 { s = SM2.review(s, grade: .again, now: t0) }
        XCTAssertEqual(s.easeFactor, 1.3, accuracy: 1e-9, "EF is floored at 1.3")
    }

    func testLapseResetsAndComesBackSoon() {
        var s = ReviewState(id: "c", due: t0)
        s = SM2.review(s, grade: .good, now: t0)
        s = SM2.review(s, grade: .good, now: t0)
        s = SM2.review(s, grade: .again, now: t0)
        XCTAssertEqual(s.repetitions, 0)
        XCTAssertEqual(s.intervalDays, 1)
        XCTAssertEqual(s.lapses, 1)
        XCTAssertEqual(s.consecutiveCorrect, 0)
        XCTAssertEqual(s.due, t0.addingTimeInterval(600))
        XCTAssertTrue(s.isDue(at: t0.addingTimeInterval(601)))
        XCTAssertEqual(s.status, .learning)
    }
}

final class PersistenceTests: XCTestCase {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ka-\(UUID().uuidString)").appendingPathComponent("userdata.json")
    }

    func testRoundTripAndReload() throws {
        let url = tempURL()
        let store = UserDataStore(url: url)
        let opening = try XCTUnwrap(OpeningDatabase.shared.opening(id: "italian-giuoco-piano"))
        store.update { d in
            d.settings.playerName = "Sam"
            d.courses[opening.id] = CourseProgress(openingID: opening.id, settings: .intermediate, side: .white)
            d.recordReview(cardID: "k|e2e4", grade: .good, openingID: opening.id, san: "e4", fen: Position.startFEN)
            d.log(ActivityEvent(kind: .puzzle, title: "Puzzles"))
            var rep = Repertoire(name: "My e4", color: .white)
            try? rep.addLine(sans: ["e4", "e5", "Nf3"])
            d.repertoires.append(rep)
        }
        let reloaded = UserDataStore(url: url)
        XCTAssertEqual(reloaded.data.settings.playerName, "Sam")
        XCTAssertEqual(reloaded.data.courses[opening.id]?.settings, .intermediate)
        XCTAssertEqual(reloaded.data.reviews["k|e2e4"]?.attempts, 1)
        XCTAssertEqual(reloaded.data.reviews["k|e2e4"]?.moveUCI, "e2e4")
        XCTAssertEqual(reloaded.data.activity.count, 1)
        XCTAssertEqual(reloaded.data.repertoires.first?.tree.count, 4)
        XCTAssertNil(reloaded.recoveredBackupURL)
    }

    func testMissingKeysDecodeToDefaults() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"settings":{"playerName":"Old"}}"#.utf8).write(to: url)
        let store = UserDataStore(url: url)
        XCTAssertEqual(store.data.settings.playerName, "Old")
        XCTAssertTrue(store.data.settings.hapticsEnabled)
        XCTAssertTrue(store.data.reviews.isEmpty)
    }

    func testCorruptFileIsMovedAside() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = UserDataStore(url: url)
        XCTAssertNotNil(store.recoveredBackupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.recoveredBackupURL!.path))
        XCTAssertTrue(store.data.reviews.isEmpty)
        store.update { $0.settings.playerName = "New" }
        XCTAssertEqual(UserDataStore(url: url).data.settings.playerName, "New")
    }
}

final class StatsTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    func testStreakAndWeekly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var d = UserData()
        for back in [0, 1, 2, 4] {
            d.log(ActivityEvent(kind: .puzzle, title: "P", count: back + 1, date: now.addingTimeInterval(Double(-back) * 86_400)))
        }
        XCTAssertEqual(ProgressStats.streak(d, now: now, calendar: cal), 3)
        // Streak still counts if today is empty but yesterday is not.
        XCTAssertEqual(ProgressStats.streak(d, now: now.addingTimeInterval(86_400), calendar: cal), 3)
        XCTAssertEqual(ProgressStats.streak(d, now: now.addingTimeInterval(3 * 86_400), calendar: cal), 0)
        let week = ProgressStats.weekly(d, now: now, calendar: cal)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.last?.count, 1)
        XCTAssertEqual(week.map(\.count).reduce(0, +), 1 + 2 + 3 + 5)
    }

    func testMasteryWeights() {
        var d = UserData()
        let now = Date()
        d.recordReview(cardID: "a", grade: .good, openingID: nil, san: nil, now: now)
        for _ in 0..<6 { d.recordReview(cardID: "b", grade: .easy, openingID: nil, san: nil, now: now) }
        let m = ProgressStats.mastery(cardIDs: ["a", "b", "c"], in: d)
        XCTAssertEqual(m, (0.35 + 1 + 0) / 3, accuracy: 1e-9)
        let counts = ProgressStats.statusCounts(cardIDs: ["a", "b", "c"], in: d)
        XCTAssertEqual(counts.new, 1)
        XCTAssertEqual(counts.learning, 1)
        XCTAssertEqual(counts.mastered, 1)
    }
}

final class RepertoireTests: XCTestCase {
    func testAddOpeningNotesPreferredAndCards() throws {
        let db = OpeningDatabase.shared
        var r = Repertoire(name: "White", color: .white)
        try r.add(opening: XCTUnwrap(db.opening(id: "italian-giuoco-piano")), maxPly: 10)
        try r.addLine(sans: ["e4", "c5", "c3"])
        XCTAssertEqual(r.openingIDs, ["italian-giuoco-piano"])
        XCTAssertEqual(r.lineCount, 2)
        let e4 = r.tree.mainline()[0]
        XCTAssertEqual(r.tree[e4].san, "e4")
        let c5 = try XCTUnwrap(r.tree[e4].children.first { r.tree[$0].san == "c5" })
        r.setPreferred(c5)
        XCTAssertEqual(r.tree[e4].children.first, c5)
        r.setNote("Alapin against the Sicilian", for: c5)
        XCTAssertEqual(r.tree[c5].comment, "Alapin against the Sicilian")
        // White's cards: e4, Nf3, Bc4, c3 (Italian), d4 ... and c3 vs Sicilian.
        let sans = r.cards.map(\.san)
        XCTAssertEqual(sans.first, "e4")
        XCTAssertTrue(sans.contains("c3"))
        XCTAssertFalse(sans.contains("e5"), "only own moves are cards")
        // Card ids match opening-course ids for shared progress.
        let plan = StudyPlanBuilder.build(opening: try XCTUnwrap(db.opening(id: "italian-giuoco-piano")), settings: .beginner)
        XCTAssertTrue(Set(plan.cards.map(\.id)).isSubset(of: Set(r.cards.map(\.id))))
    }

    func testPGNImportExportRoundTrip() throws {
        var r = Repertoire(name: "Black vs e4", color: .black)
        let added = try r.importPGN("""
        [Event "Prep"]

        1. e4 c6 2. d4 d5 3. Nc3 (3. e5 Bf5 4. Nf3 e6) 3... dxe4 4. Nxe4 Bf5 {Classical} *

        [Event "More"]

        1. e4 c6 2. c4 d5 *
        """)
        XCTAssertEqual(added, 14)
        XCTAssertEqual(r.lineCount, 3)
        let exported = r.exportPGN()
        var copy = Repertoire(name: "Copy", color: .black)
        try copy.importPGN(exported)
        XCTAssertEqual(copy.tree.allLines.map { $0.map { copy.tree[$0].san } },
                       r.tree.allLines.map { $0.map { r.tree[$0].san } })
        XCTAssertTrue(exported.contains("{Classical}"))
    }

    func testMalformedImportsAreReported() {
        var r = Repertoire(name: "R", color: .white)
        XCTAssertThrowsError(try r.importPGN("1. e4 e5 2. Ke3"))
        XCTAssertThrowsError(try r.importPGN(""))
        XCTAssertThrowsError(try r.importPGN("[FEN \"8/8/8/4k3/8/8/4P3/4K3 w - - 0 1\"]\n1. e3"), "different root") { e in
            XCTAssertEqual(e as? RepertoireError, .wrongStartPosition)
        }
        XCTAssertThrowsError(try Repertoire.fromFEN("garbage", name: "x"))
        XCTAssertEqual(r.tree.count, 1, "failed imports leave the tree unchanged")
    }

    func testRepertoireFromFEN() throws {
        var r = try Repertoire.fromFEN("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1", name: "Pawn ending")
        XCTAssertEqual(r.color, .white)
        try r.addLine(sans: ["Kd2", "Kd7", "Kd3"])
        XCTAssertFalse(r.isFromStandardStart)
        XCTAssertTrue(r.exportPGN().contains("[FEN \"4k3/8/8/8/8/8/4P3/4K3 w - - 0 1\"]"))
        XCTAssertEqual(r.cards.count, 2)
    }
}

final class ContentTests: XCTestCase {
    func testCurriculumLoadsAndTasksAreLegal() throws {
        let c = try Curriculum.loadBundled()
        XCTAssertGreaterThanOrEqual(c.modules.count, 10)
        XCTAssertGreaterThanOrEqual(c.allLessons.count, 20)
        for lesson in c.allLessons {
            XCTAssertFalse(lesson.steps.isEmpty, lesson.id)
            for (i, step) in lesson.steps.enumerated() {
                var p = try Position(fen: step.fen)
                for (k, m) in step.solutionMoves.enumerated() {
                    XCTAssertTrue(p.isLegal(m), "\(lesson.id) step \(i) move \(k)")
                    p.make(m)
                }
                for alt in (step.alternatives ?? []).compactMap(Move.init(uci:)) {
                    XCTAssertTrue(step.position.isLegal(alt), "\(lesson.id) alt")
                }
            }
        }
        let topics = Set(c.modules.map(\.id))
        for required in ["rules", "special-moves", "check-mate", "opening-principles", "tactics-forks", "tactics-pins",
                         "basic-mates", "pawn-endgames", "rook-endgames", "positional", "calculation"] {
            XCTAssertTrue(topics.contains(required), required)
        }
    }

    func testPuzzlesAreLegalAndDiverse() throws {
        let puzzles = try PuzzleLibrary.loadBundled()
        XCTAssertGreaterThanOrEqual(puzzles.count, 50)
        XCTAssertEqual(Set(puzzles.map(\.id)).count, puzzles.count)
        for pz in puzzles {
            var p = try Position(fen: pz.fen)
            XCTAssertFalse(pz.solution.isEmpty)
            XCTAssertEqual(pz.solution.count % 2, 1, "solutions end on the solver's move")
            for m in pz.solutionMoves {
                XCTAssertTrue(p.isLegal(m), "\(pz.id) \(m)")
                p.make(m)
            }
            if pz.themes.contains("mate") { XCTAssertTrue(p.isCheckmate, pz.id) }
            XCTAssertTrue((1...5).contains(pz.level))
        }
        XCTAssertGreaterThanOrEqual(Set(puzzles.flatMap(\.themes)).count, 5)
    }

    func testRecommendationsAreExplainable() throws {
        let db = OpeningDatabase.shared
        var d = UserData()
        let recs = Recommender.openings(for: d, db: db)
        XCTAssertFalse(recs.isEmpty)
        XCTAssertTrue(recs.allSatisfy { !$0.reason.isEmpty })
        if case .opening(let id) = recs[0].target {
            XCTAssertEqual(db.opening(id: id)?.side, .white)
            XCTAssertEqual(db.opening(id: id)?.difficulty, .beginner)
        } else { XCTFail() }
        d.courses["italian-giuoco-piano"] = CourseProgress(openingID: "italian-giuoco-piano", settings: .beginner, side: .white)
        let next = Recommender.openings(for: d, db: db)
        XCTAssertFalse(next.contains { $0.target == .opening("italian-giuoco-piano") })
        let step = Recommender.nextStep(for: d, db: db, curriculum: Curriculum.shared)
        XCTAssertEqual(step.target, .opening("italian-giuoco-piano"))
        d.recordReview(cardID: "x", grade: .again, openingID: nil, san: nil, fen: Position.startFEN, now: Date().addingTimeInterval(-3600))
        XCTAssertEqual(Recommender.nextStep(for: d, db: db, curriculum: Curriculum.shared).target, .reviews)
    }

    func testWeakThemeDrivesLessonRecommendation() {
        var d = UserData()
        for i in 0..<4 {
            var r = PuzzleRecord(puzzleID: "p\(i)", themes: ["fork"])
            r.attempts = 1
            r.solvedFirstTry = i == 0
            d.puzzles[r.puzzleID] = r
        }
        let rec = Recommender.nextLesson(for: d, curriculum: Curriculum.shared)
        XCTAssertEqual(rec?.target, .lesson("tactics-forks"))
        XCTAssertTrue(rec?.reason.contains("25%") ?? false, rec?.reason ?? "")
    }
}
