import SwiftUI
import ChessCore
import OpeningDatabase
import Learning
import AppFeatures

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Your name", text: binding(\.playerName))
                Picker("Level", selection: binding(\.level)) {
                    ForEach(Difficulty.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper("Daily goal: \(model.settings.dailyGoal) moves", value: binding(\.dailyGoal), in: 5...200, step: 5)
            }
            Section("Appearance") {
                Picker("Theme", selection: binding(\.appearance)) {
                    ForEach(AppearanceSetting.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Board", selection: binding(\.boardTheme)) {
                    ForEach(BoardTheme.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                BoardThumbnail(position: try! Position(fen: "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3"),
                               lastMove: Move(uci: "f1c4"), theme: model.settings.boardTheme)
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                Toggle("Board coordinates", isOn: binding(\.showCoordinates))
                Toggle("Show legal moves", isOn: binding(\.showLegalMoves))
                Toggle("Animate moves", isOn: binding(\.animateMoves))
            }
            Section("Feedback") {
                Toggle("Haptics", isOn: binding(\.hapticsEnabled))
                Toggle("Move sounds", isOn: binding(\.soundEnabled))
            }
            Section {
                Toggle("Use Stockfish when available", isOn: binding(\.preferStockfish))
                LabeledContent("Current engine", value: model.engines.engineName)
            } header: {
                Text("Engine")
            } footer: {
                Text(model.engines.isStockfishAvailable
                     ? "Stockfish 17 runs on-device. Turning it off uses the lighter built-in engine."
                     : "Stockfish network files are not bundled in this build, so the built-in engine is used.")
            }
            Section {
                ShareLink(item: exportData(), preview: SharePreview("Knight Academy progress")) {
                    Label("Export my data (JSON)", systemImage: "square.and.arrow.up")
                }
                Button("Reset all progress", role: .destructive) { confirmReset = true }
            } header: {
                Text("Data")
            } footer: {
                Text("Everything is stored on this device only. No account, no tracking.")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Reset all progress?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                model.store.reset()
                model.update { _ in }
            }
        } message: {
            Text("Reviews, courses, games, repertoires and lesson progress will be deleted. Settings are kept.")
        }
    }

    private func exportData() -> String {
        guard let raw = try? Data(contentsOf: model.store.url), let s = String(data: raw, encoding: .utf8) else { return "{}" }
        return s
    }
}

struct AboutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppInfo.name).font(.title2.bold())
                    Text("Version \(AppInfo.version)").foregroundStyle(KA.Palette.textSecondary)
                    Text("\(model.db.openings.count) openings · \(model.db.openings.reduce(0) { $0 + $1.lines.count }) lines · \(model.curriculum.allLessons.count) lessons · \(model.puzzles.count) puzzles")
                        .font(.caption).foregroundStyle(KA.Palette.textSecondary)
                }
            }
            Section("Chess engine") {
                licence("Stockfish 17", "GNU General Public License v3. Stockfish is free software; the complete source code is available at github.com/official-stockfish/Stockfish. Because this app links Stockfish, distributing the app requires offering its source under the GPLv3.")
                licence("ChessKitEngine", "MIT License — Swift wrapper used to run Stockfish on iOS (github.com/chesskit-app/chesskit-engine).")
            }
            Section("Content") {
                licence("Opening names & ECO codes", "lichess-org/chess-openings, released under CC0 1.0 (public domain). Course text, extended lines and explanations were written for this app and every move sequence was checked for legality and soundness with Stockfish.")
                licence("Puzzles", "Generated from engine games and verified with Stockfish: every solution move is the only clearly winning move.")
                licence("Piece set", "\"cburnett\" by Colin M.L. Burnett, GPLv2+.")
            }
            Section("Privacy") {
                Text("No account, no ads, no analytics. All data stays on your device.").font(.subheadline)
            }
        }
        .navigationTitle("About")
    }

    private func licence(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(KA.Palette.textSecondary)
        }
        .padding(.vertical, 2)
    }
}
