import Foundation
import ChessCore
import ChessEngine
import OpeningDatabase

/// Progress of an opening course (one per opening).
public struct CourseProgress: Codable, Hashable, Sendable {
    public var openingID: String
    public var settings: DepthSettings
    public var side: PieceColor
    public var startedAt: Date
    public var lastStudiedAt: Date
    /// SAN path of the last position studied, to resume exactly there.
    public var resumePath: [String]
    public var lastMode: String?

    public init(openingID: String, settings: DepthSettings, side: PieceColor, now: Date = Date()) {
        self.openingID = openingID
        self.settings = settings
        self.side = side
        startedAt = now
        lastStudiedAt = now
        resumePath = []
    }
}

public struct Bookmark: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var openingID: String?
    public var repertoireID: UUID?
    public var sans: [String]
    public var createdAt: Date

    public init(title: String, openingID: String? = nil, repertoireID: UUID? = nil, sans: [String], now: Date = Date()) {
        id = UUID()
        self.title = title
        self.openingID = openingID
        self.repertoireID = repertoireID
        self.sans = sans
        createdAt = now
    }
}

public enum ActivityKind: String, Codable, Sendable {
    case openingStudy, review, lesson, puzzle, game, repertoire

    public var symbol: String {
        switch self {
        case .openingStudy: return "book"
        case .review: return "arrow.triangle.2.circlepath"
        case .lesson: return "graduationcap"
        case .puzzle: return "puzzlepiece"
        case .game: return "checkerboard.rectangle"
        case .repertoire: return "list.bullet.indent"
        }
    }
}

public struct ActivityEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var kind: ActivityKind
    public var title: String
    public var detail: String
    /// Items practised (moves, puzzles, steps…) for the weekly chart.
    public var count: Int

    public init(kind: ActivityKind, title: String, detail: String = "", count: Int = 1, date: Date = Date()) {
        id = UUID()
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
        self.count = count
    }
}

public struct PuzzleRecord: Codable, Hashable, Sendable {
    public var puzzleID: String
    public var attempts: Int = 0
    public var solved: Bool = false
    public var solvedFirstTry: Bool = false
    public var usedHint: Bool = false
    public var lastAttempt: Date?
    public var themes: [String] = []

    public init(puzzleID: String, themes: [String]) {
        self.puzzleID = puzzleID
        self.themes = themes
    }
}

public struct LessonRecord: Codable, Hashable, Sendable {
    public var lessonID: String
    public var completedSteps: Int = 0
    public var completed: Bool = false
    public var mistakes: Int = 0
    public var lastStudied: Date?

    public init(lessonID: String) { self.lessonID = lessonID }
}

public struct SavedGame: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var pgn: String
    public var opponent: String
    public var playerColor: PieceColor
    public var result: String
    public var reason: String
    public var openingName: String?
    public var analysis: GameAnalysis?

    public init(pgn: String, opponent: String, playerColor: PieceColor, result: String, reason: String,
                openingName: String?, date: Date = Date()) {
        id = UUID()
        self.date = date
        self.pgn = pgn
        self.opponent = opponent
        self.playerColor = playerColor
        self.result = result
        self.reason = reason
        self.openingName = openingName
    }

    /// Win/draw/loss from the player's perspective.
    public var playerScore: Double? {
        switch result {
        case "1/2-1/2": return 0.5
        case "1-0": return playerColor == .white ? 1 : 0
        case "0-1": return playerColor == .black ? 1 : 0
        default: return nil
        }
    }
}

/// Where the user left off, shown as "Continue learning" on Home.
public struct ResumePoint: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case opening, lesson, repertoire, puzzle }
    public var kind: Kind
    public var targetID: String
    public var title: String
    public var subtitle: String
    public var updatedAt: Date

    public init(kind: Kind, targetID: String, title: String, subtitle: String, updatedAt: Date = Date()) {
        self.kind = kind
        self.targetID = targetID
        self.title = title
        self.subtitle = subtitle
        self.updatedAt = updatedAt
    }
}

public enum AppearanceSetting: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

public enum BoardTheme: String, Codable, CaseIterable, Sendable {
    case wood, forest, walnut, slate, classic

    public var displayName: String { rawValue.capitalized }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var playerName: String = ""
    public var level: Difficulty = .beginner
    public var appearance: AppearanceSetting = .dark
    public var boardTheme: BoardTheme = .wood
    public var showCoordinates: Bool = true
    public var showLegalMoves: Bool = true
    public var hapticsEnabled: Bool = true
    public var soundEnabled: Bool = true
    public var animateMoves: Bool = true
    public var dailyGoal: Int = 20
    public var preferStockfish: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        playerName = try c.decodeIfPresent(String.self, forKey: .playerName) ?? d.playerName
        level = try c.decodeIfPresent(Difficulty.self, forKey: .level) ?? d.level
        appearance = try c.decodeIfPresent(AppearanceSetting.self, forKey: .appearance) ?? d.appearance
        boardTheme = try c.decodeIfPresent(BoardTheme.self, forKey: .boardTheme) ?? d.boardTheme
        showCoordinates = try c.decodeIfPresent(Bool.self, forKey: .showCoordinates) ?? d.showCoordinates
        showLegalMoves = try c.decodeIfPresent(Bool.self, forKey: .showLegalMoves) ?? d.showLegalMoves
        hapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? d.hapticsEnabled
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? d.soundEnabled
        animateMoves = try c.decodeIfPresent(Bool.self, forKey: .animateMoves) ?? d.animateMoves
        dailyGoal = try c.decodeIfPresent(Int.self, forKey: .dailyGoal) ?? d.dailyGoal
        preferStockfish = try c.decodeIfPresent(Bool.self, forKey: .preferStockfish) ?? d.preferStockfish
    }
}

/// Everything the app persists. Missing keys decode to defaults so the
/// schema can grow without migrations.
public struct UserData: Codable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion: Int = UserData.currentSchema
    public var createdAt: Date = Date()
    public var settings = AppSettings()
    public var hasCompletedOnboarding = false
    public var reviews: [String: ReviewState] = [:]
    public var courses: [String: CourseProgress] = [:]
    public var bookmarks: [Bookmark] = []
    /// Personal notes keyed by position repetition key.
    public var positionNotes: [String: String] = [:]
    public var activity: [ActivityEvent] = []
    public var puzzles: [String: PuzzleRecord] = [:]
    public var lessons: [String: LessonRecord] = [:]
    public var games: [SavedGame] = []
    public var repertoires: [Repertoire] = []
    public var resume: ResumePoint?
    public var dailyPuzzleHistory: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? UserData.currentSchema
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        reviews = try c.decodeIfPresent([String: ReviewState].self, forKey: .reviews) ?? [:]
        courses = try c.decodeIfPresent([String: CourseProgress].self, forKey: .courses) ?? [:]
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        positionNotes = try c.decodeIfPresent([String: String].self, forKey: .positionNotes) ?? [:]
        activity = try c.decodeIfPresent([ActivityEvent].self, forKey: .activity) ?? []
        puzzles = try c.decodeIfPresent([String: PuzzleRecord].self, forKey: .puzzles) ?? [:]
        lessons = try c.decodeIfPresent([String: LessonRecord].self, forKey: .lessons) ?? [:]
        games = try c.decodeIfPresent([SavedGame].self, forKey: .games) ?? []
        repertoires = try c.decodeIfPresent([Repertoire].self, forKey: .repertoires) ?? []
        resume = try c.decodeIfPresent(ResumePoint.self, forKey: .resume)
        dailyPuzzleHistory = try c.decodeIfPresent([String: String].self, forKey: .dailyPuzzleHistory) ?? [:]
    }

    // MARK: Reviews

    /// Records an answer for a card and reschedules it.
    public mutating func recordReview(cardID: String, grade: RecallGrade, openingID: String?, san: String?,
                                      fen: String? = nil, context: String? = nil, now: Date = Date()) {
        let existing = reviews[cardID] ?? ReviewState(id: cardID, due: now, openingID: openingID, san: san, fen: fen, context: context)
        var updated = SM2.review(existing, grade: grade, now: now)
        if updated.openingID == nil { updated.openingID = openingID }
        if updated.san == nil { updated.san = san }
        if updated.fen == nil { updated.fen = fen }
        if updated.context == nil { updated.context = context }
        reviews[cardID] = updated
    }

    public func dueReviews(at now: Date = Date()) -> [ReviewState] {
        reviews.values.filter { $0.isDue(at: now) }.sorted { $0.due < $1.due }
    }

    public var frequentlyForgotten: [ReviewState] {
        reviews.values.filter { $0.lapses > 0 }.sorted { ($0.lapses, $1.accuracy) > ($1.lapses, $0.accuracy) }
    }

    // MARK: Activity

    public mutating func log(_ event: ActivityEvent) {
        activity.append(event)
        if activity.count > 2000 { activity.removeFirst(activity.count - 2000) }
    }

    public mutating func setResume(_ point: ResumePoint) { resume = point }
}
