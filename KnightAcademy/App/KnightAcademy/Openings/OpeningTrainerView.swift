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

/// Learn / play-from-memory screen for one study plan: instruction card,
/// eval bar, edge-to-edge board and a compact bottom toolbar.
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
        VStack(spacing: 0) {
            header
            progressRow
            instructionCard
                .padding(.horizontal, KA.Spacing.l)
                .padding(.vertical, KA.Spacing.m)
            EvalBar(position: trainer.position)
            ChessBoardView(display: trainer.display, cornerRadius: 0) { move in
                trainer.submit(move)
                afterLearnerMove()
            }
            MoveListView(sans: trainer.plan.tree.sans(to: trainer.nodeID), startPosition: .start, current: nil)
                .padding(.horizontal, KA.Spacing.s)
                .padding(.top, KA.Spacing.s)
            Spacer(minLength: 0)
            bottomBar
        }
        .background(KA.Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showNotes) {
            PositionNoteSheet(position: trainer.position)
        }
        .onAppear(perform: scheduleOpponentIfNeeded)
        .onDisappear { opponentTask?.cancel() }
    }

    // MARK: Header

    private var lineNumber: Int { min(trainer.completedLineIDs.count + 1, max(1, trainer.totalLines)) }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: trainer.mode == .learn ? "book.fill" : "brain.head.profile")
            Text(trainer.mode == .learn ? "Learn" : "Practice").fontWeight(.semibold)
            Text(title).foregroundStyle(KA.Palette.textSecondary).lineLimit(1)
            Text("#\(lineNumber)").foregroundStyle(KA.Palette.textSecondary)
        }
        .font(.subheadline)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    private var lineProgress: Double {
        guard let line = trainer.currentLine, !line.moves.isEmpty else { return trainer.isFinished ? 1 : 0 }
        return min(1, Double(trainer.plyInLine) / Double(line.moves.count))
    }

    private var progressRow: some View {
        HStack(spacing: KA.Spacing.m) {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left").font(.title3.weight(.medium))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(KA.Palette.surfaceElevated)
                    Capsule().fill(KA.Palette.accent)
                        .frame(width: max(8, geo.size.width * lineProgress))
                        .animation(.easeOut(duration: 0.25), value: lineProgress)
                }
            }
            .frame(height: 8)
            .accessibilityElement()
            .accessibilityLabel("Line progress")
            .accessibilityValue("\(Int(lineProgress * 100)) percent")
        }
        .padding(.horizontal, KA.Spacing.l)
        .padding(.top, 4)
    }

    // MARK: Instruction card

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardContent
        }
        .font(.callout)
        .foregroundStyle(KA.Palette.instructionText)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(14)
        .background(KA.Palette.instructionCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private var cardContent: some View {
        switch trainer.feedback {
        case .idle:
            idleContent
        case .correct(let san):
            explanationText
            Text("\(san) — correct!").fontWeight(.bold).foregroundStyle(KA.Palette.accent)
        case .alternative(let san):
            explanationText
            Text("\(san) is also in your plan — switching lines.").fontWeight(.bold).foregroundStyle(KA.Palette.accent)
        case let .incorrect(san, hint):
            Text(hint)
            Text("\(san) is not the move here.").fontWeight(.bold).foregroundStyle(KA.Palette.danger)
        case .revealed(let san):
            explanationText
            Text("The move was \(san). It will come back for review.").fontWeight(.bold).foregroundStyle(KA.Palette.warning)
        case .lineComplete(let name):
            Text("Line complete").foregroundStyle(.secondary)
            Text(name).fontWeight(.bold)
            Button("Next line") {
                trainer.continueAfterLine()
                scheduleOpponentIfNeeded()
            }
            .buttonStyle(.primary)
        case .sessionComplete:
            sessionSummary
        }
    }

    @ViewBuilder private var idleContent: some View {
        if trainer.isLearnerTurn, let move = trainer.nextLineMove {
            if trainer.mode == .learn {
                if let text = trainer.upcomingExplanation { Text(text).fixedSize(horizontal: false, vertical: true) }
                Text(MoveExplainer.instruction(for: move, in: trainer.position)).fontWeight(.bold)
            } else {
                Text("Your move. Recall what your plan plays here.")
                Text(trainer.hintLevel == 0 ? "Find the move." : "Use the highlighted piece.").fontWeight(.bold)
            }
        } else if trainer.isOpponentTurn {
            explanationText
            Text("Opponent is moving…").fontWeight(.bold).foregroundStyle(.secondary)
        } else {
            Text(trainer.plan.opening.summary)
        }
    }

    @ViewBuilder private var explanationText: some View {
        if let e = trainer.explanation {
            Text(e).fixedSize(horizontal: false, vertical: true)
        }
        let note = model.note(for: trainer.position)
        if !note.isEmpty {
            Label(note, systemImage: "note.text").font(.footnote).foregroundStyle(KA.Palette.info)
        }
    }

    @ViewBuilder private var sessionSummary: some View {
        Text("Session complete").font(.headline)
        if trainer.mode == .memory {
            let pct = trainer.gradedCount == 0 ? 0 : Int(Double(trainer.correctCount) / Double(trainer.gradedCount) * 100)
            Text("\(trainer.correctCount) of \(trainer.gradedCount) moves recalled (\(pct)%). Missed moves come back sooner.")
        } else {
            Text("You walked through \(trainer.completedLineIDs.count) line\(trainer.completedLineIDs.count == 1 ? "" : "s"). Now test yourself from memory.")
        }
        HStack {
            if trainer.mode == .learn, let openingID {
                Button("Play from memory") {
                    router.push(.trainer(openingID: openingID, mode: .memory, side: trainer.learnerSide, startNode: MoveTree.rootID))
                }
                .buttonStyle(.primary)
            }
            Button("Done") { dismiss() }.buttonStyle(.secondary)
        }
        .onAppear { Feedback.success() }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
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
                Button {
                    opponentTask?.cancel()
                    trainer.restartLine()
                    scheduleOpponentIfNeeded()
                } label: { Label("Restart line", systemImage: "arrow.counterclockwise") }
            } label: {
                barIcon("gearshape")
            }
            .accessibilityLabel("More options")

            barButton(trainer.mode == .memory && trainer.hintLevel > 0 ? (trainer.hintLevel == 1 ? "More" : "Show") : "Hint",
                      symbol: "lightbulb") {
                if trainer.mode == .memory {
                    trainer.hint()
                    if case .revealed = trainer.feedback { afterLearnerMove() }
                } else {
                    trainer.playShownMove()
                    afterLearnerMove()
                }
            }
            .disabled(!trainer.isLearnerTurn)

            if let openingID {
                barButton("Mode", symbol: "gamecontroller") {
                    let next: TrainerMode = trainer.mode == .learn ? .memory : .learn
                    router.push(.trainer(openingID: openingID, mode: next, side: trainer.learnerSide, startNode: trainer.startNodeID))
                }
            }

            Button {
                opponentTask?.cancel()
                trainer.undo()
            } label: { barIcon("chevron.left") }
            .accessibilityLabel("Back one move")

            Button {
                trainer.playShownMove()
                afterLearnerMove()
            } label: { barIcon("chevron.right") }
            .accessibilityLabel("Play move")
            .disabled(trainer.mode == .memory ? !trainer.isOpponentTurn : !(trainer.isLearnerTurn || trainer.isOpponentTurn))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, KA.Spacing.s)
        .padding(.vertical, 6)
        .background(KA.Palette.background)
    }

    private func barIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
    }

    private func barButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
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

/// Thin horizontal evaluation bar: White's share on the left, score on the right.
struct EvalBar: View {
    let position: Position
    @Environment(AppModel.self) private var model
    @State private var score: EngineScore?
    @State private var engine: ChessEngine?

    private var whiteShare: Double {
        guard let score else { return 0.5 }
        return (score.winningChances + 1) / 2
    }

    private var label: String {
        guard let score else { return "…" }
        switch score {
        case .centipawns(let cp): return String(format: "%.1f", abs(Double(cp)) / 100)
        case .mate(let m): return "M\(abs(m))"
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.38))
                Rectangle().fill(Color(white: 0.95))
                    .frame(width: geo.size.width * whiteShare)
                    .animation(.easeOut(duration: 0.35), value: whiteShare)
                Text(label)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(whiteShare >= 0.5 ? Color.black : Color.white)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: whiteShare >= 0.5 ? .leading : .trailing)
            }
        }
        .frame(height: 16)
        .task(id: position.fen) {
            guard position.hasLegalMoves else { return }
            if engine == nil { engine = model.engines.makeEngine() }
            guard let engine else { return }
            if let r = try? await engine.search(SearchRequest(position: position, limit: SearchLimit(depth: 12, moveTimeMs: 400))),
               let s = r.score {
                score = s.fromWhite(sideToMove: position.sideToMove)
            }
        }
        .onDisappear {
            if let engine { Task { await engine.shutdown() } }
        }
        .accessibilityElement()
        .accessibilityLabel("Evaluation")
        .accessibilityValue(score?.display ?? "calculating")
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
