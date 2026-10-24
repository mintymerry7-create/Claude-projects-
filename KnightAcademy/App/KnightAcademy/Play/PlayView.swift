import SwiftUI
import ChessCore
import ChessEngine
import OpeningDatabase
import Learning
import AppFeatures

/// Game setup: opponent, colour, clock and starting position.
struct PlayView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    enum ColorChoice: String, CaseIterable, Identifiable {
        case white, black, random
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum StartChoice: String, CaseIterable, Identifiable {
        case standard, opening, practice, repertoire, fen
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: return "Standard"
            case .opening: return "From an opening"
            case .practice: return "Practise an opening"
            case .repertoire: return "My repertoire"
            case .fen: return "From FEN"
            }
        }
    }

    @State private var bot: BotProfile = .intermediate
    @State private var customSkill = 10.0
    @State private var customDepth = 8.0
    @State private var customTime = 600.0
    @State private var useCustom = false
    @State private var colorChoice: ColorChoice = .white
    @State private var timeControl: TimeControl = .untimed
    @State private var start: StartChoice = .standard
    @State private var openingID: String?
    @State private var repertoireID: UUID?
    @State private var fen = ""
    @State private var casual = true
    @State private var showOpeningPicker = false

    var body: some View {
        Form {
            engineSection
            botSection
            Section("Your colour") {
                Picker("Colour", selection: $colorChoice) {
                    ForEach(ColorChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Time control") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TimeControl.presets) { tc in
                            ChoiceChip(title: tc.display, selected: tc == timeControl) { timeControl = tc }
                        }
                    }
                }
                Toggle("Casual (allow take-backs)", isOn: $casual)
            }
            startSection
            Section {
                Button("Start game") { startGame() }
                    .buttonStyle(.primary)
                    .disabled(!canStart)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if !model.recentGames.isEmpty {
                Section("Recent games") {
                    ForEach(model.recentGames) { g in
                        NavigationLink(value: Route.savedGame(g.id)) { GameRow(game: g) }
                    }
                    NavigationLink("All games", value: Route.gameHistory)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Play")
        .sheet(isPresented: $showOpeningPicker) {
            OpeningPickerSheet(selection: $openingID)
        }
    }

    // MARK: Sections

    private var engineSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: model.engines.isStockfishAvailable && model.settings.preferStockfish ? "bolt.shield.fill" : "cpu")
                    .foregroundStyle(KA.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Engine: \(model.engines.engineName)").font(.subheadline.weight(.semibold))
                    Text(model.engines.isStockfishAvailable
                         ? "Runs on your device, fully offline."
                         : "Stockfish network files are not installed in this build; the built-in engine is used. See the README to enable Stockfish.")
                        .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                }
            }
        }
    }

    private var botSection: some View {
        Section {
            ForEach(BotProfile.presets) { p in
                Button {
                    bot = p
                    useCustom = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: p.symbol).frame(width: 26).foregroundStyle(KA.Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.headline)
                            Text(p.summary).font(.caption).foregroundStyle(KA.Palette.textSecondary)
                        }
                        Spacer()
                        if !useCustom && bot.id == p.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(KA.Palette.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(!useCustom && bot.id == p.id ? .isSelected : [])
            }
            DisclosureGroup(isExpanded: $useCustom) {
                VStack(alignment: .leading) {
                    Text("Skill level \(Int(customSkill)) of 20").font(.subheadline)
                    Slider(value: $customSkill, in: 0...20, step: 1)
                    Text("Search depth \(Int(customDepth))").font(.subheadline)
                    Slider(value: $customDepth, in: 1...20, step: 1)
                    Text("Thinking time \(Int(customTime)) ms").font(.subheadline)
                    Slider(value: $customTime, in: 100...3000, step: 100)
                }
            } label: {
                Label("Custom difficulty", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("Opponent")
        } footer: {
            Text("Bots use engine skill, depth and time settings. They are not calibrated to ratings.")
        }
    }

    private var startSection: some View {
        Section("Starting position") {
            Picker("Start", selection: $start) {
                ForEach(StartChoice.allCases) { Text($0.title).tag($0) }
            }
            switch start {
            case .standard:
                EmptyView()
            case .opening, .practice:
                Button {
                    showOpeningPicker = true
                } label: {
                    HStack {
                        Text("Opening")
                        Spacer()
                        Text(openingID.flatMap { model.db.opening(id: $0)?.name } ?? "Choose…")
                            .foregroundStyle(KA.Palette.textSecondary)
                    }
                }
                if start == .practice {
                    Text("The bot follows the opening's theory while you stay in book, then plays its own moves. You'll be told when you leave your prepared lines.")
                        .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                }
            case .repertoire:
                if model.data.repertoires.isEmpty {
                    Text("Create a repertoire in Profile first.").font(.caption).foregroundStyle(KA.Palette.textSecondary)
                } else {
                    Picker("Repertoire", selection: $repertoireID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(model.data.repertoires) { r in Text("\(r.name) (\(r.color.displayName))").tag(Optional(r.id)) }
                    }
                }
            case .fen:
                TextField("Paste a FEN", text: $fen, axis: .vertical)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !fen.isEmpty {
                    if let error = fenError {
                        Text(error).font(.caption).foregroundStyle(KA.Palette.danger)
                    } else if let p = try? Position(fen: fen) {
                        BoardThumbnail(position: p, theme: model.settings.boardTheme).frame(height: 160)
                    }
                }
            }
        }
    }

    // MARK: Logic

    private var fenError: String? {
        do { _ = try Position(fen: fen); return nil } catch { return error.localizedDescription }
    }

    private var canStart: Bool {
        switch start {
        case .standard: return true
        case .opening, .practice: return openingID != nil
        case .repertoire: return repertoireID != nil
        case .fen: return !fen.isEmpty && fenError == nil && ((try? Position(fen: fen))?.hasLegalMoves ?? false)
        }
    }

    private func startGame() {
        var profile = bot
        if useCustom {
            profile = .custom(skillLevel: Int(customSkill), depth: Int(customDepth), moveTimeMs: Int(customTime))
        }
        let color: PieceColor = colorChoice == .random ? (Bool.random() ? .white : .black) : (colorChoice == .white ? .white : .black)
        var setup = GameSetup(bot: profile, playerColor: color, timeControl: timeControl, casual: casual)
        switch start {
        case .standard:
            break
        case .opening:
            if let o = openingID.flatMap(model.db.opening(id:)) { setup.startMoves = o.definingMoves }
        case .practice:
            if let o = openingID.flatMap(model.db.opening(id:)) {
                let course = model.course(for: o.id)
                // "Random" practises the side you study for this opening.
                if colorChoice == .random { setup.playerColor = course?.side ?? o.side }
                let plan = StudyPlanBuilder.build(opening: o, settings: course?.settings ?? .intermediate, side: setup.playerColor)
                setup.book = plan.tree
                setup.playerBook = plan.tree
                setup.bookName = o.name
            }
        case .repertoire:
            if let r = model.data.repertoires.first(where: { $0.id == repertoireID }) {
                setup.playerColor = r.color
                if r.isFromStandardStart {
                    setup.book = r.tree
                    setup.playerBook = r.tree
                } else {
                    setup.startFEN = r.tree.root.fen
                }
                setup.bookName = r.name
            }
        case .fen:
            setup.startFEN = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        router.push(.game(setup))
    }
}

/// Searchable opening chooser.
struct OpeningPickerSheet: View {
    @Binding var selection: String?
    var side: PieceColor?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(model.db.search(OpeningFilter(query: query, side: side))) { o in
                Button {
                    selection = o.id
                    dismiss()
                } label: {
                    HStack {
                        OpeningRow(opening: o)
                        Spacer()
                        if selection == o.id { Image(systemName: "checkmark").foregroundStyle(KA.Palette.accent) }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Choose an opening")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
