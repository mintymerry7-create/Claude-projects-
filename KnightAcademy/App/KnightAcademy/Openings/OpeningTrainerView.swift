import SwiftUI
import ChessCore
import ChessEngine
import OpeningDatabase
import Learning
import AppFeatures

/// Creates the trainer once and shows it.
struct TrainerScreen: View {
    let openingID: String
    let mode: TrainerMode
    let side: PieceColor?
    let startNode: Int
    @Environment(AppModel.self) private var model
    @State private var trainer: OpeningTrainer?

    var body: some View {
        Group {
            if let trainer {
                OpeningTrainerView(trainer: trainer, title: model.db.opening(id: openingID)?.name ?? "Opening", openingID: openingID)
            } else {
                ProgressView()
            }
        }
        .task {
            if trainer == nil {
                trainer = model.makeTrainer(openingID: openingID, mode: mode, side: side, startNodeID: startNode)
            }
        }
    }
}

struct RepertoireTrainerScreen: View {
    let repertoireID: UUID
    let mode: TrainerMode
    @Environment(AppModel.self) private var model
    @State private var trainer: OpeningTrainer?

    var body: some View {
        Group {
            if let trainer {
                OpeningTrainerView(trainer: trainer, title: trainer.plan.opening.name, openingID: nil)
            } else {
                ContentUnavailableView("Nothing to practise yet", systemImage: "list.bullet.indent",
                                       description: Text("Add moves to this repertoire first."))
            }
        }
        .task {
            if trainer == nil { trainer = model.makeRepertoireTrainer(repertoireID, mode: mode) }
        }
    }
}

/// Learn / play-from-memory screen for one study plan.
struct OpeningTrainerView: View {
    let trainer: OpeningTrainer
    let title: String
    let openingID: String?
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var showNotes = false
    @State private var opponentTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                lineHeader
                ChessBoardView(display: trainer.display) { move in
                    trainer.submit(move)
                    afterLearnerMove()
                }
                feedbackArea
                controls
                if trainer.plan.settings.includeEngineAnalysis && !trainer.isFinished {
                    EngineEvalView(position: trainer.position)
                }
                MoveListView(sans: trainer.plan.tree.sans(to: trainer.nodeID), startPosition: .start, current: nil)
            }
            .padding(KA.Spacing.l)
        }
        .screenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showNotes = true } label: { Label("Note on this position", systemImage: "note.text") }
                    if let openingID {
                        let sans = trainer.plan.tree.sans(to: trainer.nodeID)
                        Button {
                            model.addBookmark(title: "\(title) · \(sans.count) plies", openingID: openingID, sans: sans)
                            Feedback.success()
                        } label: { Label("Bookmark position", systemImage: "bookmark") }
                        Button { router.push(.explorer(openingID: openingID)) } label: {
                            Label("Variation explorer", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                    Button { trainer.restartLine() } label: { Label("Restart line", systemImage: "arrow.counterclockwise") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More options")
            }
        }
        .sheet(isPresented: $showNotes) {
            PositionNoteSheet(position: trainer.position)
        }
        .onAppear(perform: scheduleOpponentIfNeeded)
        .onDisappear { opponentTask?.cancel() }
    }

    // MARK: Header

    private var lineHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Tag(text: trainer.mode.displayName, tint: trainer.mode == .learn ? KA.Palette.info : KA.Palette.accent)
                if let line = trainer.currentLine {
                    Text(line.line.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if line.line.kind == .trap { Tag(text: "Trap", tint: KA.Palette.danger) }
                }
                Spacer()
                Text("Line \(min(trainer.completedLineIDs.count + 1, max(1, trainer.totalLines))) of \(max(1, trainer.totalLines))")
                    .font(.caption.monospacedDigit()).foregroundStyle(KA.Palette.textSecondary)
            }
            ProgressView(value: Double(trainer.completedLineIDs.count), total: Double(max(1, trainer.totalLines)))
                .tint(KA.Palette.accent)
        }
    }

    // MARK: Feedback

    @ViewBuilder private var feedbackArea: some View {
        switch trainer.feedback {
        case .idle:
            prompt
        case .correct(let san):
            FeedbackBanner(kind: .success, text: "\(san) — correct!")
            explanationText
        case .alternative(let san):
            FeedbackBanner(kind: .success, text: "\(san) is also part of your study plan — switching to that line.")
            explanationText
        case let .incorrect(san, hint):
            FeedbackBanner(kind: .error, text: "\(san) is not the move here. \(hint)")
        case .revealed(let san):
            FeedbackBanner(kind: .warning, text: "The move was \(san). It will come back soon for review.")
            explanationText
        case .lineComplete(let name):
            VStack(alignment: .leading, spacing: 10) {
                FeedbackBanner(kind: .success, text: "Line complete: \(name)")
                Button("Next line") {
                    trainer.continueAfterLine()
                    scheduleOpponentIfNeeded()
                }
                .buttonStyle(.primary)
            }
        case .sessionComplete:
            sessionSummary
        }
    }

    @ViewBuilder private var prompt: some View {
        if trainer.isLearnerTurn {
            if trainer.mode == .learn, let text = trainer.upcomingExplanation {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Play the highlighted move").font(.headline)
                    Text(text).font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
                }
                .card()
            } else {
                Text("Your move — find the move from your study plan.")
                    .font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
            }
        } else if trainer.isOpponentTurn {
            HStack(spacing: 8) {
                ProgressView()
                Text("Opponent is moving…").font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
            }
        }
    }

    @ViewBuilder private var explanationText: some View {
        if let e = trainer.explanation {
            Text(e).font(.subheadline).foregroundStyle(KA.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        let note = model.note(for: trainer.position)
        if !note.isEmpty {
            Label(note, systemImage: "note.text").font(.footnote).foregroundStyle(KA.Palette.info)
        }
    }

    private var sessionSummary: some View {
        VStack(alignment: .leading, spacing: KA.Spacing.m) {
            Text("Session complete").font(.title3.bold())
            if trainer.mode == .memory {
                let pct = trainer.gradedCount == 0 ? 0 : Int(Double(trainer.correctCount) / Double(trainer.gradedCount) * 100)
                Text("\(trainer.correctCount) of \(trainer.gradedCount) moves recalled (\(pct)%). Missed moves are scheduled for review sooner.")
                    .font(.subheadline)
            } else {
                Text("You walked through \(trainer.completedLineIDs.count) line\(trainer.completedLineIDs.count == 1 ? "" : "s"). Now test yourself from memory.")
                    .font(.subheadline)
                if let openingID {
                    Button("Play from memory") {
                        router.push(.trainer(openingID: openingID, mode: .memory, side: trainer.learnerSide, startNode: MoveTree.rootID))
                    }
                    .buttonStyle(.primary)
                }
            }
            Button("Done") { dismiss() }.buttonStyle(.secondary)
        }
        .card()
        .onAppear { Feedback.success() }
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            ToolButton(title: "Back", symbol: "arrow.uturn.backward") {
                opponentTask?.cancel()
                trainer.undo()
            }
            if trainer.mode == .memory {
                ToolButton(title: trainer.hintLevel == 0 ? "Hint" : trainer.hintLevel == 1 ? "More" : "Show", symbol: "lightbulb") {
                    trainer.hint()
                    if case .revealed = trainer.feedback { afterLearnerMove() }
                }
                .disabled(!trainer.isLearnerTurn)
            } else {
                ToolButton(title: "Play move", symbol: "forward.fill") {
                    trainer.playShownMove()
                    afterLearnerMove()
                }
                .disabled(!(trainer.isLearnerTurn || trainer.isOpponentTurn))
            }
            ToolButton(title: "Restart", symbol: "arrow.counterclockwise") {
                opponentTask?.cancel()
                trainer.restartLine()
                scheduleOpponentIfNeeded()
            }
        }
        .padding(.vertical, 4)
        .card(padding: 6)
    }

    // MARK: Opponent moves

    private func afterLearnerMove() {
        switch trainer.feedback {
        case .correct, .alternative, .revealed: Feedback.success()
        case .incorrect: Feedback.error()
        default: break
        }
        scheduleOpponentIfNeeded()
    }

    private func scheduleOpponentIfNeeded() {
        guard trainer.isOpponentTurn else { return }
        opponentTask?.cancel()
        opponentTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
            if trainer.playOpponentMove() != nil { Feedback.move() }
        }
    }
}

/// Personal note attached to a position (shared across openings and repertoires).
struct PositionNoteSheet: View {
    let position: Position
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BoardThumbnail(position: position, orientation: position.sideToMove, theme: model.settings.boardTheme)
                        .frame(maxWidth: 220)
                        .frame(maxWidth: .infinity)
                }
                Section("Your note") {
                    TextEditor(text: $text).frame(minHeight: 140)
                }
            }
            .navigationTitle("Position note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.setNote(text, for: position)
                        dismiss()
                    }
                }
            }
            .onAppear { text = model.note(for: position) }
        }
    }
}

/// Live engine evaluation of a position (advanced study option).
struct EngineEvalView: View {
    let position: Position
    @Environment(AppModel.self) private var model
    @State private var result: SearchResult?
    @State private var engine: ChessEngine?
    @State private var failed = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu").foregroundStyle(KA.Palette.info)
            if let r = result, let score = r.score {
                let white = score.fromWhite(sideToMove: position.sideToMove)
                Text(white.display).font(.headline.monospacedDigit())
                Text(GameAnalyzer.sanLine(r.lines.first?.pv ?? [r.bestMove], from: position, limit: 5).joined(separator: " "))
                    .font(.caption.monospaced()).foregroundStyle(KA.Palette.textSecondary).lineLimit(1)
            } else if failed {
                Text("Engine unavailable").font(.caption).foregroundStyle(KA.Palette.textSecondary)
            } else {
                ProgressView().controlSize(.small)
                Text("Evaluating…").font(.caption).foregroundStyle(KA.Palette.textSecondary)
            }
            Spacer()
        }
        .card(padding: 10)
        .task(id: position.fen) {
            guard position.hasLegalMoves else { return }
            result = nil
            if engine == nil { engine = model.engines.makeEngine() }
            guard let engine else { return }
            do {
                result = try await engine.search(SearchRequest(position: position, limit: SearchLimit(depth: 14, moveTimeMs: 700)))
            } catch {
                failed = true
            }
        }
        .onDisappear {
            if let engine { Task { await engine.shutdown() } }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Numbered SAN moves in a wrapping layout.
struct MoveListView: View {
    let sans: [String]
    var startPosition: Position = .start
    /// Highlighted ply index (0-based), if any.
    var current: Int?
    var annotations: [Int: String] = [:]
    var onSelect: ((Int) -> Void)?

    var body: some View {
        if sans.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { proxy in
                    HStack(spacing: 6) {
                        ForEach(Array(sans.enumerated()), id: \.offset) { i, san in
                            let label = Notation.moveNumberLabel(ply: i, startPosition: startPosition)
                            let showNumber = !label.hasSuffix("...") || i == 0
                            Button { onSelect?(i) } label: {
                                Text((showNumber ? label + " " : "") + san + (annotations[i] ?? ""))
                                    .font(.callout.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(current == i ? KA.Palette.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .disabled(onSelect == nil)
                            .id(i)
                        }
                    }
                    .onChange(of: current ?? sans.count - 1) { _, new in
                        withAnimation { proxy.scrollTo(new, anchor: .center) }
                    }
                    .onAppear { proxy.scrollTo(current ?? sans.count - 1, anchor: .trailing) }
                }
            }
            .card(padding: 8)
            .accessibilityLabel("Moves: \(Notation.movetext(sans: sans, startPosition: startPosition))")
        }
    }
}
