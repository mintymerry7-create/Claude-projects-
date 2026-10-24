import Foundation
import Observation
import ChessCore
import ChessEngine
import OpeningDatabase
import Learning

public struct TimeControl: Codable, Hashable, Sendable, Identifiable {
    /// nil = untimed.
    public var minutes: Int?
    public var incrementSeconds: Int

    public init(minutes: Int?, incrementSeconds: Int = 0) {
        self.minutes = minutes
        self.incrementSeconds = incrementSeconds
    }

    public var id: String { minutes.map { "\($0)+\(incrementSeconds)" } ?? "untimed" }
    public var isTimed: Bool { minutes != nil }
    public var display: String {
        guard let m = minutes else { return "No clock" }
        return "\(m)+\(incrementSeconds)"
    }

    public static let untimed = TimeControl(minutes: nil)
    public static let presets: [TimeControl] = [
        .untimed, TimeControl(minutes: 3, incrementSeconds: 2), TimeControl(minutes: 5),
        TimeControl(minutes: 10), TimeControl(minutes: 15, incrementSeconds: 10), TimeControl(minutes: 30),
    ]
}

/// Chess clock with increments. Time is charged to the side to move.
public struct ChessClock: Codable, Hashable, Sendable {
    public private(set) var remainingMs: [PieceColor: Int]
    public let incrementMs: Int
    public private(set) var running: PieceColor?
    public private(set) var turnStartedAt: Date?

    public init(control: TimeControl) {
        let ms = (control.minutes ?? 0) * 60_000
        remainingMs = [.white: ms, .black: ms]
        incrementMs = control.incrementSeconds * 1000
    }

    public func remaining(_ color: PieceColor, now: Date = Date()) -> Int {
        var r = remainingMs[color] ?? 0
        if running == color, let start = turnStartedAt {
            r -= Int(now.timeIntervalSince(start) * 1000)
        }
        return max(0, r)
    }

    public mutating func start(_ color: PieceColor, now: Date = Date()) {
        running = color
        turnStartedAt = now
    }

    /// Ends `color`'s turn: charges elapsed time, adds the increment, starts the opponent.
    public mutating func press(_ color: PieceColor, now: Date = Date()) {
        let left = remaining(color, now: now)
        remainingMs[color] = left + incrementMs
        start(color.opposite, now: now)
    }

    public mutating func stop(now: Date = Date()) {
        if let c = running { remainingMs[c] = remaining(c, now: now) }
        running = nil
        turnStartedAt = nil
    }

    public func flagged(now: Date = Date()) -> PieceColor? {
        guard let c = running else { return nil }
        return remaining(c, now: now) <= 0 ? c : nil
    }
}

public struct GameSetup: Hashable, Sendable {
    public var bot: BotProfile
    public var playerColor: PieceColor
    public var timeControl: TimeControl
    public var startFEN: String?
    /// Moves to play from the start before handing over (e.g. an opening's defining moves).
    public var startMoves: [String]
    /// The bot follows this tree while in book (opening practice / repertoire).
    public var book: MoveTree?
    public var bookName: String?
    /// The player's own theory, to tell them when they leave it.
    public var playerBook: MoveTree?
    public var casual: Bool

    public init(bot: BotProfile, playerColor: PieceColor, timeControl: TimeControl = .untimed,
                startFEN: String? = nil, startMoves: [String] = [], book: MoveTree? = nil,
                bookName: String? = nil, playerBook: MoveTree? = nil, casual: Bool = true) {
        self.bot = bot
        self.playerColor = playerColor
        self.timeControl = timeControl
        self.startFEN = startFEN
        self.startMoves = startMoves
        self.book = book
        self.bookName = bookName
        self.playerBook = playerBook
        self.casual = casual
    }
}

public enum GamePhase: Equatable, Sendable {
    case playerToMove
    case botThinking
    case finished(GameOutcome)
}

/// A game against a computer opponent.
@MainActor
@Observable
public final class GameSession {
    public private(set) var game: ChessGame
    public let setup: GameSetup
    public private(set) var phase: GamePhase = .playerToMove
    public private(set) var clock: ChessClock
    public private(set) var hint: Move?
    public private(set) var lastBotScore: EngineScore?
    public private(set) var message: String?
    /// Ply at which the game left the player's or the bot's book (nil = still in book / no book).
    public private(set) var leftBookAtPly: Int?
    public private(set) var bookPlies = 0
    public private(set) var errorMessage: String?
    public let engineName: String

    private let bot: BotPlayer
    private let playerBook: OpeningBook?
    private var thinkTask: Task<Void, Never>?

    public init(setup: GameSetup, engine: ChessEngine) throws {
        var g = try setup.startFEN.map { try ChessGame(fen: $0) } ?? ChessGame()
        for san in setup.startMoves { try g.play(san: san) }
        game = g
        self.setup = setup
        clock = ChessClock(control: setup.timeControl)
        bot = BotPlayer(engine: engine, profile: setup.bot, book: setup.book.map(OpeningBook.init))
        playerBook = setup.playerBook.map(OpeningBook.init)
        engineName = engine.displayName
        bookPlies = setup.startMoves.count
        if game.isOver, let o = game.outcome { phase = .finished(o) }
    }

    public var position: Position { game.position }
    public var isPlayerTurn: Bool { phase == .playerToMove && game.sideToMove == setup.playerColor }
    public var canUndo: Bool { setup.casual && game.plyCount > setup.startMoves.count && phase != .botThinking && !isFinished }
    public var isFinished: Bool { if case .finished = phase { return true }; return false }
    public var outcome: GameOutcome? { if case .finished(let o) = phase { return o }; return nil }

    public var display: BoardDisplay {
        var arrows: [Arrow] = []
        if let h = hint, isPlayerTurn { arrows.append(Arrow(from: h.from, to: h.to, kind: .engine)) }
        return BoardDisplay(position: position, orientation: setup.playerColor, lastMove: game.lastMove,
                            arrows: arrows, interactive: isPlayerTurn)
    }

    /// Starts clocks and lets the bot move first if it has White.
    public func start() {
        if setup.timeControl.isTimed && !isFinished { clock.start(game.sideToMove) }
        if game.sideToMove != setup.playerColor && !isFinished { requestBotMove() }
    }

    /// Plays the player's move. Returns false if it was rejected.
    @discardableResult
    public func play(_ move: Move) -> Bool {
        guard isPlayerTurn, game.position.isLegal(move) else { return false }
        let before = game.position
        if let pb = playerBook, leftBookAtPly == nil, pb.contains(before) {
            let bookMoves = pb.moves(for: before).map(\.move)
            if !bookMoves.contains(move), let main = bookMoves.first {
                leftBookAtPly = game.plyCount
                message = "You left your theory here — the prepared move was \(before.san(for: main))."
            }
        }
        do { try game.play(move) } catch { return false }
        hint = nil
        if setup.timeControl.isTimed { clock.press(setup.playerColor) }
        if checkEnd() { return true }
        requestBotMove()
        return true
    }

    public func requestBotMove() {
        guard !isFinished, game.sideToMove != setup.playerColor else { return }
        phase = .botThinking
        let snapshot = game
        thinkTask?.cancel()
        thinkTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Respect the bot's own clock in timed games.
                if self.setup.timeControl.isTimed {
                    let left = self.clock.remaining(self.setup.playerColor.opposite)
                    self.bot.profile.moveTimeMs = max(50, min(self.setup.bot.moveTimeMs, left / 30))
                }
                let choice = try await self.bot.chooseMove(in: snapshot)
                guard !Task.isCancelled, self.game == snapshot else { return }
                try self.game.play(choice.move)
                switch choice.source {
                case .book:
                    self.bookPlies = self.game.plyCount
                case .engine(let score):
                    self.lastBotScore = score
                    if self.setup.book != nil, self.leftBookAtPly == nil {
                        self.leftBookAtPly = snapshot.plyCount
                        if self.message == nil { self.message = "Out of book — the bot now plays its own moves." }
                    }
                }
                if self.setup.timeControl.isTimed { self.clock.press(self.setup.playerColor.opposite) }
                if !self.checkEnd() { self.phase = .playerToMove }
            } catch is CancellationError {
            } catch EngineError.cancelled {
            } catch {
                self.errorMessage = error.localizedDescription
                self.phase = .playerToMove
            }
        }
    }

    /// Takes back the last full move (casual games only).
    public func undo() {
        guard canUndo else { return }
        thinkTask?.cancel()
        game.undo()
        if game.sideToMove != setup.playerColor && game.plyCount > setup.startMoves.count { game.undo() }
        hint = nil
        phase = .playerToMove
        if let left = leftBookAtPly, game.plyCount <= left { leftBookAtPly = nil; message = nil }
    }

    public func requestHint() async {
        guard isPlayerTurn else { return }
        do {
            hint = try await bot.hint(for: game.position).bestMove
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func resign() {
        guard !isFinished else { return }
        thinkTask?.cancel()
        game.resign(setup.playerColor)
        _ = checkEnd()
    }

    /// The bot accepts a draw when it is not better (engine evaluation ≤ +0.3 for the bot).
    @discardableResult
    public func offerDraw() async -> Bool {
        guard isPlayerTurn else { return false }
        do {
            // The player is to move, so the engine score is the player's; negate for the bot.
            let r = try await bot.engine.search(SearchRequest(position: game.position, limit: SearchLimit(depth: 12, moveTimeMs: 500)))
            let botScore = (r.score ?? .centipawns(0)).negated
            if botScore.sortValue <= 30 && game.plyCount >= 20 {
                game.agreeDraw()
                _ = checkEnd()
                message = "The bot accepted your draw offer."
                return true
            }
            message = game.plyCount < 20 ? "The bot declines — it's too early for a draw." : "The bot declines — it thinks it is better."
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    /// Call periodically from the UI in timed games.
    public func tick(now: Date = Date()) {
        guard setup.timeControl.isTimed, !isFinished, let flagged = clock.flagged(now: now) else { return }
        thinkTask?.cancel()
        game.timeout(flagged)
        _ = checkEnd()
    }

    @discardableResult
    private func checkEnd() -> Bool {
        if let o = game.outcome {
            clock.stop()
            phase = .finished(o)
            return true
        }
        return false
    }

    /// The finished game as a saved record.
    public func savedGame(openingName: String?) -> SavedGame? {
        guard let o = outcome else { return nil }
        let white = setup.playerColor == .white ? "You" : "\(setup.bot.name) bot"
        let black = setup.playerColor == .black ? "You" : "\(setup.bot.name) bot"
        var tags = ["Event": "Knight Academy", "White": white, "Black": black,
                    "Date": Self.pgnDate.string(from: Date()), "Termination": o.reason.displayName]
        if setup.timeControl.isTimed { tags["TimeControl"] = "\((setup.timeControl.minutes ?? 0) * 60)+\(setup.timeControl.incrementSeconds)" }
        if let name = openingName { tags["Opening"] = name }
        return SavedGame(pgn: game.pgn(tags: tags), opponent: "\(setup.bot.name) bot", playerColor: setup.playerColor,
                         result: o.result.rawValue, reason: o.reason.displayName, openingName: openingName)
    }

    static let pgnDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// Step-through replay of a finished game with optional engine analysis.
public struct GameReplay: Sendable {
    public let game: ChessGame
    public let analysis: GameAnalysis?
    public private(set) var ply: Int

    public init(game: ChessGame, analysis: GameAnalysis? = nil) {
        self.game = game
        self.analysis = analysis
        ply = game.plyCount
    }

    public init(pgn: String, analysis: GameAnalysis? = nil) throws {
        let parsed = try PGNParser.parseFirst(pgn)
        self.init(game: try parsed.mainlineGame(), analysis: analysis)
    }

    public var position: Position { game.positions[ply] }
    public var lastMove: Move? { ply > 0 ? game.moves[ply - 1] : nil }
    public var moveAnalysis: MoveAnalysis? { ply > 0 ? analysis?.moves.first { $0.ply == ply - 1 } : nil }

    public var display: BoardDisplay {
        var arrows: [Arrow] = []
        if let a = moveAnalysis, a.classification != .best, a.classification != .book, let best = a.bestMove,
           [.inaccuracy, .mistake, .blunder].contains(a.classification) {
            arrows.append(Arrow(from: best.from, to: best.to, kind: .engine))
        }
        return BoardDisplay(position: position, lastMove: lastMove, arrows: arrows, interactive: false)
    }

    public mutating func goTo(_ p: Int) { ply = max(0, min(game.plyCount, p)) }
    public mutating func forward() { goTo(ply + 1) }
    public mutating func back() { goTo(ply - 1) }
    public mutating func toStart() { goTo(0) }
    public mutating func toEnd() { goTo(game.plyCount) }
}
