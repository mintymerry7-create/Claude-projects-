import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ChessCore
import OpeningDatabase
import Learning
import AppFeatures

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var showNewRepertoire = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 52)).foregroundStyle(KA.Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.settings.playerName.isEmpty ? "Chess learner" : model.settings.playerName).font(.title3.bold())
                        Text("\(model.settings.level.displayName) · member since \(model.data.createdAt.formatted(.dateTime.month().year()))")
                            .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
            Section("Statistics") {
                let puzzles = model.puzzleStats
                let record = model.gameRecord
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    StatTile(value: "\(model.streak)", label: "day streak", symbol: "flame.fill", tint: .orange)
                    StatTile(value: "\(Int((model.overallMastery * 100).rounded()))%", label: "opening mastery", symbol: "book")
                    StatTile(value: "\(puzzles.solved)", label: "puzzles solved", symbol: "puzzlepiece")
                    StatTile(value: "\(record.wins)-\(record.draws)-\(record.losses)", label: "games W-D-L", symbol: "checkerboard.rectangle")
                    StatTile(value: "\(model.data.reviews.count)", label: "moves tracked", symbol: "arrow.triangle.2.circlepath")
                    StatTile(value: "\(model.data.lessons.values.filter(\.completed).count)", label: "lessons completed", symbol: "graduationcap")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(model.data.repertoires) { r in
                    NavigationLink(value: Route.repertoire(r.id)) {
                        HStack(spacing: 10) {
                            SideBadge(isWhite: r.color == .white)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(.body.weight(.medium))
                                Text("\(r.lineCount) line\(r.lineCount == 1 ? "" : "s") · \(r.cards.count) moves")
                                    .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                            }
                        }
                    }
                }
                .onDelete { idx in
                    let ids = idx.map { model.data.repertoires[$0].id }
                    ids.forEach(model.deleteRepertoire)
                }
                Button { showNewRepertoire = true } label: { Label("New repertoire", systemImage: "plus") }
            } header: {
                Text("Repertoires")
            } footer: {
                Text("Build your own lines for White and Black, add notes, import PGN and drill them with spaced repetition.")
            }
            Section("More") {
                NavigationLink(value: Route.gameHistory) { Label("Game history", systemImage: "clock.arrow.circlepath") }
                NavigationLink(value: Route.bookmarks) { Label("Bookmarks", systemImage: "bookmark") }
                NavigationLink(value: Route.curriculum) { Label("Fundamentals course", systemImage: "graduationcap") }
                NavigationLink(value: Route.settings) { Label("Settings", systemImage: "gearshape") }
                NavigationLink(value: Route.about) { Label("About & licences", systemImage: "info.circle") }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Profile")
        .sheet(isPresented: $showNewRepertoire) {
            NewRepertoireSheet { id in router.push(.repertoire(id)) }
        }
    }
}

struct NewRepertoireSheet: View {
    var onCreate: (UUID) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: PieceColor = .white
    @State private var useFEN = false
    @State private var fen = ""
    @State private var openingID: String?
    @State private var showOpeningPicker = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. \"My 1.e4 repertoire\"", text: $name)
                    Picker("Colour", selection: $color) {
                        Text("White").tag(PieceColor.white)
                        Text("Black").tag(PieceColor.black)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Toggle("Start from a FEN position", isOn: $useFEN)
                    if useFEN {
                        TextField("FEN", text: $fen, axis: .vertical)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        Button {
                            showOpeningPicker = true
                        } label: {
                            HStack {
                                Text("Start with an opening")
                                Spacer()
                                Text(openingID.flatMap { model.db.opening(id: $0)?.name } ?? "Optional")
                                    .foregroundStyle(KA.Palette.textSecondary)
                            }
                        }
                    }
                } footer: {
                    Text(useFEN ? "Useful for studying a specific middlegame or endgame position." : "You can add more openings and your own moves later.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(KA.Palette.danger) }
                }
            }
            .navigationTitle("New repertoire")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showOpeningPicker) {
                OpeningPickerSheet(selection: $openingID, side: color)
            }
        }
    }

    private func create() {
        do {
            var r = try model.createRepertoire(name: name.trimmingCharacters(in: .whitespaces), color: color,
                                               fen: useFEN ? fen.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
            if !useFEN, let o = openingID.flatMap(model.db.opening(id:)) {
                try r.add(opening: o)
                model.save(repertoire: r)
            }
            dismiss()
            onCreate(r.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Paste or pick a .pgn file, then import it.
struct PGNImportSheet: View {
    let title: String
    /// Returns a success message or throws a readable error.
    let onImport: (String) throws -> String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var message: String?
    @State private var isError = false
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.callout.monospaced())
                        .frame(minHeight: 200)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Paste PGN")
                } footer: {
                    Text("Variations in parentheses, comments in braces and several games in one file are supported.")
                }
                Section {
                    Button { showFilePicker = true } label: { Label("Choose a .pgn file", systemImage: "doc") }
                    if UIPasteboard.general.hasStrings {
                        Button { text = UIPasteboard.general.string ?? "" } label: { Label("Paste from clipboard", systemImage: "doc.on.clipboard") }
                    }
                }
                if let message {
                    Section { Text(message).foregroundStyle(isError ? KA.Palette.danger : KA.Palette.accent) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            message = try onImport(text)
                            isError = false
                            Feedback.success()
                        } catch {
                            message = error.localizedDescription
                            isError = true
                            Feedback.error()
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.plainText, .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                        text = s
                    } else {
                        message = "The file could not be read as text."
                        isError = true
                    }
                case .failure(let e):
                    message = e.localizedDescription
                    isError = true
                }
            }
        }
    }
}

struct BookmarksView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        List {
            if model.data.bookmarks.isEmpty {
                ContentUnavailableView("No bookmarks", systemImage: "bookmark",
                                       description: Text("Bookmark positions from the variation explorer or while training."))
            }
            ForEach(model.data.bookmarks.reversed()) { b in
                Button {
                    if let id = b.openingID { router.push(.explorer(openingID: id)) }
                } label: {
                    HStack(spacing: 12) {
                        BoardThumbnail(position: position(b.sans), theme: model.settings.boardTheme).frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).font(.subheadline.weight(.medium))
                            Text(Notation.movetext(sans: b.sans, startPosition: .start))
                                .font(.caption.monospaced()).foregroundStyle(KA.Palette.textSecondary).lineLimit(2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) { model.removeBookmark(b.id) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Bookmarks")
    }

    private func position(_ sans: [String]) -> Position {
        var p = Position.start
        for s in sans { if let n = try? p.playing(san: s) { p = n } }
        return p
    }
}
