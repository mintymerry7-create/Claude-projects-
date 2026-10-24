import SwiftUI
import ChessCore
import ChessEngine
import OpeningDatabase
import Learning
import AppFeatures

struct RepertoireEditorScreen: View {
    let repertoireID: UUID
    @Environment(AppModel.self) private var model
    @State private var editor: RepertoireEditor?

    var body: some View {
        Group {
            if let editor {
                RepertoireEditorView(editor: editor)
            } else {
                ContentUnavailableView("Repertoire not found", systemImage: "list.bullet.indent")
            }
        }
        .task { if editor == nil { editor = model.makeRepertoireEditor(repertoireID) } }
    }
}

struct RepertoireEditorView: View {
    let editor: RepertoireEditor
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var noteText = ""
    @State private var showImport = false
    @State private var showAddOpening = false
    @State private var addOpeningID: String?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KA.Spacing.m) {
                breadcrumbs
                ChessBoardView(display: editor.display) { move in editor.play(move) }
                navigation
                Text(editor.isOwnMove
                     ? "Your move: play the move you want in your repertoire. Existing moves are shown with arrows."
                     : "Opponent's move: add every reply you want to be prepared for.")
                    .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                if let e = editor.errorMessage { FeedbackBanner(kind: .error, text: e) }
                childrenList
                noteEditor
                practiceButtons
            }
            .padding(KA.Spacing.l)
        }
        .screenBackground()
        .navigationTitle(editor.repertoire.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showAddOpening = true } label: { Label("Add opening from library", systemImage: "book") }
                        .disabled(!editor.repertoire.isFromStandardStart)
                    Button { showImport = true } label: { Label("Import PGN", systemImage: "square.and.arrow.down") }
                    ShareLink(item: editor.exportPGN(), preview: SharePreview(editor.repertoire.name)) {
                        Label("Export PGN", systemImage: "square.and.arrow.up")
                    }
                    Button { newName = editor.repertoire.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Repertoire options")
            }
        }
        .sheet(isPresented: $showImport) {
            PGNImportSheet(title: "Import into repertoire") { text in
                guard let n = editor.importPGN(text) else {
                    throw RepertoireImportFailure(message: editor.errorMessage ?? "Import failed.")
                }
                return "Added \(n) new position\(n == 1 ? "" : "s")."
            }
        }
        .sheet(isPresented: $showAddOpening) {
            OpeningPickerSheet(selection: $addOpeningID, side: editor.repertoire.color)
        }
        .onChange(of: addOpeningID) { _, id in
            if let o = id.flatMap(model.db.opening(id:)) {
                editor.add(opening: o)
                addOpeningID = nil
            }
        }
        .onChange(of: editor.nodeID) { _, _ in noteText = editor.node.comment ?? "" }
        .onAppear { noteText = editor.node.comment ?? "" }
        .alert("Rename repertoire", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { editor.rename(newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this move and everything after it?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { editor.deleteCurrent() }
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("Start") { editor.toStart() }.font(.caption.weight(.semibold))
                ForEach(editor.tree.path(to: editor.nodeID), id: \.self) { id in
                    let n = editor.tree[id]
                    Button {
                        editor.goTo(id)
                    } label: {
                        Text("\(n.ply % 2 == 1 ? "\((n.ply + 1) / 2). " : "")\(n.san)")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(id == editor.nodeID ? KA.Palette.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var navigation: some View {
        HStack {
            ToolButton(title: "Start", symbol: "backward.end") { editor.toStart() }
            ToolButton(title: "Back", symbol: "chevron.left") { editor.back() }
            ToolButton(title: "Forward", symbol: "chevron.right") { editor.forward() }
            ToolButton(title: "Preferred", symbol: editor.repertoire.isPreferred(editor.nodeID) ? "star.fill" : "star") {
                editor.markPreferred()
                Feedback.selection()
            }
            .disabled(editor.nodeID == MoveTree.rootID)
            ToolButton(title: "Delete", symbol: "trash", role: .destructive) { confirmDelete = true }
                .disabled(editor.nodeID == MoveTree.rootID)
        }
        .card(padding: 6)
    }

    @ViewBuilder private var childrenList: some View {
        if !editor.children.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(editor.isOwnMove ? "Your moves here" : "Prepared replies to").font(.headline)
                ForEach(editor.children) { child in
                    Button { editor.goTo(child.id) } label: {
                        HStack {
                            Text(child.san).font(.headline.monospaced())
                            if editor.repertoire.isPreferred(child.id) || child.id == editor.node.children.first {
                                Image(systemName: "star.fill").font(.caption).foregroundStyle(KA.Palette.gold)
                            }
                            if let c = child.comment {
                                Text(c).font(.caption).foregroundStyle(KA.Palette.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(child.children.count) →").font(.caption).foregroundStyle(KA.Palette.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .card()
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Note on this move").font(.headline)
            TextField("Plans, ideas, reminders…", text: $noteText, axis: .vertical)
                .lineLimit(2...5)
                .padding(10)
                .background(KA.Palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                .disabled(editor.nodeID == MoveTree.rootID)
            Button("Save note") { editor.setNote(noteText) }
                .font(.subheadline.weight(.semibold))
                .disabled(editor.nodeID == MoveTree.rootID || noteText == (editor.node.comment ?? ""))
        }
        .card()
    }

    private var practiceButtons: some View {
        let rep = editor.repertoire
        return VStack(spacing: KA.Spacing.s) {
            HStack(spacing: KA.Spacing.s) {
                Button { router.push(.repertoireTrainer(rep.id, .learn)) } label: { Label("Learn", systemImage: "book") }
                    .buttonStyle(.secondary)
                Button { router.push(.repertoireTrainer(rep.id, .memory)) } label: { Label("Flashcards", systemImage: "rectangle.on.rectangle") }
                    .buttonStyle(.secondary)
            }
            .disabled(rep.tree.count < 2 || !rep.isFromStandardStart)
            Button {
                var setup = GameSetup(bot: .intermediate, playerColor: rep.color, bookName: rep.name)
                if rep.isFromStandardStart {
                    setup.book = rep.tree
                    setup.playerBook = rep.tree
                } else {
                    setup.startFEN = rep.tree.root.fen
                }
                router.push(.game(setup))
            } label: { Label("Play it against a bot", systemImage: "cpu") }
            .buttonStyle(.primary)
        }
    }
}

struct RepertoireImportFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
