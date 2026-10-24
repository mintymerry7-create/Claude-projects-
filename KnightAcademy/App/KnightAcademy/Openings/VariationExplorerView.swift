import SwiftUI
import ChessCore
import OpeningDatabase
import Learning
import AppFeatures

/// Navigable move tree of a study plan: main line, branches, previews,
/// explanations, personal notes, bookmarks and "practise from here".
struct VariationExplorerView: View {
    let openingID: String
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var nodeID = MoveTree.rootID
    @State private var showNotes = false
    @State private var useAdvanced = false

    private var plan: StudyPlan? {
        guard let o = model.db.opening(id: openingID) else { return nil }
        if useAdvanced || model.course(for: openingID) == nil {
            return StudyPlanBuilder.build(opening: o, settings: .advanced, side: model.course(for: openingID)?.side)
        }
        return model.plan(for: openingID)
    }

    var body: some View {
        if let plan {
            content(plan)
        } else {
            ContentUnavailableView("Opening not found", systemImage: "questionmark.folder")
        }
    }

    private func content(_ plan: StudyPlan) -> some View {
        let tree = plan.tree
        let node = tree[min(nodeID, tree.count - 1)]
        let position = tree.position(at: node.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                if model.course(for: openingID) != nil {
                    Picker("Tree", selection: $useAdvanced) {
                        Text("My study plan").tag(false)
                        Text("Full theory").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: useAdvanced) { _, _ in nodeID = MoveTree.rootID }
                }
                breadcrumbs(tree, node)
                ChessBoardView(display: BoardDisplay(position: position, orientation: plan.learnerSide, lastMove: node.move,
                                                     arrows: arrows(tree, node), interactive: true)) { move in
                    if let child = tree.child(of: node.id, playing: move) {
                        nodeID = child
                    } else {
                        Feedback.error()
                    }
                }
                navigation(tree, node)
                explanation(plan, node, position)
                branches(plan, node)
                lineIndex(plan)
            }
            .padding(KA.Spacing.l)
        }
        .screenBackground()
        .navigationTitle("Variation explorer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showNotes = true } label: { Label("Note on this position", systemImage: "note.text") }
                    let sans = tree.sans(to: node.id)
                    if model.isBookmarked(openingID: openingID, sans: sans) {
                        Button {
                            if let b = model.data.bookmarks.first(where: { $0.openingID == openingID && $0.sans == sans }) {
                                model.removeBookmark(b.id)
                            }
                        } label: { Label("Remove bookmark", systemImage: "bookmark.slash") }
                    } else {
                        Button {
                            model.addBookmark(title: "\(plan.opening.name) · \(Notation.movetext(sans: Array(sans.suffix(2)), startPosition: .start))",
                                              openingID: openingID, sans: sans)
                            Feedback.success()
                        } label: { Label("Bookmark", systemImage: "bookmark") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More options")
            }
        }
        .sheet(isPresented: $showNotes) { PositionNoteSheet(position: position) }
    }

    private func arrows(_ tree: MoveTree, _ node: MoveTree.Node) -> [Arrow] {
        node.children.enumerated().compactMap { i, id in
            guard let m = tree[id].move else { return nil }
            return Arrow(from: m.from, to: m.to, kind: i == 0 ? .suggestion : .plan)
        }
    }

    private func breadcrumbs(_ tree: MoveTree, _ node: MoveTree.Node) -> some View {
        let path = tree.path(to: node.id)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("Start") { nodeID = MoveTree.rootID }
                    .font(.caption.weight(.semibold))
                ForEach(path, id: \.self) { id in
                    let n = tree[id]
                    Button {
                        nodeID = id
                    } label: {
                        Text("\(n.ply % 2 == 1 ? "\((n.ply + 1) / 2). " : "")\(n.san)")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(id == node.id ? KA.Palette.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func navigation(_ tree: MoveTree, _ node: MoveTree.Node) -> some View {
        HStack {
            ToolButton(title: "Start", symbol: "backward.end") { nodeID = MoveTree.rootID }
            ToolButton(title: "Back", symbol: "chevron.left") { if let p = node.parent { nodeID = p } }
            ToolButton(title: "Forward", symbol: "chevron.right") { if let c = node.children.first { nodeID = c } }
            ToolButton(title: "Practise", symbol: "brain") {
                router.push(.trainer(openingID: openingID, mode: .memory, side: nil, startNode: practiceNode(tree, node)))
            }
        }
        .card(padding: 6)
    }

    /// Practise from the nearest node that the learner's plan actually contains.
    private func practiceNode(_ tree: MoveTree, _ node: MoveTree.Node) -> Int {
        guard !useAdvanced, model.course(for: openingID) != nil else { return MoveTree.rootID }
        return node.id
    }

    @ViewBuilder private func explanation(_ plan: StudyPlan, _ node: MoveTree.Node, _ position: Position) -> some View {
        if let parent = node.parent, let move = node.move {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Notation.moveNumberLabel(ply: node.ply - 1))\(node.san)").font(.headline.monospaced())
                if let note = plan.notes[node.id] {
                    Text(note).font(.subheadline)
                } else {
                    Text(MoveExplainer.explain(move, in: plan.tree.position(at: parent)).text)
                        .font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
                }
                let lines = (plan.nodeLines[node.id] ?? []).compactMap { id in plan.lines.first { $0.id == id } }
                if !lines.isEmpty {
                    Text("In: " + lines.map(\.line.name).joined(separator: ", "))
                        .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                }
                let personal = model.note(for: position)
                if !personal.isEmpty {
                    Label(personal, systemImage: "note.text").font(.footnote).foregroundStyle(KA.Palette.info)
                }
            }
            .card()
        } else {
            Text("Starting position. Choose a move below or play one on the board.")
                .font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
        }
    }

    @ViewBuilder private func branches(_ plan: StudyPlan, _ node: MoveTree.Node) -> some View {
        let tree = plan.tree
        if !node.children.isEmpty {
            VStack(alignment: .leading, spacing: KA.Spacing.s) {
                Text(node.children.count == 1 ? "Continuation" : "\(node.children.count) continuations").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: KA.Spacing.m) {
                        ForEach(Array(node.children.enumerated()), id: \.element) { i, id in
                            let child = tree[id]
                            Button { nodeID = id } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    BoardThumbnail(position: tree.position(at: id), orientation: plan.learnerSide,
                                                   lastMove: child.move, theme: model.settings.boardTheme)
                                        .frame(width: 110, height: 110)
                                    HStack(spacing: 4) {
                                        Text(child.san).font(.subheadline.weight(.semibold).monospaced())
                                        if i == 0 { Tag(text: "Main") }
                                    }
                                    let names = (plan.nodeLines[id] ?? []).compactMap { lid in plan.lines.first { $0.id == lid }?.line.name }
                                    Text(names.first ?? "").font(.caption2).foregroundStyle(KA.Palette.textSecondary).lineLimit(2)
                                }
                                .frame(width: 110, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Play \(child.san)")
                        }
                    }
                }
            }
            .card()
        }
    }

    private func lineIndex(_ plan: StudyPlan) -> some View {
        VStack(alignment: .leading, spacing: KA.Spacing.s) {
            Text("Lines in this tree").font(.headline)
            ForEach(plan.lines) { l in
                Button { nodeID = l.leafNodeID } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.line.name).font(.subheadline.weight(.medium))
                            Text(Notation.movetext(sans: l.moves, startPosition: .start))
                                .font(.caption.monospaced()).foregroundStyle(KA.Palette.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Tag(text: l.line.kind.displayName, tint: l.line.kind == .trap ? KA.Palette.danger : KA.Palette.info)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }
}
