import XCTest
import ChessCore
@testable import OpeningDatabase

final class OpeningDatabaseTests: XCTestCase {
    static let db = try! OpeningDatabase.loadBundled()
    var db: OpeningDatabase { Self.db }

    func testAtLeastHundredDistinctOpenings() {
        XCTAssertGreaterThanOrEqual(db.openings.count, 100)
        XCTAssertEqual(Set(db.openings.map(\.id)).count, db.openings.count, "ids unique")
        XCTAssertEqual(Set(db.openings.map(\.name)).count, db.openings.count, "names unique")
        // Distinct openings must define distinct positions.
        let keys = db.openings.map { $0.position.repetitionKey }
        XCTAssertEqual(Set(keys).count, keys.count, "defining positions unique")
    }

    func testEveryLineIsLegalWithChessCore() throws {
        var lineCount = 0
        for o in db.openings {
            for line in o.lines {
                var p = Position.start
                for (i, san) in line.moves.enumerated() {
                    let m: Move
                    do { m = try p.move(fromSAN: san) } catch {
                        return XCTFail("\(o.id)/\(line.id): illegal \(san) at ply \(i + 1)")
                    }
                    XCTAssertEqual(p.san(for: m), san, "\(o.id)/\(line.id) SAN mismatch at ply \(i + 1)")
                    p.make(m)
                }
                lineCount += 1
            }
        }
        XCTAssertGreaterThan(lineCount, 1000)
    }

    func testMainLineReachesDefiningPosition() throws {
        for o in db.openings {
            var p = Position.start
            for san in o.mainLine.moves.prefix(o.canonicalPly) { p = try p.playing(san: san) }
            XCTAssertEqual(p.repetitionKey, try Position(fen: o.fen).repetitionKey, o.id)
        }
    }

    func testContentCompleteness() {
        for o in db.openings {
            XCTAssertFalse(o.summary.isEmpty, o.id)
            XCTAssertFalse(o.ideas.isEmpty, o.id)
            XCTAssertFalse(o.whitePlans.isEmpty, o.id)
            XCTAssertFalse(o.blackPlans.isEmpty, o.id)
            XCTAssertFalse(o.mistakes.isEmpty, o.id)
            XCTAssertFalse(o.eco.isEmpty, o.id)
            XCTAssertEqual(o.lines.filter { $0.kind == .main }.count, 1, o.id)
            for kp in o.keyPositions { XCTAssertLessThanOrEqual(kp.ply, o.mainLine.plyCount, o.id) }
        }
    }

    func testMajorOpeningsHaveMultipleVariations() {
        for id in ["sicilian-najdorf", "ruy-lopez-closed", "qgd-orthodox", "kid-classical", "italian-giuoco-piano", "french-classical"] {
            guard let o = db.opening(id: id) else { return XCTFail("missing \(id)") }
            XCTAssertGreaterThanOrEqual(o.lines.count, 4, id)
        }
        XCTAssertNotNil(db.opening(id: "london-system"))
        XCTAssertTrue(db.families.contains("Sicilian Defense"))
    }

    func testSearchAndFilters() {
        XCTAssertEqual(db.search(OpeningFilter(query: "najdorf")).first?.id, "sicilian-najdorf")
        XCTAssertTrue(db.search(OpeningFilter(query: "B90")).contains { $0.id == "sicilian-najdorf" })
        XCTAssertTrue(db.search(OpeningFilter(query: "grunfeld")).contains { $0.id == "grunfeld-exchange" }, "diacritic-insensitive")
        let whiteBeginner = db.search(OpeningFilter(difficulty: .beginner, side: .white))
        XCTAssertFalse(whiteBeginner.isEmpty)
        XCTAssertTrue(whiteBeginner.allSatisfy { $0.difficulty == .beginner && $0.side == .white })
        XCTAssertTrue(db.search(OpeningFilter(family: "Flank Openings")).allSatisfy { $0.family == "Flank Openings" })
        XCTAssertTrue(db.search(OpeningFilter(query: "zzzz")).isEmpty)
    }

    func testIdentifyOpeningFromMoves() throws {
        let moves = try Notation.moves(fromSANs: ["e4", "c5", "Nf3", "d6", "d4", "cxd4", "Nxd4", "Nf6", "Nc3", "a6", "Be3"])
        XCTAssertEqual(db.identify(moves: moves)?.id, "sicilian-najdorf")
        let qgd = try Notation.moves(fromSANs: ["d4", "Nf6", "c4", "e6", "Nc3", "d5", "cxd5", "exd5"])
        XCTAssertEqual(db.identify(moves: qgd)?.id, "qgd-exchange", "transposition recognised")
    }
}

final class StudyPlanTests: XCTestCase {
    var db: OpeningDatabase { OpeningDatabaseTests.db }

    func testPresetsGenerateDifferentTrees() throws {
        let o = try XCTUnwrap(db.opening(id: "ruy-lopez-closed"))
        let b = StudyPlanBuilder.build(opening: o, settings: .beginner)
        let i = StudyPlanBuilder.build(opening: o, settings: .intermediate)
        let a = StudyPlanBuilder.build(opening: o, settings: .advanced)

        XCTAssertEqual(b.lines.count, 1)
        XCTAssertEqual(b.tree.maxPly, 8)
        XCTAssertEqual(b.lines[0].line.kind, .main)
        XCTAssertGreaterThan(i.lines.count, b.lines.count)
        XCTAssertGreaterThan(a.lines.count, i.lines.count)
        XCTAssertGreaterThan(a.tree.count, i.tree.count)
        XCTAssertGreaterThan(i.cards.count, b.cards.count)
        XCTAssertTrue(i.lines.contains { $0.line.kind == .trap }, "intermediate includes traps")
        XCTAssertFalse(i.lines.contains { $0.line.kind == .sideline }, "no rare lines at intermediate")
        XCTAssertTrue(a.lines.contains { $0.line.kind == .sideline })
        // Main line is the first branch everywhere.
        let mainSANs = a.tree.mainline().map { a.tree[$0].san }
        XCTAssertEqual(Array(mainSANs.prefix(o.mainLine.plyCount)), Array(o.mainLine.moves.prefix(30)))
    }

    func testCustomSettingsAreRespected() throws {
        let o = try XCTUnwrap(db.opening(id: "sicilian-najdorf"))
        var s = DepthSettings.forPreset(.custom)
        s.maxPly = 12
        s.maxVariations = 3
        s.includeRareSidelines = true
        s.prioritizeTraps = false
        let plan = StudyPlanBuilder.build(opening: o, settings: s)
        XCTAssertLessThanOrEqual(plan.lines.count, 3)
        XCTAssertLessThanOrEqual(plan.tree.maxPly, 12)
        for l in plan.lines { XCTAssertLessThanOrEqual(l.moves.count, 12) }
    }

    func testPrioritisedTrapsKeptWhole() throws {
        let o = try XCTUnwrap(db.opening(id: "philidor-defense"))
        var s = DepthSettings.forPreset(.custom)
        s.maxPly = 6
        s.maxVariations = 3
        s.prioritizeTraps = true
        let plan = StudyPlanBuilder.build(opening: o, settings: s)
        let trap = try XCTUnwrap(plan.lines.first { $0.line.kind == .trap })
        XCTAssertEqual(trap.moves, trap.line.moves, "the punchline must be included")
        XCTAssertTrue(plan.tree[trap.leafNodeID].san.hasSuffix("#"))
    }

    func testCardsBelongToLearnerSide() throws {
        let o = try XCTUnwrap(db.opening(id: "sicilian-najdorf"))
        let plan = StudyPlanBuilder.build(opening: o, settings: .intermediate)
        XCTAssertEqual(plan.learnerSide, .black)
        for c in plan.cards {
            let parent = plan.tree[c.nodeID].parent!
            XCTAssertEqual(plan.tree.position(at: parent).sideToMove, .black)
        }
        let asWhite = StudyPlanBuilder.build(opening: o, settings: .intermediate, side: .white)
        XCTAssertEqual(asWhite.cards.first?.san, "e4")
        // Card ids are stable across depth changes so progress is preserved.
        let deeper = StudyPlanBuilder.build(opening: o, settings: .advanced)
        XCTAssertTrue(Set(plan.cards.map(\.id)).isSubset(of: Set(deeper.cards.map(\.id))))
        XCTAssertGreaterThan(plan.estimatedMinutes, 0)
    }

    func testNotesAttachToNodes() throws {
        let o = try XCTUnwrap(db.opening(id: "italian-giuoco-piano"))
        let plan = StudyPlanBuilder.build(opening: o, settings: .beginner)
        let bc4 = plan.tree.mainline()[4]
        XCTAssertEqual(plan.tree[bc4].san, "Bc4")
        XCTAssertNotNil(plan.notes[bc4])
    }

    func testEveryOpeningBuildsAtEveryPreset() {
        for o in db.openings {
            for p in DepthPreset.allCases {
                let plan = StudyPlanBuilder.build(opening: o, settings: .forPreset(p))
                XCTAssertFalse(plan.lines.isEmpty, "\(o.id) \(p)")
                XCTAssertFalse(plan.cards.isEmpty, "\(o.id) \(p)")
            }
        }
    }
}
