import SwiftUI
import ChessCore
import Learning
import AppFeatures

// MARK: - Reviews

struct ReviewScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var session: ReviewSession?

    var body: some View {
        Group {
            if let session {
                ReviewSessionView(session: session)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task { if session == nil { session = model.makeReviewSession() } }
    }
}

struct ReviewSessionView: View {
    let session: ReviewSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                if let card = session.current, let display = session.display {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.context ?? "Opening review").font(.headline)
                            Text("\(display.position.sideToMove.displayName) to move · \(session.remaining) left")
                                .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                        }
                        Spacer()
                        Tag(text: card.status.displayName, tint: card.status.tint)
                    }
                    ChessBoardView(display: display) { move in
                        let fb = session.submit(move)
                        if case .correct = fb { Feedback.success() } else if case .incorrect = fb { Feedback.error() }
                    }
                    feedback
                    HStack(spacing: KA.Spacing.s) {
                        Button("Hint") { session.hint() }
                            .buttonStyle(.secondary)
                            .disabled(isAnswered)
                        Button("Next") { session.next() }
                            .buttonStyle(.primary)
                            .disabled(!isAnswered)
                    }
                } else {
                    summary
                }
            }
            .padding(KA.Spacing.l)
        }
        .screenBackground()
    }

    private var isAnswered: Bool {
        switch session.feedback {
        case .correct, .revealed: return true
        default: return false
        }
    }

    @ViewBuilder private var feedback: some View {
        switch session.feedback {
        case .waiting:
            Text("Play the move you prepared for this position.").font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
        case let .correct(san, grade):
            FeedbackBanner(kind: .success, text: "\(san) — correct (\(grade.displayName.lowercased())).")
        case let .incorrect(san, hint):
            FeedbackBanner(kind: .error, text: "\(san) is not it. \(hint)")
        case .alsoKnown(let san):
            FeedbackBanner(kind: .info, text: "\(san) is also in your repertoire, but this card asks for a different move.")
        case .revealed(let san):
            FeedbackBanner(kind: .warning, text: "The move was \(san). It will come back soon.")
        }
    }

    private var summary: some View {
        VStack(spacing: KA.Spacing.m) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(KA.Palette.accent)
            Text(session.results.isEmpty ? "Nothing to review right now" : "Review complete").font(.title2.bold())
            if !session.results.isEmpty {
                Text("\(session.results.filter(\.isCorrect).count) of \(session.results.count) correct · \(Int(session.accuracy * 100))%")
                    .foregroundStyle(KA.Palette.textSecondary)
            }
            Button("Done") { dismiss() }.buttonStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .onAppear { if !session.results.isEmpty { Feedback.success() } }
    }
}

// MARK: - Puzzles

struct PuzzleScreen: View {
    let theme: String?
    let initialPuzzleID: String?
    @Environment(AppModel.self) private var model
    @State private var session: PuzzleSession?
    @State private var replyTask: Task<Void, Never>?
    @State private var solvedCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                if let session {
                    header(session)
                    ChessBoardView(display: session.display) { move in
                        submit(move, session)
                    }
                    status(session)
                    controls(session)
                } else {
                    ContentUnavailableView("No puzzles found", systemImage: "puzzlepiece",
                                           description: Text("Try another theme."))
                }
            }
            .padding(KA.Spacing.l)
        }
        .screenBackground()
        .navigationTitle(theme.map(Puzzle.displayName(forTheme:)) ?? "Puzzles")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard session == nil else { return }
            if let id = initialPuzzleID, let p = model.puzzles.first(where: { $0.id == id }) {
                session = model.makePuzzleSession(p)
            } else {
                loadNext()
            }
        }
        .onDisappear { replyTask?.cancel() }
    }

    private func header(_ s: PuzzleSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(s.learnerColor.displayName) to move").font(.headline)
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        Image(systemName: i < s.puzzle.level ? "star.fill" : "star")
                            .font(.caption2).foregroundStyle(KA.Palette.gold)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Difficulty \(s.puzzle.level) of 5")
            }
            Spacer()
            if solvedCount > 0 {
                Text("\(solvedCount) solved this session").font(.caption).foregroundStyle(KA.Palette.textSecondary)
            }
        }
    }

    @ViewBuilder private func status(_ s: PuzzleSession) -> some View {
        switch s.state {
        case .solving:
            Text(s.step == 0 ? "Find the best move." : "Keep going — find the next move.")
                .font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
        case .wrong(let san):
            FeedbackBanner(kind: .error, text: "\(san) doesn't work. Try again.")
        case .solved(let firstTry):
            FeedbackBanner(kind: .success, text: firstTry ? "Solved on the first try!" : "Solved!")
            explanation(s)
        case .failed:
            FeedbackBanner(kind: .warning, text: "Here is the solution.")
            explanation(s)
        }
    }

    private func explanation(_ s: PuzzleSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(s.puzzle.themes.filter { $0 != "mate" }, id: \.self) { Tag(text: Puzzle.displayName(forTheme: $0)) }
            }
            Text(s.puzzle.explanation).font(.subheadline)
            let sans = sanSolution(s.puzzle)
            Text("Solution: " + Notation.movetext(sans: sans, startPosition: s.puzzle.position))
                .font(.caption.monospaced()).foregroundStyle(KA.Palette.textSecondary)
        }
        .card()
    }

    private func controls(_ s: PuzzleSession) -> some View {
        HStack(spacing: KA.Spacing.s) {
            switch s.state {
            case .solved, .failed:
                Button("Next puzzle") { loadNext() }.buttonStyle(.primary)
            case .wrong:
                Button("Retry") { s.retry() }.buttonStyle(.secondary)
                Button("Solution") { s.revealSolution() }.buttonStyle(.secondary)
            case .solving:
                Button("Hint") { s.hint() }.buttonStyle(.secondary).disabled(!s.isLearnerTurn)
                Button("Solution") { s.revealSolution() }.buttonStyle(.secondary)
            }
        }
    }

    private func submit(_ move: Move, _ s: PuzzleSession) {
        let state = s.submit(move)
        switch state {
        case .wrong: Feedback.error()
        case .solved:
            Feedback.success()
            solvedCount += 1
        case .solving:
            if s.needsReply {
                replyTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if s.playReply() != nil { Feedback.move() }
                }
            }
        case .failed: break
        }
    }

    private func loadNext() {
        replyTask?.cancel()
        if let p = model.nextPuzzle(theme: theme) ?? model.puzzles.randomElement() {
            session = model.makePuzzleSession(p)
        }
    }

    private func sanSolution(_ p: Puzzle) -> [String] {
        var pos = p.position
        var out: [String] = []
        for m in p.solutionMoves where pos.isLegal(m) {
            out.append(pos.san(for: m))
            pos.make(m)
        }
        return out
    }
}

// MARK: - Lessons

struct LessonScreen: View {
    let lessonID: String
    @Environment(AppModel.self) private var model
    @State private var session: LessonSession?

    var body: some View {
        Group {
            if let session {
                LessonView(session: session)
            } else if model.curriculum.lesson(id: lessonID) == nil {
                ContentUnavailableView("Lesson not found", systemImage: "graduationcap")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model.curriculum.lesson(id: lessonID)?.title ?? "Lesson")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if session == nil, let lesson = model.curriculum.lesson(id: lessonID) {
                session = model.makeLessonSession(lesson)
            }
        }
    }
}

struct LessonView: View {
    let session: LessonSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                ProgressView(value: session.feedback == .finished ? 1 : session.progress).tint(KA.Palette.accent)
                if session.feedback == .finished {
                    finished
                } else if let step = session.step {
                    Text(step.text).font(.body).fixedSize(horizontal: false, vertical: true)
                    ChessBoardView(display: session.display) { move in
                        let fb = session.submit(move)
                        if case .correct = fb { Feedback.success() } else if case .wrong = fb { Feedback.error() }
                    }
                    feedback(step)
                    HStack(spacing: KA.Spacing.s) {
                        Button("Back") { session.previous() }
                            .buttonStyle(.secondary)
                            .disabled(session.stepIndex == 0)
                        if step.isTask && session.feedback != .reading && !isStepDone {
                            Button("Hint") { session.requestHint() }.buttonStyle(.secondary)
                        }
                        Button(session.isLastStep ? "Finish" : "Continue") { session.next() }
                            .buttonStyle(.primary)
                            .disabled(step.isTask && !isStepDone)
                    }
                }
            }
            .padding(KA.Spacing.l)
        }
        .screenBackground()
    }

    private var isStepDone: Bool {
        if case .correct = session.feedback { return true }
        return false
    }

    @ViewBuilder private func feedback(_ step: LessonStep) -> some View {
        switch session.feedback {
        case .awaitingMove:
            if session.showHint, let hint = step.hint {
                FeedbackBanner(kind: .info, text: hint)
            } else {
                Text("Your move.").font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
            }
        case .wrong(let san):
            VStack(alignment: .leading, spacing: 8) {
                FeedbackBanner(kind: .error, text: "\(san) is not the answer. Try again.")
                Button("Try again") { session.retry() }.buttonStyle(.secondary)
            }
        case .correct(let message):
            FeedbackBanner(kind: .success, text: message)
        case .reading, .finished:
            EmptyView()
        }
    }

    private var finished: some View {
        VStack(spacing: KA.Spacing.m) {
            Image(systemName: "graduationcap.fill").font(.system(size: 54)).foregroundStyle(KA.Palette.accent)
            Text("Lesson complete").font(.title2.bold())
            Text(session.lesson.title).foregroundStyle(KA.Palette.textSecondary)
            Button("Done") { dismiss() }.buttonStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .onAppear { Feedback.success() }
    }
}
