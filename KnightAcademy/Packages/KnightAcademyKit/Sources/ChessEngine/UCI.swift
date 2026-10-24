import Foundation
import ChessCore

/// Commands sent to a UCI engine.
public enum UCICommand: Hashable, Sendable {
    case uci
    case isready
    case setoption(name: String, value: String?)
    case ucinewgame
    case position(fen: String, moves: [String])
    case go(depth: Int?, movetime: Int?, nodes: Int?)
    case stop
    case quit

    public var rawValue: String {
        switch self {
        case .uci: return "uci"
        case .isready: return "isready"
        case let .setoption(name, value):
            return "setoption name \(name)" + (value.map { " value \($0)" } ?? "")
        case .ucinewgame: return "ucinewgame"
        case let .position(fen, moves):
            return "position fen \(fen)" + (moves.isEmpty ? "" : " moves " + moves.joined(separator: " "))
        case let .go(depth, movetime, nodes):
            var s = "go"
            if let depth { s += " depth \(depth)" }
            if let nodes { s += " nodes \(nodes)" }
            if let movetime { s += " movetime \(movetime)" }
            return s
        case .stop: return "stop"
        case .quit: return "quit"
        }
    }
}

/// Parsed engine output.
public enum UCIMessage: Hashable, Sendable {
    case id(name: String)
    case uciok
    case readyok
    case bestmove(String, ponder: String?)
    case info(UCIInfo)
    case other(String)
}

public struct UCIInfo: Hashable, Sendable {
    public var depth: Int?
    public var multipv: Int?
    public var score: EngineScore?
    /// true when the score is only a bound (lowerbound/upperbound).
    public var isBound = false
    public var pv: [String] = []
    public var nodes: Int?
    public var nps: Int?
    public var time: Int?
}

public enum UCIParser {
    public static func parse(_ rawLine: String) -> UCIMessage {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = line.split(separator: " ").map(String.init)
        guard let head = t.first else { return .other(line) }
        switch head {
        case "uciok": return .uciok
        case "readyok": return .readyok
        case "id":
            if t.count >= 3, t[1] == "name" { return .id(name: t[2...].joined(separator: " ")) }
            return .other(line)
        case "bestmove":
            guard t.count >= 2 else { return .other(line) }
            let ponder = (t.count >= 4 && t[2] == "ponder") ? t[3] : nil
            return .bestmove(t[1], ponder: ponder)
        case "info":
            return .info(parseInfo(Array(t.dropFirst())))
        default:
            return .other(line)
        }
    }

    static func parseInfo(_ t: [String]) -> UCIInfo {
        var info = UCIInfo()
        var i = 0
        while i < t.count {
            let key = t[i]
            func int(_ k: Int) -> Int? { k < t.count ? Int(t[k]) : nil }
            switch key {
            case "depth": info.depth = int(i + 1); i += 2
            case "multipv": info.multipv = int(i + 1); i += 2
            case "nodes": info.nodes = int(i + 1); i += 2
            case "nps": info.nps = int(i + 1); i += 2
            case "time": info.time = int(i + 1); i += 2
            case "score":
                if i + 2 < t.count, let v = Int(t[i + 2]) {
                    info.score = t[i + 1] == "mate" ? .mate(v) : .centipawns(v)
                }
                i += 3
                if i < t.count, t[i] == "lowerbound" || t[i] == "upperbound" {
                    info.isBound = true
                    i += 1
                }
            case "pv":
                info.pv = Array(t[(i + 1)...])
                i = t.count
            case "string":
                i = t.count
            case "seldepth", "hashfull", "tbhits", "currmovenumber", "cpuload", "currmove", "sbhits":
                i += 2
            default:
                i += 1
            }
        }
        return info
    }
}

/// A byte pipe to a UCI engine. Implementations: a child process on
/// macOS/Linux (tests, tools) and ChessKitEngine's in-process Stockfish on iOS.
public protocol UCITransport: AnyObject, Sendable {
    /// Launches the engine and sends `uci` (the client waits for readiness).
    func start() async throws
    func send(_ command: UCICommand) async
    /// Raw output lines, in order where the transport guarantees it.
    var output: AsyncStream<String> { get }
    func terminate() async
}

/// Generic UCI engine client. It serialises searches, re-synchronises with
/// `isready` before each one and validates the engine's move against the
/// requested position, so stale output from an earlier search is ignored.
public actor UCIEngine: ChessEngine {
    public nonisolated let displayName: String
    private let transport: UCITransport
    private let queue = LineQueue()
    private var reader: Task<Void, Never>?
    private var started = false
    private var currentSkill: Int?
    private var currentMultiPV = 1
    private let startupOptions: [(String, String)]
    public let responseTimeout: TimeInterval

    public init(name: String, transport: UCITransport, options: [(String, String)] = [], responseTimeout: TimeInterval = 30) {
        self.displayName = name
        self.transport = transport
        self.startupOptions = options
        self.responseTimeout = responseTimeout
    }

    public func ensureStarted() async throws {
        guard !started else { return }
        try await transport.start()
        let stream = transport.output
        let queue = self.queue
        reader = Task {
            for await line in stream { await queue.push(line) }
            await queue.finish()
        }
        for (k, v) in startupOptions { await transport.send(.setoption(name: k, value: v)) }
        started = true
        try await sync()
    }

    /// Waits for a message matching `predicate`, with a timeout.
    private func waitFor(_ predicate: @escaping (UCIMessage) -> Bool,
                         collect: ((UCIMessage) -> Void)? = nil) async throws -> UCIMessage {
        let deadline = Date().addingTimeInterval(responseTimeout)
        while true {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw EngineError.timeout }
            guard let line = await queue.next(timeout: remaining) else {
                if await queue.isFinished { throw EngineError.notRunning }
                throw EngineError.timeout
            }
            let msg = UCIParser.parse(line)
            if predicate(msg) { return msg }
            collect?(msg)
        }
    }

    private func sync() async throws {
        await transport.send(.isready)
        _ = try await waitFor { $0 == .readyok }
    }

    public func newGame() async {
        guard (try? await ensureStarted()) != nil else { return }
        await transport.send(.ucinewgame)
        try? await sync()
    }

    public func search(_ request: SearchRequest) async throws -> SearchResult {
        let legal = request.position.legalMoves()
        guard !legal.isEmpty else { throw EngineError.noLegalMoves }
        try await ensureStarted()

        let skill = request.skillLevel.map { max(0, min(20, $0)) } ?? 20
        if skill != currentSkill {
            await transport.send(.setoption(name: "Skill Level", value: String(skill)))
            currentSkill = skill
        }
        if request.multiPV != currentMultiPV {
            await transport.send(.setoption(name: "MultiPV", value: String(request.multiPV)))
            currentMultiPV = request.multiPV
        }
        try await sync()

        await transport.send(.position(fen: request.position.fen, moves: []))
        let l = request.limit
        await transport.send(.go(depth: l.depth, movetime: l.moveTimeMs ?? (l.depth == nil && l.nodes == nil ? 1000 : nil), nodes: l.nodes))

        var lines: [Int: EngineLine] = [:]
        let position = request.position
        func collect(_ msg: UCIMessage) {
            guard case let .info(info) = msg, let score = info.score, !info.isBound, !info.pv.isEmpty,
                  let depth = info.depth else { return }
            let pv = Self.legalPrefix(info.pv, from: position)
            guard !pv.isEmpty else { return }
            let k = info.multipv ?? 1
            if let existing = lines[k], existing.depth > depth { return }
            lines[k] = EngineLine(pv: pv, score: score, depth: depth, multipv: k)
        }

        let best: Move
        do {
            let msg = try await waitFor({ msg in
                if case let .bestmove(m, _) = msg, let mv = Move(uci: m), legal.contains(mv) { return true }
                return false
            }, collect: collect)
            guard case let .bestmove(m, _) = msg, let mv = Move(uci: m) else { throw EngineError.timeout }
            best = mv
        } catch is CancellationError {
            await transport.send(.stop)
            throw EngineError.cancelled
        }
        let sorted = lines.values.sorted { $0.multipv < $1.multipv }
        return SearchResult(bestMove: best, lines: sorted)
    }

    /// Keeps the longest legal prefix of a UCI move list.
    static func legalPrefix(_ uci: [String], from start: Position) -> [Move] {
        var p = start
        var out: [Move] = []
        for s in uci {
            guard let m = Move(uci: s), p.isLegal(m) else { break }
            p.make(m)
            out.append(m)
        }
        return out
    }

    public func stop() async { await transport.send(.stop) }

    public func shutdown() async {
        guard started else { return }
        await transport.send(.quit)
        await transport.terminate()
        reader?.cancel()
        reader = nil
        started = false
    }
}

/// FIFO of engine output lines with a timed wait.
actor LineQueue {
    private var lines: [String] = []
    private var head = 0
    private var waiter: (UUID, CheckedContinuation<String?, Never>)?
    private var timer: Task<Void, Never>?
    private(set) var isFinished = false

    func push(_ line: String) {
        if let w = waiter {
            waiter = nil
            timer?.cancel()
            timer = nil
            w.1.resume(returning: line)
        } else {
            lines.append(line)
        }
    }

    func finish() {
        isFinished = true
        if let w = waiter {
            waiter = nil
            w.1.resume(returning: nil)
        }
    }

    func next(timeout: TimeInterval) async -> String? {
        if head < lines.count {
            let l = lines[head]
            head += 1
            if head > 512 { lines.removeFirst(head); head = 0 }
            return l
        }
        if isFinished { return nil }
        let token = UUID()
        return await withCheckedContinuation { cont in
            waiter = (token, cont)
            timer = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                } catch { return }
                self.expire(token)
            }
        }
    }

    private func expire(_ token: UUID) {
        if let w = waiter, w.0 == token {
            waiter = nil
            w.1.resume(returning: nil)
        }
    }
}

#if os(macOS) || os(Linux)
/// Runs a UCI engine binary as a child process (macOS tools and Linux tests).
public final class ProcessUCITransport: UCITransport, @unchecked Sendable {
    private let executable: URL
    private var process: Process?
    private var inputPipe: Pipe?
    private let lock = NSLock()
    private var continuation: AsyncStream<String>.Continuation?
    public let output: AsyncStream<String>
    private var buffer = Data()

    public init(executable: URL) {
        self.executable = executable
        var cont: AsyncStream<String>.Continuation?
        output = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    public func start() async throws {
        let p = Process()
        p.executableURL = executable
        let input = Pipe(), out = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty {
                self.continuation?.finish()
                h.readabilityHandler = nil
                return
            }
            self.lock.lock()
            self.buffer.append(data)
            var lines: [String] = []
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer[self.buffer.startIndex..<nl]
                lines.append(String(decoding: lineData, as: UTF8.self))
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
            }
            self.lock.unlock()
            for l in lines { self.continuation?.yield(l) }
        }
        do { try p.run() } catch { throw EngineError.launchFailed(error.localizedDescription) }
        process = p
        inputPipe = input
        await send(.uci)
    }

    public func send(_ command: UCICommand) async {
        guard let data = (command.rawValue + "\n").data(using: .utf8) else { return }
        inputPipe?.fileHandleForWriting.write(data)
    }

    public func terminate() async {
        process?.terminate()
        process = nil
        continuation?.finish()
    }
}
#endif
