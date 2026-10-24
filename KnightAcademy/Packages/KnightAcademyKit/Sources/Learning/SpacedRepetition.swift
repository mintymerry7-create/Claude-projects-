import Foundation

/// How well a card was recalled. Maps to SM-2 quality grades.
public enum RecallGrade: Int, Codable, CaseIterable, Sendable {
    /// Wrong answer or answer revealed.
    case again = 1
    /// Correct, but only after a hint or a retry.
    case hard = 3
    /// Correct on the first try.
    case good = 4
    /// Correct, instantly and confidently.
    case easy = 5

    public var displayName: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }

    public var isCorrect: Bool { self != .again }
}

public enum CardStatus: String, Codable, Sendable, CaseIterable {
    case new, learning, reviewing, mastered

    public var displayName: String {
        switch self {
        case .new: return "New"
        case .learning: return "Learning"
        case .reviewing: return "Reviewing"
        case .mastered: return "Mastered"
        }
    }
}

/// Spaced-repetition state of one card (one move in one position).
public struct ReviewState: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var easeFactor: Double = 2.5
    /// Current interval in days (0 = not yet scheduled).
    public var intervalDays: Int = 0
    /// Consecutive successful SM-2 repetitions.
    public var repetitions: Int = 0
    public var due: Date
    public var lastReviewed: Date?
    public var attempts: Int = 0
    public var correctCount: Int = 0
    public var consecutiveCorrect: Int = 0
    public var lapses: Int = 0
    /// Last recall grade (0...5) — used as the confidence indicator.
    public var lastGrade: Int?
    /// Context for "frequently forgotten" lists.
    public var openingID: String?
    public var san: String?
    /// Full FEN of the position before the move, to show the card on a board.
    public var fen: String?
    /// Human-readable context, e.g. the opening or repertoire name.
    public var context: String?

    public init(id: String, due: Date, openingID: String? = nil, san: String? = nil, fen: String? = nil, context: String? = nil) {
        self.id = id
        self.due = due
        self.openingID = openingID
        self.san = san
        self.fen = fen
        self.context = context
    }

    /// The expected move, encoded at the end of the card id.
    public var moveUCI: String? { id.split(separator: "|").last.map(String.init) }

    public var accuracy: Double { attempts == 0 ? 0 : Double(correctCount) / Double(attempts) }

    public var status: CardStatus {
        if attempts == 0 { return .new }
        if intervalDays >= SM2.masteredIntervalDays { return .mastered }
        if repetitions >= 2 { return .reviewing }
        return .learning
    }

    public func isDue(at now: Date) -> Bool { attempts > 0 && due <= now }

    /// Confidence 0...1 combining last grade and streak.
    public var confidence: Double {
        guard let g = lastGrade else { return 0 }
        let gradePart = Double(g) / 5
        let streakPart = min(1, Double(consecutiveCorrect) / 4)
        return (gradePart + streakPart) / 2
    }
}

/// SuperMemo-2 scheduling (Wozniak, 1990), the algorithm used by Anki's
/// classic scheduler:
///   EF' = EF + (0.1 − (5 − q)(0.08 + (5 − q)·0.02)), EF ≥ 1.3
///   q < 3  → repetitions = 0, interval = 1 day
///   q ≥ 3  → interval = 1, 6, then round(previous · EF)
/// A "hard" answer additionally caps growth at 1.2× the previous interval.
public enum SM2 {
    public static let masteredIntervalDays = 21

    public static func review(_ state: ReviewState, grade: RecallGrade, now: Date = Date(),
                              calendar: Calendar = .current) -> ReviewState {
        var s = state
        let q = Double(grade.rawValue)
        s.attempts += 1
        s.lastReviewed = now
        s.lastGrade = grade.rawValue

        if grade.isCorrect {
            s.correctCount += 1
            s.consecutiveCorrect += 1
            switch s.repetitions {
            case 0: s.intervalDays = 1
            case 1: s.intervalDays = 6
            default:
                var next = Double(s.intervalDays) * s.easeFactor
                if grade == .hard { next = min(next, Double(s.intervalDays) * 1.2) }
                s.intervalDays = max(s.intervalDays + 1, Int(next.rounded()))
            }
            s.repetitions += 1
        } else {
            s.consecutiveCorrect = 0
            if s.repetitions > 0 || s.attempts > 1 { s.lapses += 1 }
            s.repetitions = 0
            s.intervalDays = 1
        }
        s.easeFactor = max(1.3, s.easeFactor + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02)))

        // Failed cards come back within the same session (10 minutes);
        // successful ones on the scheduled day.
        if grade.isCorrect {
            s.due = calendar.date(byAdding: .day, value: s.intervalDays, to: calendar.startOfDay(for: now)) ?? now
        } else {
            s.due = now.addingTimeInterval(10 * 60)
        }
        return s
    }
}
