import SwiftUI
import ChessCore
import ChessEngine
import OpeningDatabase
import Learning
import AppFeatures

struct OpeningDetailView: View {
    let openingID: String
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var showDepthPicker = false
    @State private var previewLine: LinePreview?

    var body: some View {
        if let opening = model.db.opening(id: openingID) {
            content(opening)
        } else {
            ContentUnavailableView("Opening not found", systemImage: "questionmark.folder")
        }
    }

    private func content(_ o: Opening) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KA.Spacing.l) {
                header(o)
                courseCard(o)
                section("About") { Text(o.summary).fixedSize(horizontal: false, vertical: true) }
                section("Strategic ideas") { BulletList(items: o.ideas) }
                section("Plans for White") { BulletList(items: o.whitePlans) }
                section("Plans for Black") { BulletList(items: o.blackPlans) }
                section("Tactical motifs") { BulletList(items: o.tactics) }
                section("Common mistakes") { BulletList(items: o.mistakes) }
                if !o.keyPositions.isEmpty { keyPositions(o) }
                linesSection(o)
                Text(o.source).font(.caption2).foregroundStyle(KA.Palette.textSecondary)
            }
            .padding(KA.Spacing.l)
        }
        .screenBackground()
        .navigationTitle(o.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDepthPicker) {
            DepthPickerSheet(opening: o)
        }
        .sheet(item: $previewLine) { p in
            LineViewerSheet(preview: p)
        }
    }

    // MARK: Header

    private func header(_ o: Opening) -> some View {
        HStack(alignment: .top, spacing: KA.Spacing.l) {
            BoardThumbnail(position: o.position, orientation: o.side, theme: model.settings.boardTheme)
                .frame(width: 130, height: 130)
            VStack(alignment: .leading, spacing: 6) {
                Text(o.name).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                if !o.aliases.isEmpty {
                    Text(o.aliases.joined(separator: " · ")).font(.caption).foregroundStyle(KA.Palette.textSecondary)
                }
                HStack(spacing: 6) {
                    Tag(text: o.eco, tint: KA.Palette.textSecondary)
                    Tag(text: o.difficulty.displayName, tint: o.difficulty.tint)
                }
                HStack(spacing: 6) {
                    SideBadge(isWhite: o.side == .white)
                    Text("Played by \(o.side.displayName)").font(.caption)
                }
                Text(o.definingMovetext).font(.caption.monospaced()).foregroundStyle(KA.Palette.textSecondary)
            }
        }
    }

    // MARK: Course

    @ViewBuilder private func courseCard(_ o: Opening) -> some View {
        if let course = model.course(for: o.id), let plan = model.plan(for: o.id) {
            let ids = plan.cards.map(\.id)
            let counts = ProgressStats.statusCounts(cardIDs: ids, in: model.data)
            let due = Set(model.dueReviews().map(\.id))
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                HStack(spacing: KA.Spacing.l) {
                    ProgressRing(progress: ProgressStats.mastery(cardIDs: ids, in: model.data)).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(course.settings.preset.displayName) depth · as \(course.side.displayName)").font(.headline)
                        Text("\(plan.lines.count) lines · \(ids.count) moves to learn · ~\(plan.estimatedMinutes) min")
                            .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                        HStack(spacing: 6) {
                            Tag(text: "\(counts.new) new", tint: CardStatus.new.tint)
                            Tag(text: "\(counts.learning) learning", tint: CardStatus.learning.tint)
                            Tag(text: "\(counts.mastered) mastered", tint: CardStatus.mastered.tint)
                        }
                        let dueHere = ids.filter(due.contains).count
                        if dueHere > 0 {
                            Text("\(dueHere) due for review").font(.caption.weight(.semibold)).foregroundStyle(KA.Palette.warning)
                        }
                    }
                }
                HStack(spacing: KA.Spacing.s) {
                    Button { router.push(.trainer(openingID: o.id, mode: .learn, side: course.side, startNode: MoveTree.rootID)) } label: {
                        Label("Learn", systemImage: "book.fill")
                    }
                    .buttonStyle(.secondary)
                    Button { router.push(.trainer(openingID: o.id, mode: .memory, side: course.side, startNode: MoveTree.rootID)) } label: {
                        Label("From memory", systemImage: "brain")
                    }
                    .buttonStyle(.primary)
                }
                HStack(spacing: KA.Spacing.s) {
                    Button { router.push(.explorer(openingID: o.id)) } label: { Label("Explore", systemImage: "point.3.connected.trianglepath.dotted") }
                    Button { router.push(.game(practiceSetup(o, plan: plan))) } label: { Label("Vs bot", systemImage: "cpu") }
                    Button { showDepthPicker = true } label: { Label("Depth", systemImage: "slider.horizontal.3") }
                }
                .buttonStyle(.secondary)
                Button {
                    let other = course.side.opposite
                    model.updateCourse(o.id, side: other)
                } label: {
                    Text("Practise this opening as \(course.side.opposite.displayName) instead")
                        .font(.footnote.weight(.medium))
                }
            }
            .card()
        } else {
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                Text("Choose how deep to study, then learn the moves one by one with explanations.")
                    .font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
                Button("Start learning") { showDepthPicker = true }.buttonStyle(.primary)
                HStack(spacing: KA.Spacing.s) {
                    Button { router.push(.explorer(openingID: o.id)) } label: { Label("Explore lines", systemImage: "point.3.connected.trianglepath.dotted") }
                    Button {
                        let plan = StudyPlanBuilder.build(opening: o, settings: .beginner)
                        router.push(.game(practiceSetup(o, plan: plan)))
                    } label: { Label("Try vs bot", systemImage: "cpu") }
                }
                .buttonStyle(.secondary)
            }
            .card()
        }
    }

    private func practiceSetup(_ o: Opening, plan: StudyPlan) -> GameSetup {
        let bot: BotProfile = model.settings.level == .advanced ? .advanced : .intermediate
        return GameSetup(bot: bot, playerColor: plan.learnerSide, book: plan.tree, bookName: o.name, playerBook: plan.tree)
    }

    // MARK: Sections

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: KA.Spacing.s) {
            Text(title).font(.headline)
            content()
        }
        .card()
    }

    private func keyPositions(_ o: Opening) -> some View {
        VStack(alignment: .leading, spacing: KA.Spacing.s) {
            Text("Key positions").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: KA.Spacing.m) {
                    ForEach(o.keyPositions, id: \.ply) { kp in
                        Button {
                            previewLine = LinePreview(opening: o, line: o.mainLine, startPly: kp.ply)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                let moves = Array(o.mainLine.moves.prefix(kp.ply))
                                BoardThumbnail(position: (try? Self.position(after: moves)) ?? .start, orientation: o.side,
                                               lastMove: nil, theme: model.settings.boardTheme)
                                    .frame(width: 150, height: 150)
                                Text(kp.title).font(.subheadline.weight(.semibold))
                                Text(kp.text).font(.caption).foregroundStyle(KA.Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(width: 150, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .card()
    }

    private func linesSection(_ o: Opening) -> some View {
        VStack(alignment: .leading, spacing: KA.Spacing.s) {
            Text("Main line").font(.headline)
            Button { previewLine = LinePreview(opening: o, line: o.mainLine, startPly: 0) } label: {
                Text(o.mainLineMovetext).font(.callout.monospaced()).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            if !o.keyVariations.isEmpty || !o.traps.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Variations & traps").font(.headline)
                ForEach(o.keyVariations + o.traps) { line in
                    lineRow(o, line)
                }
            }
            if !o.sidelines.isEmpty {
                DisclosureGroup("\(o.sidelines.count) named sidelines") {
                    ForEach(o.sidelines) { line in lineRow(o, line) }
                }
                .font(.subheadline)
            }
        }
        .card()
    }

    private func lineRow(_ o: Opening, _ line: OpeningLine) -> some View {
        Button { previewLine = LinePreview(opening: o, line: line, startPly: 0) } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(line.name).font(.subheadline.weight(.medium))
                        if line.kind == .trap { Tag(text: "Trap", tint: KA.Palette.danger) }
                    }
                    Text(Notation.movetext(sans: line.moves, startPosition: .start))
                        .font(.caption.monospaced()).foregroundStyle(KA.Palette.textSecondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "play.circle").foregroundStyle(KA.Palette.accent)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func position(after sans: [String]) throws -> Position {
        var p = Position.start
        for s in sans { p = try p.playing(san: s) }
        return p
    }
}

// MARK: - Depth picker

struct DepthPickerSheet: View {
    let opening: Opening
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var settings: DepthSettings = .beginner
    @State private var side: PieceColor = .white
    @State private var loaded = false

    private var plan: StudyPlan { StudyPlanBuilder.build(opening: opening, settings: settings, side: side) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Depth", selection: Binding(get: { settings.preset }, set: { setPreset($0) })) {
                        ForEach(DepthPreset.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.preset.blurb).font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
                }
                if settings.preset == .custom {
                    Section("Custom depth") {
                        Stepper("Depth: \(settings.maxPly) plies (\((settings.maxPly + 1) / 2) moves)", value: $settings.maxPly, in: 4...40, step: 2)
                        Stepper("Variations: \(settings.maxVariations)", value: $settings.maxVariations, in: 1...30)
                        Toggle("Include rare sidelines", isOn: $settings.includeRareSidelines)
                        Toggle("Prioritise tactical traps", isOn: $settings.prioritizeTraps)
                        Toggle("Engine evaluation & analysis", isOn: $settings.includeEngineAnalysis)
                        Text("A ply is one move by either White or Black.").font(.caption).foregroundStyle(KA.Palette.textSecondary)
                    }
                }
                Section("Learn as") {
                    Picker("Side", selection: $side) {
                        Text("White").tag(PieceColor.white)
                        Text("Black").tag(PieceColor.black)
                    }
                    .pickerStyle(.segmented)
                    if side != opening.side {
                        Text("You will learn the responses from the other side of the board.")
                            .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                    }
                }
                Section("Your study plan") {
                    let p = plan
                    LabeledContent("Lines", value: "\(p.lines.count)")
                    LabeledContent("Moves to learn", value: "\(p.cards.count)")
                    LabeledContent("Deepest line", value: "\(p.maxDepthPlies) plies")
                    LabeledContent("Estimated time", value: "~\(p.estimatedMinutes) min")
                    ForEach(p.lines) { l in
                        HStack {
                            Text(l.line.name).font(.subheadline)
                            Spacer()
                            Tag(text: l.line.kind.displayName, tint: l.line.kind == .trap ? KA.Palette.danger : KA.Palette.info)
                        }
                    }
                }
                Section {
                    Text("Changing the depth later keeps all progress — each move's review history is stored separately.")
                        .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                }
            }
            .navigationTitle(opening.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.course(for: opening.id) == nil ? "Start" : "Save") {
                        let isNew = model.course(for: opening.id) == nil
                        model.startCourse(opening, settings: settings, side: side)
                        dismiss()
                        if isNew {
                            router.push(.trainer(openingID: opening.id, mode: .learn, side: side, startNode: MoveTree.rootID))
                        }
                    }
                    .bold()
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let c = model.course(for: opening.id) {
                    settings = c.settings
                    side = c.side
                } else {
                    settings = .forPreset(model.settings.level == .beginner ? .beginner : model.settings.level == .intermediate ? .intermediate : .advanced)
                    side = opening.side
                }
            }
        }
    }

    private func setPreset(_ p: DepthPreset) {
        if p == .custom {
            settings.preset = .custom
        } else {
            settings = .forPreset(p)
        }
    }
}

// MARK: - Line viewer

struct LinePreview: Identifiable {
    let opening: Opening
    let line: OpeningLine
    let startPly: Int
    var id: String { "\(line.id)-\(startPly)" }
}

/// Steps through a single line with annotations (used for traps, sidelines and key positions).
struct LineViewerSheet: View {
    let preview: LinePreview
    @Environment(\.dismiss) private var dismiss
    @State private var ply = 0

    private var positions: [Position] {
        var out = [Position.start]
        var p = Position.start
        for s in preview.line.moves {
            guard let next = try? p.playing(san: s) else { break }
            p = next
            out.append(p)
        }
        return out
    }

    var body: some View {
        let positions = self.positions
        let maxPly = positions.count - 1
        let lastMove: Move? = ply > 0 ? (try? positions[ply - 1].move(fromSAN: preview.line.moves[ply - 1])) : nil
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: KA.Spacing.m) {
                    ChessBoardView(display: BoardDisplay(position: positions[min(ply, maxPly)],
                                                         orientation: preview.line.trapper ?? preview.opening.side,
                                                         lastMove: lastMove, interactive: false))
                    HStack {
                        Button { ply = 0 } label: { Image(systemName: "backward.end.fill") }
                        Spacer()
                        Button { ply = max(0, ply - 1) } label: { Image(systemName: "chevron.left").font(.title2) }
                        Spacer()
                        Text(ply == 0 ? "Start" : "\(Notation.moveNumberLabel(ply: ply - 1))\(preview.line.moves[ply - 1])")
                            .font(.headline.monospaced())
                        Spacer()
                        Button { ply = min(maxPly, ply + 1) } label: { Image(systemName: "chevron.right").font(.title2) }
                        Spacer()
                        Button { ply = maxPly } label: { Image(systemName: "forward.end.fill") }
                    }
                    .padding(.horizontal)
                    if ply > 0, let note = preview.line.note(atPly: ply) {
                        FeedbackBanner(kind: .info, text: note)
                    } else if ply > 0, let m = lastMove {
                        Text(MoveExplainer.explain(m, in: positions[ply - 1]).text)
                            .font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
                    }
                    if !preview.line.description.isEmpty {
                        Text(preview.line.description).font(.body)
                    }
                    Text(Notation.movetext(sans: preview.line.moves, startPosition: .start))
                        .font(.callout.monospaced()).foregroundStyle(KA.Palette.textSecondary)
                }
                .padding()
            }
            .navigationTitle(preview.line.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { ply = min(preview.startPly, maxPly) }
        }
    }
}
