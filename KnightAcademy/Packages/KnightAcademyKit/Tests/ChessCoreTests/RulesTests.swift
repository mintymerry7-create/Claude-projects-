import XCTest
@testable import ChessCore

final class PerftTests: XCTestCase {
    // Reference values from https://www.chessprogramming.org/Perft_Results
    func testStartPosition() throws {
        let p = Position.start
        XCTAssertEqual(p.perft(1), 20)
        XCTAssertEqual(p.perft(2), 400)
        XCTAssertEqual(p.perft(3), 8_902)
        XCTAssertEqual(p.perft(4), 197_281)
    }

    func testKiwipete() throws {
        let p = try Position(fen: "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")
        XCTAssertEqual(p.perft(1), 48)
        XCTAssertEqual(p.perft(2), 2_039)
        XCTAssertEqual(p.perft(3), 97_862)
    }

    func testPosition3EnPassantAndPins() throws {
        let p = try Position(fen: "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1")
        XCTAssertEqual(p.perft(1), 14)
        XCTAssertEqual(p.perft(2), 191)
        XCTAssertEqual(p.perft(3), 2_812)
        XCTAssertEqual(p.perft(4), 43_238)
    }

    func testPosition4PromotionsAndCastling() throws {
        let p = try Position(fen: "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1")
        XCTAssertEqual(p.perft(1), 6)
        XCTAssertEqual(p.perft(2), 264)
        XCTAssertEqual(p.perft(3), 9_467)
    }

    func testPosition5() throws {
        let p = try Position(fen: "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8")
        XCTAssertEqual(p.perft(1), 44)
        XCTAssertEqual(p.perft(2), 1_486)
        XCTAssertEqual(p.perft(3), 62_379)
    }

    func testPosition6() throws {
        let p = try Position(fen: "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10")
        XCTAssertEqual(p.perft(1), 46)
        XCTAssertEqual(p.perft(2), 2_079)
        XCTAssertEqual(p.perft(3), 89_890)
    }
}

final class FENTests: XCTestCase {
    func testRoundTrip() throws {
        let fens = [
            Position.startFEN,
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "8/8/8/8/8/8/8/K6k b - - 12 40",
        ]
        for f in fens { XCTAssertEqual(try Position(fen: f).fen, f) }
    }

    func testEnPassantWrittenOnlyWhenLegal() throws {
        var p = Position.start
        p = try p.playing(san: "e4")
        // No black pawn can capture on e3, so FEN omits it.
        XCTAssertEqual(p.fen, "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1")
        p = try p.playing(san: "d5").playing(san: "e5").playing(san: "f5")
        XCTAssertEqual(p.fen, "rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3")
    }

    func testRejectsMalformed() {
        XCTAssertThrowsError(try Position(fen: ""))
        XCTAssertThrowsError(try Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP w KQkq - 0 1"))
        XCTAssertThrowsError(try Position(fen: "rnbqkbnr/pppppppp/9/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"))
        XCTAssertThrowsError(try Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR x KQkq - 0 1"))
        XCTAssertThrowsError(try Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQxq - 0 1"))
        XCTAssertThrowsError(try Position(fen: "8/8/8/8/8/8/8/8 w - - 0 1"), "no kings")
        XCTAssertThrowsError(try Position(fen: "4k3/8/8/8/8/8/8/P3K3 w - - 0 1"), "pawn on first rank")
        // Side not to move in check
        XCTAssertThrowsError(try Position(fen: "4k3/4R3/8/8/8/8/8/4K3 w - - 0 1"))
    }

    func testEPDWithoutCounters() throws {
        let p = try Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -")
        XCTAssertEqual(p, Position.start)
    }

    func testCastlingRightsSanitised() throws {
        let p = try Position(fen: "4k3/8/8/8/8/8/8/4K3 w KQkq - 0 1")
        XCTAssertEqual(p.castling, [])
    }
}

final class SpecialMoveTests: XCTestCase {
    func testCastlingBothSides() throws {
        let p = try Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        let ks = try p.move(fromSAN: "O-O")
        let qs = try p.move(fromSAN: "O-O-O")
        XCTAssertEqual(ks.uci, "e1g1")
        XCTAssertEqual(qs.uci, "e1c1")
        let after = try p.playing(ks)
        XCTAssertEqual(after[Square("f1")!], Piece(.white, .rook))
        XCTAssertNil(after[Square("h1")!])
        XCTAssertEqual(after.castling, [.blackKingside, .blackQueenside])
        let afterQ = try p.playing(qs)
        XCTAssertEqual(afterQ[Square("d1")!], Piece(.white, .rook))
        XCTAssertEqual(afterQ[Square("c1")!], Piece(.white, .king))
    }

    func testCannotCastleThroughCheckOrOutOfCheck() throws {
        // Black rook on f8 covers f1.
        let p = try Position(fen: "5r1k/7p/8/8/8/8/8/R3K2R w KQ - 0 1")
        XCTAssertThrowsError(try p.move(fromSAN: "O-O"))
        XCTAssertNoThrow(try p.move(fromSAN: "O-O-O"))
        // In check
        let q = try Position(fen: "4r2k/7p/8/8/8/8/8/R3K2R w KQ - 0 1")
        XCTAssertThrowsError(try q.move(fromSAN: "O-O"))
        XCTAssertThrowsError(try q.move(fromSAN: "O-O-O"))
        // b1 attacked does not prevent queenside castling, b1 occupied does.
        let r = try Position(fen: "1r5k/8/8/8/8/8/8/R3K3 w Q - 0 1")
        XCTAssertNoThrow(try r.move(fromSAN: "O-O-O"))
        let s = try Position(fen: "7k/8/8/8/8/8/8/RN2K3 w Q - 0 1")
        XCTAssertThrowsError(try s.move(fromSAN: "O-O-O"))
    }

    func testCastlingRightsLostWhenRookCaptured() throws {
        var g = try ChessGame(fen: "r3k2r/8/8/8/8/8/6b1/R3K2R b KQkq - 0 1")
        try g.play(san: "Bxh1")
        XCTAssertFalse(g.position.castling.contains(.whiteKingside))
        XCTAssertTrue(g.position.castling.contains(.whiteQueenside))
    }

    func testEnPassant() throws {
        var g = ChessGame()
        for m in ["e4", "a6", "e5", "d5"] { try g.play(san: m) }
        let ep = try g.position.move(fromSAN: "exd6")
        XCTAssertTrue(g.position.isEnPassant(ep))
        try g.play(ep)
        XCTAssertNil(g.position[Square("d5")!])
        XCTAssertEqual(g.position[Square("d6")!], Piece(.white, .pawn))
        XCTAssertEqual(g.sanMoves.last, "exd6")
        g.undo()
        XCTAssertEqual(g.position[Square("d5")!], Piece(.black, .pawn))
    }

    func testEnPassantOnlyImmediately() throws {
        var g = ChessGame()
        for m in ["e4", "a6", "e5", "d5", "Nf3", "h6"] { try g.play(san: m) }
        XCTAssertThrowsError(try g.play(san: "exd6"))
    }

    func testEnPassantPinnedHorizontally() throws {
        // Capturing en passant would expose the white king on the 5th rank.
        let p = try Position(fen: "8/8/8/K2pP2r/8/8/8/7k w - d6 0 1")
        XCTAssertFalse(p.legalMoves().contains(Move(uci: "e5d6")!))
        XCTAssertEqual(p.fen, "8/8/8/K2pP2r/8/8/8/7k w - - 0 1")
    }

    func testPromotion() throws {
        let p = try Position(fen: "8/P6k/8/8/8/8/8/K7 w - - 0 1")
        XCTAssertEqual(p.legalMoves().filter { $0.from == Square("a7")! }.count, 4)
        let m = try p.move(fromSAN: "a8=Q+")
        XCTAssertEqual(m.promotion, .queen)
        XCTAssertEqual(try p.move(fromSAN: "a8N").promotion, .knight)
        XCTAssertThrowsError(try p.move(fromSAN: "a8"), "promotion piece is required")
        let after = try p.playing(m)
        XCTAssertEqual(after[Square("a8")!], Piece(.white, .queen))
        XCTAssertEqual(p.san(for: m), "a8=Q")
        let cap = try Position(fen: "1n6/P6k/8/8/8/8/8/K7 w - - 0 1")
        XCTAssertEqual(cap.san(for: Move(uci: "a7b8r")!), "axb8=R")
    }

    func testIllegalMovesRejected() throws {
        let p = Position.start
        XCTAssertThrowsError(try p.move(fromSAN: "e5"))
        XCTAssertThrowsError(try p.move(fromSAN: "Ke2"))
        XCTAssertThrowsError(try p.move(fromSAN: "Nf4"))
        XCTAssertThrowsError(try p.playing(Move(uci: "e2e5")!))
        XCTAssertThrowsError(try p.move(fromSAN: "xyz"))
        // Pinned piece cannot move.
        let pinned = try Position(fen: "4k3/4r3/8/8/8/8/4B3/4K3 w - - 0 1")
        XCTAssertTrue(pinned.legalMoves(from: Square("e2")!).isEmpty)
    }
}

final class SANTests: XCTestCase {
    func testDisambiguation() throws {
        let p = try Position(fen: "4k3/8/8/8/8/8/8/R4RK1 w - - 0 1")
        XCTAssertEqual(p.san(for: Move(uci: "a1d1")!), "Rad1")
        XCTAssertEqual(p.san(for: Move(uci: "f1d1")!), "Rfd1")
        let q = try Position(fen: "4k3/8/8/R7/8/8/8/R3K3 w - - 0 1")
        XCTAssertEqual(q.san(for: Move(uci: "a1a3")!), "R1a3")
        XCTAssertEqual(q.san(for: Move(uci: "a5a3")!), "R5a3")
        let n = try Position(fen: "4k3/8/8/8/8/2N3N1/8/2N1K3 w - - 0 1")
        XCTAssertEqual(n.san(for: Move(uci: "c3e2")!), "Nc3e2")
        XCTAssertEqual(try n.move(fromSAN: "Nc3e2").uci, "c3e2")
        XCTAssertThrowsError(try n.move(fromSAN: "Ne2")) { XCTAssertEqual($0 as? ChessError, .ambiguousSAN("Ne2")) }
    }

    func testCheckAndMateSuffix() throws {
        var g = ChessGame()
        for m in ["f3", "e5", "g4"] { try g.play(san: m) }
        XCTAssertEqual(try g.play(san: "Qh4"), Move(uci: "d8h4"))
        XCTAssertEqual(g.sanMoves.last, "Qh4#")
        XCTAssertEqual(g.outcome, GameOutcome(result: .blackWins, reason: .checkmate))
        XCTAssertThrowsError(try g.play(san: "a3"), "no moves after mate")
    }

    func testLenientInput() throws {
        let p = Position.start
        XCTAssertEqual(try p.move(fromSAN: "Nf3!?").uci, "g1f3")
        XCTAssertEqual(try p.move(fromSAN: "e2e4").uci, "e2e4")
        let c = try Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        XCTAssertEqual(try c.move(fromSAN: "0-0").uci, "e1g1")
        XCTAssertEqual(try c.move(fromSAN: "0-0-0").uci, "e1c1")
    }

    func testSANRoundTripForAllLegalMoves() throws {
        let fens = [
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
            "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        ]
        for f in fens {
            let p = try Position(fen: f)
            for m in p.legalMoves() {
                XCTAssertEqual(try p.move(fromSAN: p.san(for: m)), m, "\(f) \(m)")
            }
        }
    }
}

final class OutcomeTests: XCTestCase {
    func testStalemate() throws {
        let g = try ChessGame(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
        XCTAssertEqual(g.outcome, GameOutcome(result: .draw, reason: .stalemate))
        XCTAssertTrue(g.position.isStalemate)
    }

    func testCheckmateBackRank() throws {
        var g = try ChessGame(fen: "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1")
        try g.play(san: "Ra8")
        XCTAssertTrue(g.position.isCheckmate)
        XCTAssertEqual(g.outcome?.result, .whiteWins)
    }

    func testInsufficientMaterial() throws {
        XCTAssertTrue(try Position(fen: "8/8/8/4k3/8/8/8/4K3 w - - 0 1").hasInsufficientMaterial)
        XCTAssertTrue(try Position(fen: "8/8/8/4k3/8/8/8/4KN2 w - - 0 1").hasInsufficientMaterial)
        XCTAssertTrue(try Position(fen: "8/8/8/4kb2/8/8/8/4KB2 w - - 0 1").hasInsufficientMaterial, "same-coloured bishops")
        XCTAssertFalse(try Position(fen: "8/8/8/4k1b1/8/8/8/4KB2 w - - 0 1").hasInsufficientMaterial, "opposite-coloured bishops")
        XCTAssertFalse(try Position(fen: "8/8/8/4k3/8/8/8/3NKN2 w - - 0 1").hasInsufficientMaterial)
        XCTAssertFalse(try Position(fen: "8/8/8/4k3/8/8/4P3/4K3 w - - 0 1").hasInsufficientMaterial)
        let g = try ChessGame(fen: "8/8/8/4k3/8/8/8/4K3 w - - 0 1")
        XCTAssertEqual(g.outcome?.reason, .insufficientMaterial)
    }

    func testThreefoldRepetition() throws {
        var g = ChessGame()
        for m in ["Nf3", "Nf6", "Ng1", "Ng8", "Nf3", "Nf6", "Ng1"] { try g.play(san: m) }
        XCTAssertNil(g.outcome)
        try g.play(san: "Ng8")
        XCTAssertEqual(g.outcome, GameOutcome(result: .draw, reason: .threefoldRepetition))
    }

    func testFiftyMoveRule() throws {
        var g = try ChessGame(fen: "8/8/8/4k3/8/8/R7/4K3 w - - 99 80")
        XCTAssertNil(g.outcome)
        try g.play(san: "Ra3")
        XCTAssertEqual(g.outcome?.reason, .fiftyMoveRule)
    }

    func testResignTimeoutAgreement() throws {
        var g = ChessGame()
        g.resign(.white)
        XCTAssertEqual(g.outcome, GameOutcome(result: .blackWins, reason: .resignation))
        var t2 = try ChessGame(fen: "8/8/8/4k3/8/8/8/3QK3 w - - 0 1")
        t2.timeout(.white) // black has a lone king: cannot mate
        XCTAssertEqual(t2.outcome, GameOutcome(result: .draw, reason: .timeout))
        var t3 = try ChessGame(fen: "8/8/8/4k3/8/8/8/3QK3 w - - 0 1")
        t3.timeout(.black)
        XCTAssertEqual(t3.outcome, GameOutcome(result: .whiteWins, reason: .timeout))
        var a = ChessGame()
        a.agreeDraw()
        XCTAssertEqual(a.outcome?.reason, .agreement)
    }
}

final class GameHistoryTests: XCTestCase {
    func testUndoRedoKeepsStateInSync() throws {
        var g = ChessGame()
        for m in ["e4", "c5", "Nf3", "d6", "d4", "cxd4"] { try g.play(san: m) }
        let fenAfter = g.position.fen
        XCTAssertEqual(g.movetext, "1. e4 c5 2. Nf3 d6 3. d4 cxd4")
        g.undo(); g.undo()
        XCTAssertEqual(g.plyCount, 4)
        XCTAssertTrue(g.canRedo)
        g.redo(); g.redo()
        XCTAssertEqual(g.position.fen, fenAfter)
        XCTAssertFalse(g.canRedo)
        g.undo()
        try g.play(san: "Qb6")
        XCTAssertFalse(g.canRedo, "a new move clears redo")
        XCTAssertEqual(g.positions.count, g.moves.count + 1)
        XCTAssertEqual(g.sanMoves.count, g.moves.count)
    }

    func testCountersAndCastlingAfterMoves() throws {
        var g = ChessGame()
        for m in ["e4", "e5", "Nf3", "Nc6", "Bc4", "Bc5", "O-O", "Nf6", "Re1"] { try g.play(san: m) }
        XCTAssertEqual(g.position.fen, "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQR1K1 b kq - 7 5")
    }

    func testStartFromBlackToMove() throws {
        var g = try ChessGame(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1")
        try g.play(san: "c5")
        try g.play(san: "Nf3")
        XCTAssertEqual(g.movetext, "1... c5 2. Nf3")
    }
}
