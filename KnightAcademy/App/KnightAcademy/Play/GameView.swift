import SwiftUI
import ChessCore
import ChessEngine
import OpeningDatabase
import Learning
import AppFeatures

struct GameScreen: View {
    let setup: GameSetup
    @Environment(AppModel.self) private var model
    @State private var session: GameSession?
    @State private var error: String?

    var body: some View {
        Group {
            if let session {
                GameView(session: session)
            } else if let error {
                ContentUnavailableView("Could not start the game", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView("Starting engine…")
            }
        }
        .task {
            guard session == nil else { return }
            do {
                let s = try GameSession(setup: setup, engine: model.engines.makeEngine())
                session = s
                s.start()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct GameView: View {
    let session: GameSession
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var flipped = false
    @State private var confirmResign = false
    @State private var savedGameID: UUID?
    @State private var drawPending = false

    private var openingName: String? {
        guard session.game.startPosition == .start || session.game.startPosition.fen == Position.startFEN else { return session.setup.bookName }
        return model.db.identify(moves: session.game.moves)?.name ?? session.setup.bookName
    }

    var body: some View {
        ScrollView {
            VStack(spacing: KA.Spacing.m) {
                playerBar(isBot: true)
                ChessBoardView(display: boardDisplay) { move in
                    session.play(move)
                }
                playerBar(isBot: false)
                messages
                MoveListView(sans: session.game.sanMoves, startPosition: session.game.startPosition, current: nil)
                if session.isFinished {
                    resultCard
                } else {
                    controls
                }
            }
            .padding(KA.Spacing.l)
        }
        .screenBackground()
        .navigationTitle(session.setup.bookName ?? "vs \(session.setup.bot.name) bot")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!session.isFinished && session.game.plyCount > session.setup.startMoves.count)
        .toolbar {
            if !session.isFinished && session.game.plyCount > session.setup.startMoves.count {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Leave") { confirmResign = true }
                }
            }
        }
        .confirmationDialog("Resign this game?", isPresented: $confirmResign, titleVisibility: .visible) {
            Button("Resign", role: .destructive) { session.resign() }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: session.setup.timeControl.isTimed) {
            guard session.setup.timeControl.isTimed else { return }
            while !Task.isCancelled && !session.isFinished {
                session.tick()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        .onChange(of: session.isFinished) { _, finished in
            if finished { saveIfNeeded() }
        }
        .onChange(of: session.game.plyCount) { _, _ in
            if session.isPlayerTurn, let last = session.game.lastMove, session.game.plyCount > 0 {
                let before = session.game.positions[session.game.plyCount - 1]
                Feedback.move(capture: before.isCapture(last))
            }
        }
    }

    private var boardDisplay: BoardDisplay {
        var d = session.display
        if flipped { d.orientation = d.orientation.opposite }
        return d
    }

    // MARK: Player bars

    private func playerBar(isBot: Bool) -> some View {
        let color = isBot ? session.setup.playerColor.opposite : session.setup.playerColor
        return HStack(spacing: 10) {
            Image(systemName: isBot ? session.setup.bot.symbol : "person.fill")
                .frame(width: 32, height: 32)
                .background(KA.Palette.surfaceElevated, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(isBot ? "\(session.setup.bot.name) bot" : (model.settings.playerName.isEmpty ? "You" : model.settings.playerName))
                    .font(.subheadline.weight(.semibold))
                Text(isBot ? session.engineName : color.displayName).font(.caption2).foregroundStyle(KA.Palette.textSecondary)
            }
            if isBot && session.phase == .botThinking {
                ProgressView().controlSize(.small).accessibilityLabel("Bot is thinking")
            }
            Spacer()
            if session.setup.timeControl.isTimed {
                TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                    let ms = session.clock.remaining(color, now: ctx.date)
                    Text(Self.format(ms))
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(session.clock.running == color ? Color.white : Color.primary)
                        .background(session.clock.running == color ? (ms < 20_000 ? KA.Palette.danger : KA.Palette.accent) : KA.Palette.surfaceElevated,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("\(color.displayName) clock \(Self.format(ms))")
                }
            }
        }
    }

    static func format(_ ms: Int) -> String {
        let total = ms / 1000
        if total < 20 { return String(format: "%d:%02d.%d", total / 60, total % 60, (ms % 1000) / 100) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Messages & controls

    @ViewBuilder private var messages: some View {
        if let name = openingName, session.game.plyCount > 0 {
            Text(name).font(.caption).foregroundStyle(KA.Palette.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        if let m = session.message {
            FeedbackBanner(kind: .info, text: m)
        }
        if let e = session.errorMessage {
            FeedbackBanner(kind: .error, text: e)
        }
        if session.position.isCheck && !session.isFinished {
            Text("Check!").font(.headline).foregroundStyle(KA.Palette.danger)
        }
    }

    private var controls: some View {
        HStack {
            if session.setup.casual {
                ToolButton(title: "Undo", symbol: "arrow.uturn.backward") { session.undo() }
                    .disabled(!session.canUndo)
            }
            ToolButton(title: "Hint", symbol: "lightbulb") {
                Task { await session.requestHint() }
            }
            .disabled(!session.isPlayerTurn)
            ToolButton(title: "Draw", symbol: "equal.circle") {
                drawPending = true
                Task {
                    _ = await session.offerDraw()
                    drawPending = false
                }
            }
            .disabled(!session.isPlayerTurn || drawPending)
            ToolButton(title: "Flip", symbol: "arrow.up.arrow.down") { flipped.toggle() }
            ToolButton(title: "Resign", symbol: "flag", role: .destructive) { confirmResign = true }
        }
        .card(padding: 6)
    }

    private var resultCard: some View {
        let outcome = session.outcome
        let won = outcome?.result.winner == session.setup.playerColor
        let draw = outcome?.result == .draw
        return VStack(spacing: KA.Spacing.m) {
            Image(systemName: won ? "trophy.fill" : draw ? "equal.circle.fill" : "flag.fill")
                .font(.system(size: 40))
                .foregroundStyle(won ? KA.Palette.gold : draw ? KA.Palette.info : KA.Palette.textSecondary)
            Text(won ? "You won!" : draw ? "Draw" : "You lost").font(.title2.bold())
            Text(outcome?.summary ?? "").foregroundStyle(KA.Palette.textSecondary)
            if let id = savedGameID {
                Button("Review & analyse") { router.push(.savedGame(id)) }.buttonStyle(.primary)
            }
            HStack(spacing: KA.Spacing.s) {
                Button("Rematch") {
                    var s = session.setup
                    s.playerColor = s.playerColor.opposite
                    router.push(.game(s))
                }
                .buttonStyle(.secondary)
                Button("Done") { dismiss() }.buttonStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
        .onAppear {
            if won { Feedback.success() }
        }
    }

    private func saveIfNeeded() {
        guard savedGameID == nil, let g = session.savedGame(openingName: openingName) else { return }
        model.save(game: g)
        savedGameID = g.id
    }
}
