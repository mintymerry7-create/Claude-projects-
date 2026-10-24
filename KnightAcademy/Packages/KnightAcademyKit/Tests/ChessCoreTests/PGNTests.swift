import XCTest
@testable import ChessCore

final class PGNTests: XCTestCase {
    let sample = """
    [Event "Casual Game"]
    [Site "London"]
    [Date "1851.06.21"]
    [White "Adolf Anderssen"]
    [Black "Lionel Kieseritzky"]
    [Result "1-0"]

    1. e4 e5 2. f4 exf4 3. Bc4 Qh4+ 4. Kf1 b5 {Bryan Countergambit} 5. Bxb5 Nf6 6. Nf3
    Qh6 7. d3 Nh5 8. Nh4 Qg5 9. Nf5 c6 10. g4 Nf6 11. Rg1 cxb5 12. h4 Qg6 13. h5 Qg5
    14. Qf3 Ng8 15. Bxf4 Qf6 16. Nc3 Bc5 17. Nd5 Qxb2 18. Bd6 Bxg1 19. e5 Qxa1+ 20.
    Ke2 Na6 21. Nxg7+ Kd8 22. Qf6+ Nxf6 23. Be7# 1-0
    """

    func testImmortalGame() throws {
        let game = try PGNParser.parseFirst(sample)
        XCTAssertEqual(game.tags["White"], "Adolf Anderssen")
        XCTAssertEqual(game.result, "1-0")
        XCTAssertEqual(game.mainlineSANs.count, 45)
        XCTAssertEqual(game.mainlineSANs.last, "Be7#")
        let g = try game.mainlineGame()
        XCTAssertTrue(g.position.isCheckmate)
        XCTAssertEqual(game.tree[game.tree.mainline()[7]].comment, "Bryan Countergambit")
    }

    func testVariationsCommentsNAGs() throws {
        let pgn = """
        1. e4 e5 (1... c5 2. Nf3 (2. c3) d6) 2. Nf3! Nc6 $1 {Main line} 3. Bb5 a6 ; Morphy
        4. Ba4 *
        """
        let game = try PGNParser.parseFirst(pgn)
        let t = game.tree
        XCTAssertEqual(game.mainlineSANs, ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6", "Ba4"])
        let e4 = t.mainline()[0]
        XCTAssertEqual(t[e4].children.map { t[$0].san }, ["e5", "c5"])
        let c5 = t[e4].children[1]
        let nf3 = t[c5].children[0]
        XCTAssertEqual(t[c5].children.map { t[$0].san }, ["Nf3", "c3"])
        XCTAssertEqual(t[nf3].children.map { t[$0].san }, ["d6"])
        XCTAssertEqual(t[t.mainline()[2]].nags, [1])
        XCTAssertEqual(t[t.mainline()[3]].nags, [1])
        XCTAssertEqual(t[t.mainline()[3]].comment, "Main line")
        XCTAssertEqual(t[t.mainline()[5]].comment, "Morphy")
        XCTAssertEqual(t.allLines.count, 3)

        // Round trip through the writer keeps the whole tree.
        let text = PGNWriter.write(game: game)
        let again = try PGNParser.parseFirst(text)
        XCTAssertEqual(again.tree.allLines.map { $0.map { again.tree[$0].san } },
                       t.allLines.map { $0.map { t[$0].san } })
        XCTAssertTrue(text.contains("(1... c5 2. Nf3 (2. c3) 2... d6)"), text)
    }

    func testMultipleGamesAndFEN() throws {
        let pgn = """
        [Event "A"]
        [SetUp "1"]
        [FEN "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"]

        1. e4 Kd7 2. e5 1/2-1/2

        [Event "B"]

        1.d4 d5 2.c4 *
        """
        let games = try PGNParser.parse(pgn)
        XCTAssertEqual(games.count, 2)
        XCTAssertEqual(games[0].mainlineSANs, ["e4", "Kd7", "e5"])
        XCTAssertEqual(games[0].result, "1/2-1/2")
        XCTAssertEqual(games[1].mainlineSANs, ["d4", "d5", "c4"])
    }

    func testMalformedInputIsReported() {
        XCTAssertThrowsError(try PGNParser.parse("")) { XCTAssertEqual($0 as? PGNError, .empty) }
        XCTAssertThrowsError(try PGNParser.parse("1. e4 e5 2. Ke3")) {
            XCTAssertEqual($0 as? PGNError, .illegalMove(san: "Ke3", moveNumber: "move 2"))
        }
        XCTAssertThrowsError(try PGNParser.parse("1. e4 (1. d4 d5")) { XCTAssertEqual($0 as? PGNError, .unbalancedVariation) }
        XCTAssertThrowsError(try PGNParser.parse("1. e4 {oops")) { XCTAssertEqual($0 as? PGNError, .unterminatedComment) }
        XCTAssertThrowsError(try PGNParser.parse("[FEN \"bad\"]\n1. e4")) { XCTAssertEqual($0 as? PGNError, .badFEN("bad")) }
        XCTAssertThrowsError(try PGNParser.parse("[Event Unquoted]\n1. e4"))
    }

    func testGameExportImportRoundTrip() throws {
        var g = ChessGame()
        for m in ["d4", "Nf6", "c4", "e6", "Nc3", "Bb4", "e3", "O-O", "Bd3", "d5", "Nf3", "c5", "O-O"] {
            try g.play(san: m)
        }
        let pgn = g.pgn(tags: ["Event": "Test", "White": "Me", "Black": "Bot"])
        XCTAssertTrue(pgn.contains("[Result \"*\"]"))
        let back = try PGNParser.parseFirst(pgn)
        XCTAssertEqual(back.mainlineSANs, g.sanMoves)
        XCTAssertEqual(try back.mainlineGame().position.fen, g.position.fen)
    }

    func testMoveTreeEditing() throws {
        var t = MoveTree()
        let a = try t.addLine(sans: ["e4", "e5", "Nf3"])
        let b = try t.addLine(sans: ["e4", "c5", "Nf3"])
        XCTAssertEqual(t.count, 6)
        XCTAssertEqual(t.allLines.count, 2)
        XCTAssertEqual(t.sans(to: b), ["e4", "c5", "Nf3"])
        let c5 = t[b].parent!
        t.promoteToMain(c5)
        XCTAssertEqual(t.mainline().map { t[$0].san }, ["e4", "c5", "Nf3"])
        t.delete(c5)
        XCTAssertEqual(t.allLines.count, 1)
        XCTAssertEqual(t.mainline().map { t[$0].san }, ["e4", "e5", "Nf3"])
        _ = a
        XCTAssertThrowsError(try t.add(san: "Ke2", after: MoveTree.rootID))
    }
}

final class ExplainerTests: XCTestCase {
    func testInstructions() throws {
        let p = Position.start
        XCTAssertEqual(MoveExplainer.instruction(for: Move(uci: "d2d4")!, in: p), "Play pawn to d4.")
        XCTAssertEqual(MoveExplainer.instruction(for: Move(uci: "g1f3")!, in: p), "Play knight to f3.")
        let c = try Position(fen: "r3k2r/8/8/3p4/4P3/8/8/R3K2R w KQkq - 0 1")
        XCTAssertEqual(MoveExplainer.instruction(for: Move(uci: "e1g1")!, in: c), "Castle kingside.")
        XCTAssertEqual(MoveExplainer.instruction(for: Move(uci: "e4d5")!, in: c), "Capture on d5 with the pawn.")
    }

    func testDevelopmentAndCenter() throws {
        let p = try Position.start.playing(san: "e4").playing(san: "e5")
        let e = MoveExplainer.explain(try p.move(fromSAN: "Nf3"), in: p)
        XCTAssertTrue(e.text.contains("Develops the knight"), e.text)
        XCTAssertTrue(e.text.contains("attacks the pawn on e5"), e.text)
    }

    func testCastlingAndFork() throws {
        let c = try Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        XCTAssertTrue(MoveExplainer.explain(try c.move(fromSAN: "O-O"), in: c).text.contains("Castles kingside"))
        let f = try Position(fen: "r3k3/8/8/8/8/8/8/4K1N1 w - - 0 1")
        // Nf3 is not a fork; Ne2-d4-c6... use a direct fork position instead.
        let fork = try Position(fen: "r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1")
        let text = MoveExplainer.explain(try fork.move(fromSAN: "Nc7+"), in: fork).text
        XCTAssertTrue(text.contains("Check"), text)
        _ = f
    }

    func testPin() throws {
        let p = try Position(fen: "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3")
        let e = MoveExplainer.explain(try p.move(fromSAN: "Bb5"), in: p)
        XCTAssertTrue(e.text.contains("Develops the bishop"), e.text)
        let q = try Position(fen: "rnbqkb1r/pppp1ppp/5n2/4p3/4P3/2N5/PPPP1PPP/R1BQKBNR w KQkq - 0 1")
        _ = q
        let pin = try Position(fen: "4k3/8/8/8/8/2n5/8/4K1B1 w - - 0 1")
        _ = pin
        let r = try Position(fen: "4k3/4n3/8/8/8/8/8/R5K1 w - - 0 1")
        let t = MoveExplainer.explain(try r.move(fromSAN: "Re1"), in: r).text
        XCTAssertTrue(t.contains("pins the knight on e7 to the king"), t)
    }
}
