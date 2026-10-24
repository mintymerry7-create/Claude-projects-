import Foundation
import ChessKitEngine
import ChessEngine
import AppFeatures

/// Provides Stockfish 17 (compiled into the app through ChessKitEngine) when
/// its NNUE network files are bundled, and the built-in engine otherwise.
///
/// Stockfish needs two network files that are not stored in git because of
/// their size. Run `Scripts/fetch-stockfish-nets.sh` once before building;
/// it places them in Resources/EngineNets, which is copied into the app.
final class StockfishEngineProvider: EngineProvider {
    static let bigNet = "nn-1111cefa1111"
    static let smallNet = "nn-37f18f62d772"

    private let evalFile: URL?
    private let evalFileSmall: URL?
    var preferStockfish = true

    init(bundle: Bundle = .main) {
        evalFile = Self.locate(Self.bigNet, in: bundle)
        evalFileSmall = Self.locate(Self.smallNet, in: bundle)
    }

    private static func locate(_ name: String, in bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: "nnue", subdirectory: "EngineNets")
            ?? bundle.url(forResource: name, withExtension: "nnue")
    }

    var isStockfishAvailable: Bool { evalFile != nil && evalFileSmall != nil }

    var engineName: String { isStockfishAvailable && preferStockfish ? "Stockfish 17" : "Knight (built-in)" }

    func makeEngine() -> ChessEngine {
        guard preferStockfish, let big = evalFile, let small = evalFileSmall else { return BuiltInEngine() }
        let transport = ChessKitTransport(evalFile: big, evalFileSmall: small)
        return UCIEngine(name: "Stockfish 17", transport: transport, options: [("Hash", "32")], responseTimeout: 20)
    }
}

/// Bridges ChessKitEngine's typed command/response API to the generic UCI client.
final class ChessKitTransport: UCITransport, @unchecked Sendable {
    private let engine = Engine(type: .stockfish)
    private let evalFile: URL
    private let evalFileSmall: URL
    private var continuation: AsyncStream<String>.Continuation?
    private var pump: Task<Void, Never>?
    let output: AsyncStream<String>

    init(evalFile: URL, evalFileSmall: URL) {
        self.evalFile = evalFile
        self.evalFileSmall = evalFileSmall
        var cont: AsyncStream<String>.Continuation?
        output = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    func start() async throws {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        await engine.start(coreCount: cores, multipv: 1)
        // ChessKitEngine finishes its own uci/isready handshake before reporting running.
        var waitedMs = 0
        while !(await engine.isRunning) {
            try await Task.sleep(nanoseconds: 50_000_000)
            waitedMs += 50
            if waitedMs > 8_000 { throw EngineError.launchFailed("Stockfish did not start.") }
        }
        guard let stream = await engine.responseStream else { throw EngineError.launchFailed("No response stream.") }
        let cont = continuation
        pump = Task {
            for await response in stream {
                if let line = Self.uciLine(from: response) { cont?.yield(line) }
            }
            cont?.finish()
        }
        await engine.send(command: .setoption(id: "EvalFile", value: evalFile.path))
        await engine.send(command: .setoption(id: "EvalFileSmall", value: evalFileSmall.path))
    }

    func send(_ command: UCICommand) async {
        switch command {
        case .uci:
            await engine.send(command: .uci)
        case .isready:
            await engine.send(command: .isready)
        case let .setoption(name, value):
            await engine.send(command: .setoption(id: name, value: value))
        case .ucinewgame:
            await engine.send(command: .ucinewgame)
        case let .position(fen, moves):
            await engine.send(command: .position(.fen(fen), moves: moves.isEmpty ? nil : moves))
        case let .go(depth, movetime, nodes):
            await engine.send(command: .go(depth: depth, nodes: nodes, movetime: movetime))
        case .stop:
            await engine.send(command: .stop)
        case .quit:
            break // handled by Engine.stop()
        }
    }

    func terminate() async {
        await engine.stop()
        pump?.cancel()
        continuation?.finish()
    }

    /// Re-creates a UCI text line from a parsed ChessKitEngine response.
    static func uciLine(from response: EngineResponse) -> String? {
        switch response {
        case .uciok:
            return "uciok"
        case .readyok:
            return "readyok"
        case let .bestmove(move, ponder):
            return "bestmove \(move)" + (ponder.map { " ponder \($0)" } ?? "")
        case let .info(info):
            var parts = ["info"]
            if let d = info.depth { parts += ["depth", String(d)] }
            if let k = info.multipv { parts += ["multipv", String(k)] }
            if let s = info.score {
                if let mate = s.mate {
                    parts += ["score", "mate", String(mate)]
                } else if let cp = s.cp {
                    parts += ["score", "cp", String(Int(cp.rounded()))]
                }
                if s.lowerbound == true { parts.append("lowerbound") }
                if s.upperbound == true { parts.append("upperbound") }
            }
            if let pv = info.pv, !pv.isEmpty { parts += ["pv"] + pv }
            return parts.count > 1 ? parts.joined(separator: " ") : nil
        default:
            return nil
        }
    }
}
