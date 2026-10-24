import SwiftUI
import Charts
import ChessCore
import ChessEngine
import Learning
import AppFeatures

/// Replay a saved game move by move, with optional engine analysis.
struct GameReviewView: View {
    let gameID: UUID
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var replay: GameReplay?
    @State private var progress: Double?
    @State private var error: String?
    @State private var analysisTask: Task<Void, Never>?

    private var saved: SavedGame? { model.data.games.first { $0.id == gameID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                if let saved, let replay {
                    header(saved)
                    ChessBoardView(display: orientedDisplay(replay, saved))
                    navigation
                    if let a = replay.moveAnalysis { moveComment(a) }
                    MoveListView(sans: replay.game.sanMoves, startPosition: replay.game.startPosition,
                                 current: replay.ply > 0 ? replay.ply - 1 : nil,
                                 annotations: annotations(replay)) { i in self.replay?.goTo(i + 1) }
                    analysisSection(replay, saved)
                    actions(replay, saved)
                } else if let error {
                    ContentUnavailableView("Can't open this game", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .padding(KA.Spacing.l)
        }
        .screenBackground()
        .navigationTitle("Game review")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .onDisappear { analysisTask?.cancel() }
    }

    private func load() {
        guard replay == nil, let saved else { return }
        do {
            replay = try GameReplay(pgn: saved.pgn, analysis: saved.analysis)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func orientedDisplay(_ r: GameReplay, _ g: SavedGame) -> BoardDisplay {
        var d = r.display
        d.orientation = g.playerColor
        return d
    }

    private func header(_ g: SavedGame) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("vs \(g.opponent)").font(.headline)
            Text([g.openingName, g.reason, g.result].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(KA.Palette.textSecondary)
        }
    }

    private var navigation: some View {
        HStack {
            ToolButton(title: "Start", symbol: "backward.end.fill") { replay?.toStart() }
            ToolButton(title: "Back", symbol: "chevron.left") { replay?.back() }
            ToolButton(title: "Forward", symbol: "chevron.right") { replay?.forward() }
            ToolButton(title: "End", symbol: "forward.end.fill") { replay?.toEnd() }
        }
        .card(padding: 6)
    }

    private func moveComment(_ a: MoveAnalysis) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(a.classification.symbol.isEmpty ? "•" : a.classification.symbol)
                .font(.headline)
                .foregroundStyle(tint(a.classification))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Notation.moveNumberLabel(ply: a.ply))\(a.san) — \(a.classification.displayName)").font(.subheadline.weight(.semibold))
                Text(a.comment).font(.subheadline)
                if !a.bestLine.isEmpty, a.classification != .best, a.classification != .book {
                    Text("Best: " + a.bestLine.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(KA.Palette.textSecondary)
                }
                Text("Evaluation: \(a.evalAfter.display)").font(.caption).foregroundStyle(KA.Palette.textSecondary)
            }
        }
        .card(padding: 12)
    }

    private func annotations(_ r: GameReplay) -> [Int: String] {
        var out: [Int: String] = [:]
        for m in r.analysis?.moves ?? [] where [.inaccuracy, .mistake, .blunder].contains(m.classification) {
            out[m.ply] = m.classification.symbol
        }
        return out
    }

    @ViewBuilder private func analysisSection(_ r: GameReplay, _ g: SavedGame) -> some View {
        if let a = r.analysis {
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                Text("Analysis · \(a.engineName), depth \(a.depth)").font(.headline)
                evalChart(a)
                HStack(spacing: KA.Spacing.m) {
                    accuracyColumn(title: "White", accuracy: a.whiteAccuracy, analysis: a, color: .white)
                    accuracyColumn(title: "Black", accuracy: a.blackAccuracy, analysis: a, color: .black)
                }
                if !a.keyMoments.isEmpty {
                    Text("Key moments").font(.subheadline.weight(.semibold))
                    ForEach(a.keyMoments.prefix(5)) { m in
                        Button { replay?.goTo(m.ply + 1) } label: {
                            HStack {
                                Text("\(Notation.moveNumberLabel(ply: m.ply))\(m.san)\(m.classification.symbol)").font(.callout.monospaced())
                                Text(m.comment).font(.caption).foregroundStyle(KA.Palette.textSecondary).lineLimit(2)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .card()
        } else if let p = progress {
            VStack(alignment: .leading, spacing: 8) {
                Text("Analysing with \(model.engines.engineName)…").font(.subheadline)
                ProgressView(value: p).tint(KA.Palette.accent)
            }
            .card()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Find your mistakes and missed opportunities with an engine review of every move.")
                    .font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
                Button("Analyse game") { analyse(g) }.buttonStyle(.primary)
            }
            .card()
        }
    }

    private func evalChart(_ a: GameAnalysis) -> some View {
        Chart(a.moves) { m in
            LineMark(x: .value("Move", m.ply + 1), y: .value("Eval", Self.pawns(m.evalAfter)))
                .interpolationMethod(.monotone)
                .foregroundStyle(KA.Palette.accent)
            if [.mistake, .blunder].contains(m.classification) {
                PointMark(x: .value("Move", m.ply + 1), y: .value("Eval", Self.pawns(m.evalAfter)))
                    .foregroundStyle(m.classification == .blunder ? KA.Palette.danger : KA.Palette.warning)
            }
            RuleMark(y: .value("Equal", 0)).foregroundStyle(KA.Palette.stroke)
        }
        .chartYScale(domain: -10...10)
        .chartYAxis { AxisMarks(values: [-5, 0, 5]) }
        .frame(height: 140)
        .accessibilityLabel("Evaluation graph from White's point of view")
    }

    static func pawns(_ s: EngineScore) -> Double {
        switch s {
        case .centipawns(let cp): return max(-10, min(10, Double(cp) / 100))
        case .mate(let m): return m > 0 ? 10 : -10
        }
    }

    private func accuracyColumn(title: String, accuracy: Double, analysis a: GameAnalysis, color: PieceColor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SideBadge(isWhite: color == .white)
                Text(title).font(.subheadline.weight(.semibold))
            }
            Text("\(Int(accuracy.rounded()))% accuracy").font(.headline.monospacedDigit())
            Text("\(a.count(.inaccuracy, for: color)) inaccuracies").font(.caption)
            Text("\(a.count(.mistake, for: color)) mistakes").font(.caption).foregroundStyle(KA.Palette.warning)
            Text("\(a.count(.blunder, for: color)) blunders").font(.caption).foregroundStyle(KA.Palette.danger)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(_ r: GameReplay, _ g: SavedGame) -> some View {
        HStack(spacing: KA.Spacing.s) {
            ShareLink(item: g.pgn, preview: SharePreview("Game PGN")) {
                Label("Share PGN", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.secondary)
            Button {
                router.push(.game(GameSetup(bot: .intermediate, playerColor: r.position.sideToMove, startFEN: r.position.fen)))
            } label: {
                Label("Play from here", systemImage: "play")
            }
            .buttonStyle(.secondary)
            .disabled(!r.position.hasLegalMoves)
        }
    }

    private func tint(_ c: MoveClassification) -> Color {
        switch c {
        case .blunder: return KA.Palette.danger
        case .mistake: return KA.Palette.warning
        case .inaccuracy: return KA.Palette.info
        default: return KA.Palette.accent
        }
    }

    private func analyse(_ g: SavedGame) {
        guard let game = replay?.game else { return }
        progress = 0
        let engine = model.engines.makeEngine()
        let stockfish = engine is UCIEngine
        let analyzer = GameAnalyzer(engine: engine, depth: stockfish ? 14 : 4, moveTimeMs: stockfish ? 600 : 2500)
        let bookPlies = bookLength(game)
        analysisTask = Task { @MainActor in
            do {
                let result = try await analyzer.analyze(game, bookPlies: bookPlies) { p in
                    Task { @MainActor in self.progress = p }
                }
                model.attach(analysis: result, to: g.id)
                let ply = replay?.ply ?? 0
                replay = GameReplay(game: game, analysis: result)
                replay?.goTo(ply)
                progress = nil
            } catch {
                self.error = nil
                progress = nil
            }
            await engine.shutdown()
        }
    }

    /// Plies that follow known theory, labelled "book" in the review.
    private func bookLength(_ game: ChessGame) -> Int {
        guard game.startPosition.fen == Position.startFEN else { return 0 }
        var keys = Set<String>()
        for o in model.db.openings {
            for l in o.lines where l.kind != .sideline {
                var p = Position.start
                for s in l.moves {
                    guard let next = try? p.playing(san: s) else { break }
                    p = next
                    keys.insert(p.repetitionKey)
                }
            }
        }
        var n = 0
        for (i, pos) in game.positions.enumerated() where i > 0 {
            if keys.contains(pos.repetitionKey) { n = i } else { break }
        }
        return n
    }
}

struct GameHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var showImport = false

    var body: some View {
        List {
            let record = model.gameRecord
            Section {
                HStack {
                    StatTile(value: "\(record.wins)", label: "wins", symbol: "trophy")
                    StatTile(value: "\(record.draws)", label: "draws", symbol: "equal.circle", tint: KA.Palette.info)
                    StatTile(value: "\(record.losses)", label: "losses", symbol: "flag", tint: KA.Palette.danger)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section("Games") {
                if model.data.games.isEmpty {
                    Text("No games yet — play a bot from the Play tab.").foregroundStyle(KA.Palette.textSecondary)
                }
                ForEach(model.data.games.sorted { $0.date > $1.date }) { g in
                    NavigationLink(value: Route.savedGame(g.id)) { GameRow(game: g) }
                }
                .onDelete { idx in
                    let sorted = model.data.games.sorted { $0.date > $1.date }
                    for i in idx { model.deleteGame(sorted[i].id) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Games")
        .toolbar {
            Button { showImport = true } label: { Label("Import PGN", systemImage: "square.and.arrow.down") }
        }
        .sheet(isPresented: $showImport) {
            PGNImportSheet(title: "Import game") { text in
                let game = try PGNParser.parseFirst(text)
                let played = try game.mainlineGame()
                let tags = game.tags
                let saved = SavedGame(pgn: played.pgn(tags: tags), opponent: tags["Black"].map { "\(tags["White"] ?? "?") – \($0)" } ?? "Imported game",
                                      playerColor: .white, result: game.result, reason: tags["Termination"] ?? "Imported",
                                      openingName: tags["Opening"] ?? model.db.identify(moves: played.moves)?.name)
                model.save(game: saved)
                return "Imported \(played.plyCount) moves."
            }
        }
    }
}
