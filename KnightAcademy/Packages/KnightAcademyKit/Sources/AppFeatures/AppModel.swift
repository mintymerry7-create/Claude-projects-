import Foundation
import Observation
import ChessCore
import ChessEngine
import OpeningDatabase
import Learning

/// Supplies chess engines. The iOS app provides Stockfish (via
/// ChessKitEngine) when its network files are installed; otherwise the
/// built-in engine is used so bot games always work offline.
public protocol EngineProvider: AnyObject {
    var engineName: String { get }
    var isStockfishAvailable: Bool { get }
    /// An engine for a bot opponent (one per game).
    func makeEngine() -> ChessEngine
}

public final class BuiltInEngineProvider: EngineProvider {
    public init() {}
    public var engineName: String { "Knight (built-in)" }
    public var isStockfishAvailable: Bool { false }
    public func makeEngine() -> ChessEngine { BuiltInEngine() }
}

public struct CourseSummary: Identifiable, Hashable {
    public let opening: Opening
    public let progress: CourseProgress
    public let mastery: Double
    public let counts: ProgressStats.StatusCounts
    public let dueCount: Int
    public var id: String { opening.id }
}

/// The app's single source of truth: persisted user data plus the bundled
/// content, with actions that keep everything saved.
@MainActor
@Observable
public final class AppModel {
    public let db: OpeningDatabase
    public let curriculum: Curriculum
    public let puzzles: [Puzzle]
    @ObservationIgnored public let store: UserDataStore
    @ObservationIgnored public let engines: EngineProvider
    public private(set) var data: UserData
    /// Bumped on every change so views depending on derived values refresh.
    public private(set) var revision = 0

    public init(store: UserDataStore, db: OpeningDatabase = .shared, curriculum: Curriculum = .shared,
                puzzles: [Puzzle] = PuzzleLibrary.shared, engines: EngineProvider = BuiltInEngineProvider()) {
        self.store = store
        self.db = db
        self.curriculum = curriculum
        self.puzzles = puzzles
        self.engines = engines
        data = store.data
    }

    public func update(_ body: (inout UserData) -> Void) {
        store.update(body)
        data = store.data
        revision += 1
    }

    public var settings: AppSettings { data.settings }

    public func updateSettings(_ body: (inout AppSettings) -> Void) {
        update { body(&$0.settings) }
    }

    // MARK: Dashboard

    public func greeting(now: Date = Date(), calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: now)
        let part = hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = data.settings.playerName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? part : "\(part), \(name)"
    }

    public func dueReviews(now: Date = Date()) -> [ReviewState] { data.dueReviews(at: now) }
    public var streak: Int { ProgressStats.streak(data) }
    public var weekly: [ProgressStats.DayCount] { ProgressStats.weekly(data) }
    public var practisedToday: Int { ProgressStats.practisedToday(data) }
    public var recentActivity: [ActivityEvent] { Array(data.activity.suffix(8).reversed()) }
    public var recentGames: [SavedGame] { Array(data.games.sorted { $0.date > $1.date }.prefix(5)) }

    public var courses: [CourseSummary] {
        data.courses.values.sorted { $0.lastStudiedAt > $1.lastStudiedAt }.compactMap { course in
            guard let o = db.opening(id: course.openingID) else { return nil }
            let ids = plan(for: o.id)?.cards.map(\.id) ?? []
            let due = Set(dueReviews().map(\.id))
            return CourseSummary(opening: o, progress: course,
                                 mastery: ProgressStats.mastery(cardIDs: ids, in: data),
                                 counts: ProgressStats.statusCounts(cardIDs: ids, in: data),
                                 dueCount: ids.filter(due.contains).count)
        }
    }

    public var overallMastery: Double { ProgressStats.overallMastery(data, db: db) }
    public var nextStep: Recommendation { Recommender.nextStep(for: data, db: db, curriculum: curriculum) }
    public var recommendedOpenings: [Recommendation] { Recommender.openings(for: data, db: db) }
    public var recommendedLesson: Recommendation? { Recommender.nextLesson(for: data, curriculum: curriculum) }
    public var dailyPuzzle: Puzzle? { Recommender.dailyPuzzle(from: puzzles) }

    // MARK: Activity

    /// Logs activity, merging with the previous event of the same kind and
    /// title within 30 minutes so a session counts as one entry.
    public func logActivity(_ kind: ActivityKind, title: String, detail: String = "", count: Int = 1, now: Date = Date()) {
        update { d in
            if let last = d.activity.last, last.kind == kind, last.title == title,
               now.timeIntervalSince(last.date) < 30 * 60 {
                d.activity[d.activity.count - 1].count += count
                d.activity[d.activity.count - 1].date = now
                if !detail.isEmpty { d.activity[d.activity.count - 1].detail = detail }
            } else {
                d.log(ActivityEvent(kind: kind, title: title, detail: detail, count: count, date: now))
            }
        }
    }

    // MARK: Opening courses

    public func course(for openingID: String) -> CourseProgress? { data.courses[openingID] }

    public func startCourse(_ opening: Opening, settings: DepthSettings, side: PieceColor? = nil) {
        update { d in
            if var existing = d.courses[opening.id] {
                existing.settings = settings
                existing.side = side ?? existing.side
                existing.lastStudiedAt = Date()
                d.courses[opening.id] = existing
            } else {
                d.courses[opening.id] = CourseProgress(openingID: opening.id, settings: settings, side: side ?? opening.side)
            }
        }
    }

    /// Changing depth never deletes progress: cards are keyed by position and move.
    public func updateCourse(_ openingID: String, settings: DepthSettings? = nil, side: PieceColor? = nil) {
        update { d in
            guard var c = d.courses[openingID] else { return }
            if let s = settings { c.settings = s }
            if let side { c.side = side }
            d.courses[openingID] = c
        }
    }

    public func removeCourse(_ openingID: String) {
        update { $0.courses[openingID] = nil }
    }

    public func plan(for openingID: String, side: PieceColor? = nil) -> StudyPlan? {
        guard let o = db.opening(id: openingID) else { return nil }
        let course = data.courses[openingID]
        return StudyPlanBuilder.build(opening: o, settings: course?.settings ?? .beginner, side: side ?? course?.side ?? o.side)
    }

    public func makeTrainer(openingID: String, mode: TrainerMode, side: PieceColor? = nil,
                            startNodeID: Int = MoveTree.rootID) -> OpeningTrainer? {
        guard let opening = db.opening(id: openingID), let plan = plan(for: openingID, side: side) else { return nil }
        if data.courses[openingID] == nil {
            startCourse(opening, settings: .beginner, side: side)
        }
        let due = Set(dueReviews().map(\.id))
        let unseen = Set(plan.cards.map(\.id).filter { data.reviews[$0] == nil })
        let trainer = OpeningTrainer(plan: plan, mode: mode, startNodeID: startNodeID,
                                     prioritise: mode == .memory ? due.union(unseen) : [])
        trainer.onGrade = { [weak self] card, grade, position in
            guard let self else { return }
            self.update { d in
                d.recordReview(cardID: card.id, grade: grade, openingID: opening.id, san: card.san,
                               fen: position.fen, context: opening.name)
            }
            self.logActivity(.openingStudy, title: opening.name, detail: "Practised from memory")
        }
        trainer.onProgress = { [weak self] sans in
            guard let self else { return }
            self.update { d in
                d.courses[opening.id]?.resumePath = sans
                d.courses[opening.id]?.lastStudiedAt = Date()
                d.courses[opening.id]?.lastMode = mode.rawValue
                d.setResume(ResumePoint(kind: .opening, targetID: opening.id, title: opening.name,
                                        subtitle: "\(mode.displayName) · move \(max(1, (sans.count + 1) / 2))"))
            }
        }
        if mode == .learn {
            logActivity(.openingStudy, title: opening.name, detail: "Learn mode", count: 0)
        }
        return trainer
    }

    /// Reviews (in learn mode) introduce cards without grading; mark them as
    /// seen so they enter the review cycle after a first memory pass.
    public func makeReviewSession(limit: Int = 30) -> ReviewSession {
        let due = Array(dueReviews().prefix(limit))
        let session = ReviewSession(cards: due, allReviews: Array(data.reviews.values))
        session.onGrade = { [weak self] card, grade in
            guard let self else { return }
            self.update { d in
                d.recordReview(cardID: card.id, grade: grade, openingID: card.openingID, san: card.san)
            }
            self.logActivity(.review, title: "Daily review")
        }
        return session
    }

    // MARK: Puzzles

    public func makePuzzleSession(_ puzzle: Puzzle) -> PuzzleSession {
        let s = PuzzleSession(puzzle: puzzle)
        s.onFinish = { [weak self] p, solved, firstTry, usedHint in
            guard let self else { return }
            self.update { d in
                var r = d.puzzles[p.id] ?? PuzzleRecord(puzzleID: p.id, themes: p.themes)
                r.attempts += 1
                if solved { r.solved = true }
                if r.attempts == 1 { r.solvedFirstTry = firstTry }
                r.usedHint = r.usedHint || usedHint
                r.lastAttempt = Date()
                d.puzzles[p.id] = r
                d.setResume(ResumePoint(kind: .puzzle, targetID: p.id, title: "Tactics practice",
                                        subtitle: Puzzle.displayName(forTheme: p.primaryTheme)))
            }
            self.logActivity(.puzzle, title: "Puzzles", detail: solved ? "Solved" : "Missed")
        }
        return s
    }

    public func nextPuzzle(theme: String? = nil) -> Puzzle? {
        Recommender.nextPuzzle(from: puzzles, data: data, theme: theme)
    }

    public var puzzleStats: (solved: Int, attempted: Int, firstTry: Int) {
        let records = data.puzzles.values.filter { $0.attempts > 0 }
        return (records.filter(\.solved).count, records.count, records.filter(\.solvedFirstTry).count)
    }

    // MARK: Lessons

    public func makeLessonSession(_ lesson: Lesson) -> LessonSession {
        let record = data.lessons[lesson.id]
        let start = (record?.completed ?? false) ? 0 : (record?.completedSteps ?? 0)
        let s = LessonSession(lesson: lesson, startStep: min(start, max(0, lesson.steps.count - 1)))
        s.onStepCompleted = { [weak self] index in
            guard let self else { return }
            self.update { d in
                var r = d.lessons[lesson.id] ?? LessonRecord(lessonID: lesson.id)
                r.completedSteps = max(r.completedSteps, index + 1)
                r.lastStudied = Date()
                d.lessons[lesson.id] = r
                d.setResume(ResumePoint(kind: .lesson, targetID: lesson.id, title: lesson.title,
                                        subtitle: "Step \(min(index + 2, lesson.steps.count)) of \(lesson.steps.count)"))
            }
            self.logActivity(.lesson, title: lesson.title)
        }
        s.onFinished = { [weak self] mistakes in
            guard let self else { return }
            self.update { d in
                var r = d.lessons[lesson.id] ?? LessonRecord(lessonID: lesson.id)
                r.completed = true
                r.completedSteps = lesson.steps.count
                r.mistakes = mistakes
                r.lastStudied = Date()
                d.lessons[lesson.id] = r
            }
        }
        return s
    }

    public func lessonProgress(_ lesson: Lesson) -> Double {
        guard let r = data.lessons[lesson.id], !lesson.steps.isEmpty else { return 0 }
        return r.completed ? 1 : Double(r.completedSteps) / Double(lesson.steps.count)
    }

    // MARK: Games

    public func save(game: SavedGame) {
        update { $0.games.append(game) }
        logActivity(.game, title: "Bot game", detail: "\(game.opponent) · \(game.result)")
    }

    public func attach(analysis: GameAnalysis, to gameID: UUID) {
        update { d in
            if let i = d.games.firstIndex(where: { $0.id == gameID }) { d.games[i].analysis = analysis }
        }
    }

    public func deleteGame(_ id: UUID) {
        update { $0.games.removeAll { $0.id == id } }
    }

    public var gameRecord: (wins: Int, draws: Int, losses: Int) {
        let scores = data.games.compactMap(\.playerScore)
        return (scores.filter { $0 == 1 }.count, scores.filter { $0 == 0.5 }.count, scores.filter { $0 == 0 }.count)
    }

    // MARK: Repertoires

    @discardableResult
    public func createRepertoire(name: String, color: PieceColor, fen: String? = nil) throws -> Repertoire {
        let r = try fen.map { try Repertoire.fromFEN($0, name: name, color: color) } ?? Repertoire(name: name, color: color)
        update { $0.repertoires.append(r) }
        return r
    }

    public func save(repertoire: Repertoire) {
        update { d in
            if let i = d.repertoires.firstIndex(where: { $0.id == repertoire.id }) {
                d.repertoires[i] = repertoire
            } else {
                d.repertoires.append(repertoire)
            }
        }
        logActivity(.repertoire, title: repertoire.name, detail: "Edited", count: 0)
    }

    public func deleteRepertoire(_ id: UUID) {
        update { $0.repertoires.removeAll { $0.id == id } }
    }

    public func makeRepertoireEditor(_ id: UUID) -> RepertoireEditor? {
        guard let r = data.repertoires.first(where: { $0.id == id }) else { return nil }
        let editor = RepertoireEditor(repertoire: r)
        editor.onChange = { [weak self] rep in self?.save(repertoire: rep) }
        return editor
    }

    /// Repertoire drill: the repertoire becomes a study plan whose lines are its tree lines.
    public func repertoirePlan(_ id: UUID) -> StudyPlan? {
        guard let r = data.repertoires.first(where: { $0.id == id }), r.isFromStandardStart else { return nil }
        let lines = r.tree.allLines.enumerated().map { i, path in
            OpeningLine(id: "\(r.id.uuidString)-\(i)", name: "Line \(i + 1)", kind: i == 0 ? .main : .key,
                        moves: path.map { r.tree[$0].san })
        }
        guard !lines.isEmpty else { return nil }
        let opening = Opening(id: "repertoire-\(r.id.uuidString)", name: r.name, aliases: [], eco: "", family: "Repertoire",
                              group: "Repertoire", side: r.color, difficulty: .intermediate, summary: "", ideas: [], tactics: [],
                              whitePlans: [], blackPlans: [], mistakes: [], keyPositions: [], canonicalName: r.name,
                              canonicalPly: 0, fen: Position.startFEN, lines: lines, source: "Personal repertoire")
        let settings = DepthSettings(preset: .custom, maxPly: 60, maxVariations: 60, includeRareSidelines: true,
                                     prioritizeTraps: false, includeEngineAnalysis: false)
        return StudyPlanBuilder.build(opening: opening, settings: settings, side: r.color)
    }

    public func makeRepertoireTrainer(_ id: UUID, mode: TrainerMode) -> OpeningTrainer? {
        guard let plan = repertoirePlan(id), let r = data.repertoires.first(where: { $0.id == id }) else { return nil }
        let due = Set(dueReviews().map(\.id))
        let trainer = OpeningTrainer(plan: plan, mode: mode, prioritise: due)
        trainer.onGrade = { [weak self] card, grade, position in
            guard let self else { return }
            self.update { d in
                d.recordReview(cardID: card.id, grade: grade, openingID: nil, san: card.san, fen: position.fen, context: r.name)
            }
            self.logActivity(.repertoire, title: r.name, detail: "Drill")
        }
        return trainer
    }

    // MARK: Bookmarks & notes

    public func addBookmark(title: String, openingID: String?, repertoireID: UUID? = nil, sans: [String]) {
        update { $0.bookmarks.append(Bookmark(title: title, openingID: openingID, repertoireID: repertoireID, sans: sans)) }
    }

    public func removeBookmark(_ id: UUID) {
        update { $0.bookmarks.removeAll { $0.id == id } }
    }

    public func isBookmarked(openingID: String, sans: [String]) -> Bool {
        data.bookmarks.contains { $0.openingID == openingID && $0.sans == sans }
    }

    public func note(for position: Position) -> String { data.positionNotes[position.repetitionKey] ?? "" }

    public func setNote(_ text: String, for position: Position) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        update { $0.positionNotes[position.repetitionKey] = t.isEmpty ? nil : t }
    }

    public func completeOnboarding(name: String, level: Difficulty) {
        update { d in
            d.settings.playerName = name
            d.settings.level = level
            d.hasCompletedOnboarding = true
        }
    }
}
