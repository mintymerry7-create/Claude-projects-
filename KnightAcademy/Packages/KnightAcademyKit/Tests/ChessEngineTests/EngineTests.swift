import XCTest
import ChessCore
@testable import ChessEngine

final class UCIParserTests: XCTestCase {
    func testParsesInfoAndBestmove() {
        let info = UCIParser.parse("info depth 18 seldepth 25 multipv 2 score cp -34 nodes 123456 nps 999 hashfull 12 tbhits 0 time 450 pv e7e5 g1f3 b8c6")
        guard case let .info(i) = info else { return XCTFail("not info") }
        XCTAssertEqual(i.depth, 18)
        XCTAssertEqual(i.multipv, 2)
        XCTAssertEqual(i.score, .centipawns(-34))
        XCTAssertEqual(i.pv, ["e7e5", "g1f3", "b8c6"])
        XCTAssertEqual(i.nodes, 123_456)
        XCTAssertFalse(i.isBound)

        guard case let .info(m) = UCIParser.parse("info depth 5 score mate -2 upperbound pv a1a2") else { return XCTFail() }
        XCTAssertEqual(m.score, .mate(-2))
        XCTAssertTrue(m.isBound)

        XCTAssertEqual(UCIParser.parse("bestmove e2e4 ponder e7e5"), .bestmove("e2e4", ponder: "e7e5"))
        XCTAssertEqual(UCIParser.parse("bestmove (none)"), .bestmove("(none)", ponder: nil))
        XCTAssertEqual(UCIParser.parse("readyok"), .readyok)
        XCTAssertEqual(UCIParser.parse("id name Stockfish 17"), .id(name: "Stockfish 17"))
        XCTAssertEqual(UCIParser.parse("option name Hash type spin"), .other("option name Hash type spin"))
    }

    func testCommandsSerialise() {
        XCTAssertEqual(UCICommand.position(fen: Position.startFEN, moves: ["e2e4"]).rawValue,
                       "position fen \(Position.startFEN) moves e2e4")
        XCTAssertEqual(UCICommand.go(depth: 10, movetime: 500, nodes: nil).rawValue, "go depth 10 movetime 500")
        XCTAssertEqual(UCICommand.setoption(name: "Skill Level", value: "5").rawValue, "setoption name Skill Level value 5")
    }

    func testScores() {
        XCTAssertGreaterThan(EngineScore.mate(3), .centipawns(5000))
        XCTAssertLessThan(EngineScore.mate(-1), .centipawns(-5000))
        XCTAssertGreaterThan(EngineScore.mate(1), .mate(4))
        XCTAssertEqual(EngineScore.centipawns(30).fromWhite(sideToMove: .black), .centipawns(-30))
        XCTAssertEqual(EngineScore.centipawns(0).winningChances, 0, accuracy: 1e-9)
        XCTAssertEqual(EngineScore.centipawns(125).display, "+1.25")
    }
}

final class BuiltInEngineTests: XCTestCase {
    func search(_ fen: String, depth: Int = 4, skill: Int? = nil) async throws -> SearchResult {
        let engine = BuiltInEngine(seed: 42)
        return try await engine.search(SearchRequest(position: try Position(fen: fen), limit: SearchLimit(depth: depth, moveTimeMs: 20_000), skillLevel: skill))
    }

    func testFindsMateInOne() async throws {
        let r = try await search("6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", depth: 2)
        XCTAssertEqual(r.bestMove.uci, "a1a8")
        XCTAssertEqual(r.score, .mate(1))
    }

    func testFindsMateInTwo() async throws {
        // Smothered mate: 1.Qg8+ Rxg8 2.Nf7# (verified with Stockfish).
        let r = try await search("r6k/6pp/7N/8/2Q5/8/8/6K1 w - - 0 1", depth: 4)
        XCTAssertEqual(r.bestMove.uci, "c4g8")
        XCTAssertEqual(r.score, .mate(2))
    }

    func testWinsHangingQueen() async throws {
        let r = try await search("rnb1kbnr/pppp1ppp/8/4p1q1/4P3/3P4/PPP2PPP/RNBQKBNR w KQkq - 1 3", depth: 3)
        XCTAssertEqual(r.bestMove.uci, "c1g5")
    }

    func testAvoidsStalemateWhenWinning() async throws {
        // Queen move Qf7?? stalemates; engine should mate or keep winning instead.
        let r = try await search("7k/8/5K2/8/8/8/8/6Q1 w - - 0 1", depth: 4)
        var p = try Position(fen: "7k/8/5K2/8/8/8/8/6Q1 w - - 0 1")
        p.make(r.bestMove)
        XCTAssertFalse(p.isStalemate)
    }

    func testAlwaysReturnsLegalMovesAtAnySkill() async throws {
        var game = ChessGame()
        let engine = BuiltInEngine(seed: 7)
        let player = BotPlayer(engine: engine, profile: .beginner)
        for _ in 0..<30 where !game.isOver {
            let m = try await player.chooseMove(in: game)
            XCTAssertTrue(game.position.isLegal(m.move))
            try game.play(m.move)
        }
    }

    func testNoLegalMovesThrows() async {
        let engine = BuiltInEngine()
        do {
            _ = try await engine.search(SearchRequest(position: try Position(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"), limit: .depth(2)))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? EngineError, .noLegalMoves)
        }
    }

    func testZobristDistinguishesSideAndCastling() throws {
        let a = Position.start
        let b = try Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1")
        let c = try Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w Kkq - 0 1")
        XCTAssertNotEqual(a.zobrist, b.zobrist)
        XCTAssertNotEqual(a.zobrist, c.zobrist)
        XCTAssertEqual(a.zobrist, Position.start.zobrist)
    }
}

final class BookAndAnalysisTests: XCTestCase {
    func testOpeningBookFollowsTreeAndTranspositions() throws {
        var tree = MoveTree()
        try tree.addLine(sans: ["e4", "c5", "Nf3", "d6"])
        try tree.addLine(sans: ["Nf3", "c5", "e4"])
        let book = OpeningBook(tree: tree)
        var p = Position.start
        XCTAssertEqual(Set(book.moves(for: p).map(\.move.uci)), ["e2e4", "g1f3"])
        p = try p.playing(san: "Nf3").playing(san: "c5").playing(san: "e4")
        // Transposes into the 1.e4 c5 2.Nf3 line: book suggests ...d6.
        XCTAssertEqual(book.moves(for: p).map(\.move.uci), ["d7d6"])
        p = try p.playing(san: "a6")
        XCTAssertTrue(book.moves(for: p).isEmpty)
    }

    func testBotUsesBookThenEngine() async throws {
        var tree = MoveTree()
        try tree.addLine(sans: ["e4", "c5"])
        let bot = BotPlayer(engine: BuiltInEngine(seed: 1), profile: .easy, book: OpeningBook(tree: tree))
        var g = ChessGame()
        try g.play(san: "e4")
        let reply = try await bot.chooseMove(in: g)
        XCTAssertEqual(reply.move.uci, "c7c5")
        XCTAssertEqual(reply.source, .book)
        try g.play(reply.move)
        try g.play(san: "Nc3")
        let next = try await bot.chooseMove(in: g)
        if case .engine = next.source {} else { XCTFail("expected engine move out of book") }
    }

    func testAnalyzerFlagsBlunder() async throws {
        var g = ChessGame()
        for m in ["e4", "e5", "Qh5", "Nc6", "Bc4", "Nf6", "Qxf7#"] { try g.play(san: m) }
        let analyzer = GameAnalyzer(engine: BuiltInEngine(seed: 3), depth: 3, moveTimeMs: 5_000)
        let a = try await analyzer.analyze(g, bookPlies: 2)
        XCTAssertEqual(a.moves.count, 7)
        XCTAssertEqual(a.moves[0].classification, .book)
        XCTAssertEqual(a.moves[5].san, "Nf6")
        XCTAssertEqual(a.moves[5].classification, .blunder)
        XCTAssertEqual(a.moves[5].bestSAN.map { ["g6", "Qe7", "Qf6"].contains($0) }, true, a.moves[5].bestSAN ?? "")
        XCTAssertEqual(a.moves[6].evalAfter, .mate(1))
        XCTAssertGreaterThan(a.whiteAccuracy, a.blackAccuracy)
        XCTAssertEqual(a.keyMoments.first?.ply, 5)
    }
}

/// Talks to a real Stockfish binary over UCI when one is installed
/// (`stockfish` on PATH, /usr/games/stockfish, or $STOCKFISH_PATH).
final class StockfishUCITests: XCTestCase {
    #if os(macOS) || os(Linux)
    func stockfishURL() -> URL? {
        let env = ProcessInfo.processInfo.environment["STOCKFISH_PATH"]
        for path in [env, "/usr/local/bin/stockfish", "/usr/games/stockfish", "/opt/homebrew/bin/stockfish"].compactMap({ $0 })
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func testRealStockfishSearch() async throws {
        guard let url = stockfishURL() else { throw XCTSkip("Stockfish binary not installed") }
        let engine = UCIEngine(name: "Stockfish", transport: ProcessUCITransport(executable: url), options: [("Threads", "1")])
        defer { Task { await engine.shutdown() } }

        // Mate in one.
        let mate = try await engine.search(SearchRequest(position: try Position(fen: "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1"), limit: .depth(8)))
        XCTAssertEqual(mate.bestMove.uci, "a1a8")
        XCTAssertEqual(mate.score, .mate(1))

        // Multi-PV and skill settings round-trip; all PV moves must be legal.
        let start = try await engine.search(SearchRequest(position: .start, limit: .depth(10), skillLevel: 20, multiPV: 3))
        XCTAssertEqual(start.lines.count, 3)
        XCTAssertTrue(Position.start.isLegal(start.bestMove))
        for line in start.lines { XCTAssertFalse(line.pv.isEmpty) }

        let weak = try await engine.search(SearchRequest(position: .start, limit: SearchLimit(depth: 1, moveTimeMs: 50), skillLevel: 0))
        XCTAssertTrue(Position.start.isLegal(weak.bestMove))

        // Analysis through the generic analyzer.
        var g = ChessGame()
        for m in ["e4", "e5", "Qh5", "Nc6", "Bc4", "Nf6", "Qxf7#"] { try g.play(san: m) }
        let analysis = try await GameAnalyzer(engine: engine, depth: 10, moveTimeMs: 300).analyze(g)
        XCTAssertEqual(analysis.moves[5].classification, .blunder)
        XCTAssertEqual(analysis.moves[4].classification == .blunder || analysis.moves[4].classification == .mistake, false)
    }
    #endif
}
