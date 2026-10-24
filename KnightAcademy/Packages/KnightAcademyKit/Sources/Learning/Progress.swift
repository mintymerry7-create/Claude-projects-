import Foundation
import ChessCore
import OpeningDatabase

/// Derived statistics for dashboards. Pure functions of `UserData`.
public enum ProgressStats {

    /// Consecutive days with at least one activity, counting back from today
    /// (a streak survives until the end of the day after the last activity).
    public static func streak(_ data: UserData, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(data.activity.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day), days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    public struct DayCount: Hashable, Sendable, Identifiable {
        public let date: Date
        public let count: Int
        public var id: Date { date }
    }

    /// Items practised per day for the last `days` days (oldest first).
    public static func weekly(_ data: UserData, days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> [DayCount] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset -> DayCount? in
            guard let d = calendar.date(byAdding: .day, value: -offset, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: d) else { return nil }
            let n = data.activity.filter { $0.date >= d && $0.date < next }.reduce(0) { $0 + $1.count }
            return DayCount(date: d, count: n)
        }
    }

    public static func practisedToday(_ data: UserData, now: Date = Date(), calendar: Calendar = .current) -> Int {
        weekly(data, days: 1, now: now, calendar: calendar).first?.count ?? 0
    }

    /// Weighted mastery of a set of cards: mastered 1, reviewing 0.75, learning 0.35, new 0.
    public static func mastery(cardIDs: [String], in data: UserData) -> Double {
        guard !cardIDs.isEmpty else { return 0 }
        let total = cardIDs.reduce(0.0) { acc, id in
            switch data.reviews[id]?.status ?? .new {
            case .mastered: return acc + 1
            case .reviewing: return acc + 0.75
            case .learning: return acc + 0.35
            case .new: return acc
            }
        }
        return total / Double(cardIDs.count)
    }

    public struct StatusCounts: Hashable, Sendable {
        public var new = 0, learning = 0, reviewing = 0, mastered = 0
        public var total: Int { new + learning + reviewing + mastered }
    }

    public static func statusCounts(cardIDs: [String], in data: UserData) -> StatusCounts {
        var c = StatusCounts()
        for id in cardIDs {
            switch data.reviews[id]?.status ?? .new {
            case .new: c.new += 1
            case .learning: c.learning += 1
            case .reviewing: c.reviewing += 1
            case .mastered: c.mastered += 1
            }
        }
        return c
    }

    /// Overall mastery across all started courses.
    public static func overallMastery(_ data: UserData, db: OpeningDatabase) -> Double {
        let ids = data.courses.values.flatMap { course -> [String] in
            guard let o = db.opening(id: course.openingID) else { return [] }
            return StudyPlanBuilder.build(opening: o, settings: course.settings, side: course.side).cards.map(\.id)
        }
        return mastery(cardIDs: ids, in: data)
    }

    /// Puzzle accuracy per theme (only themes with attempts).
    public static func puzzleAccuracyByTheme(_ data: UserData) -> [String: (solved: Int, attempted: Int)] {
        var out: [String: (Int, Int)] = [:]
        for r in data.puzzles.values where r.attempts > 0 {
            for t in r.themes {
                let cur = out[t] ?? (0, 0)
                out[t] = (cur.0 + (r.solvedFirstTry ? 1 : 0), cur.1 + 1)
            }
        }
        return out.mapValues { (solved: $0.0, attempted: $0.1) }
    }

    /// Learning status of an opening for explorer filters.
    public static func learningStatus(of opening: Opening, in data: UserData) -> CardStatus {
        guard let course = data.courses[opening.id] else { return .new }
        let ids = StudyPlanBuilder.build(opening: opening, settings: course.settings, side: course.side).cards.map(\.id)
        let m = mastery(cardIDs: ids, in: data)
        if m >= 0.95 { return .mastered }
        if m >= 0.5 { return .reviewing }
        return .learning
    }
}

public struct Recommendation: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        case opening(String)
        case lesson(String)
        case reviews
        case puzzles(theme: String?)
    }
    public let target: Target
    public let title: String
    public let reason: String
}

/// Simple, explainable recommendations. No hidden scoring — each rule says why.
public enum Recommender {

    public static func openings(for data: UserData, db: OpeningDatabase, limit: Int = 3) -> [Recommendation] {
        let level = data.settings.level
        let started = Set(data.courses.keys)
        let repertoireOpenings = Set(data.repertoires.flatMap(\.openingIDs))
        let known = started.union(repertoireOpenings)
        let knownOpenings = known.compactMap { db.opening(id: $0) }
        let hasWhite = knownOpenings.contains { $0.side == .white }
        let firstMove: (Opening) -> String = { $0.mainLine.moves.first ?? "" }
        let blackVsE4 = knownOpenings.contains { $0.side == .black && firstMove($0) == "e4" }
        let blackVsD4 = knownOpenings.contains { $0.side == .black && firstMove($0) == "d4" }

        let candidates = db.openings.filter { !known.contains($0.id) && $0.difficulty <= level }
        var out: [Recommendation] = []
        func pick(_ filter: (Opening) -> Bool, reason: String) {
            guard out.count < limit,
                  let o = candidates.first(where: { o in filter(o) && !out.contains { $0.target == .opening(o.id) } })
            else { return }
            out.append(Recommendation(target: .opening(o.id), title: o.name, reason: reason))
        }
        if !hasWhite {
            pick({ $0.side == .white && $0.difficulty == .beginner }, reason: "You don't have a White opening yet — start with a principled, beginner-friendly one.")
        }
        if !blackVsE4 {
            pick({ $0.side == .black && firstMove($0) == "e4" }, reason: "You need an answer to 1.e4 as Black.")
        }
        if !blackVsD4 {
            pick({ $0.side == .black && firstMove($0) == "d4" }, reason: "You need an answer to 1.d4 as Black.")
        }
        // Deepen families the user already plays.
        for o in knownOpenings {
            pick({ $0.family == o.family && $0.difficulty <= level }, reason: "Builds on \(o.name), which you already study.")
        }
        pick({ _ in true }, reason: "Matches your level (\(level.displayName)).")
        return out
    }

    /// Lessons first targeting weak puzzle themes, otherwise the next unfinished lesson.
    public static func nextLesson(for data: UserData, curriculum: Curriculum) -> Recommendation? {
        let accuracy = ProgressStats.puzzleAccuracyByTheme(data)
        let weak = accuracy.filter { $0.value.attempted >= 3 && Double($0.value.solved) / Double($0.value.attempted) < 0.6 }
            .sorted { Double($0.value.solved) / Double($0.value.attempted) < Double($1.value.solved) / Double($1.value.attempted) }
        for (theme, stats) in weak {
            if let lesson = curriculum.allLessons.first(where: { $0.themes.contains(theme) && !(data.lessons[$0.id]?.completed ?? false) })
                ?? curriculum.allLessons.first(where: { $0.themes.contains(theme) }) {
                let pct = Int(Double(stats.solved) / Double(stats.attempted) * 100)
                return Recommendation(target: .lesson(lesson.id), title: lesson.title,
                                      reason: "You solve \(pct)% of \(Puzzle.displayName(forTheme: theme).lowercased()) puzzles on the first try.")
            }
        }
        let level = data.settings.level
        if let next = curriculum.allLessons.first(where: { !(data.lessons[$0.id]?.completed ?? false) && $0.difficulty <= level })
            ?? curriculum.allLessons.first(where: { !(data.lessons[$0.id]?.completed ?? false) }) {
            return Recommendation(target: .lesson(next.id), title: next.title, reason: "Next in the fundamentals course.")
        }
        return nil
    }

    /// The single most useful next step for the Home screen.
    public static func nextStep(for data: UserData, db: OpeningDatabase, curriculum: Curriculum, now: Date = Date()) -> Recommendation {
        let due = data.dueReviews(at: now).count
        if due > 0 {
            return Recommendation(target: .reviews, title: "Review \(due) move\(due == 1 ? "" : "s")",
                                  reason: "Reviews are due — spaced repetition works best on time.")
        }
        if let course = data.courses.values.sorted(by: { $0.lastStudiedAt > $1.lastStudiedAt }).first,
           let o = db.opening(id: course.openingID) {
            let plan = StudyPlanBuilder.build(opening: o, settings: course.settings, side: course.side)
            let counts = ProgressStats.statusCounts(cardIDs: plan.cards.map(\.id), in: data)
            if counts.new > 0 {
                return Recommendation(target: .opening(o.id), title: "Continue \(o.name)",
                                      reason: "\(counts.new) new move\(counts.new == 1 ? "" : "s") left at your chosen depth.")
            }
        }
        if let lesson = nextLesson(for: data, curriculum: curriculum) { return lesson }
        if let o = openings(for: data, db: db, limit: 1).first { return o }
        return Recommendation(target: .puzzles(theme: nil), title: "Solve puzzles", reason: "Keep your tactics sharp.")
    }

    /// Picks puzzles near the user's success rate: harder after successes, easier after failures.
    public static func nextPuzzle(from puzzles: [Puzzle], data: UserData, theme: String? = nil) -> Puzzle? {
        let pool = puzzles.filter { theme == nil || $0.themes.contains(theme!) }
        let unsolved = pool.filter { !(data.puzzles[$0.id]?.solved ?? false) }
        let recent = data.puzzles.values.filter { $0.lastAttempt != nil }
            .sorted { ($0.lastAttempt ?? .distantPast) > ($1.lastAttempt ?? .distantPast) }
            .prefix(10)
        let rate = recent.isEmpty ? 0.5 : Double(recent.filter(\.solvedFirstTry).count) / Double(recent.count)
        let target = rate > 0.75 ? 4 : rate > 0.5 ? 3 : rate > 0.3 ? 2 : 1
        let candidates = unsolved.isEmpty ? pool : unsolved
        return candidates.min { abs($0.level - target) < abs($1.level - target) }
    }

    /// Deterministic puzzle of the day.
    public static func dailyPuzzle(from puzzles: [Puzzle], now: Date = Date(), calendar: Calendar = .current) -> Puzzle? {
        guard !puzzles.isEmpty else { return nil }
        let day = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        let sorted = puzzles.sorted { $0.id < $1.id }
        return sorted[(day * 7919) % sorted.count]
    }
}
