import SwiftUI
import Learning
import AppFeatures

/// Change the product name in one place.
enum AppInfo {
    static let name = "Knight Academy"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
}

@main
struct KnightAcademyApp: App {
    @State private var model: AppModel
    @State private var router = Router()
    private let engines: StockfishEngineProvider

    init() {
        // UI tests start from a clean, throw-away profile.
        let url = ProcessInfo.processInfo.arguments.contains("-uitest-reset")
            ? FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(UUID().uuidString)/userdata.json")
            : UserDataStore.defaultURL()
        let store = UserDataStore(url: url)
        let provider = StockfishEngineProvider()
        provider.preferStockfish = store.data.settings.preferStockfish
        engines = provider
        _model = State(initialValue: AppModel(store: store, engines: provider))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .tint(KA.Palette.accent)
                .onAppear(perform: applySettings)
                .onChange(of: model.settings) { _, _ in applySettings() }
        }
    }

    private func applySettings() {
        Feedback.hapticsEnabled = model.settings.hapticsEnabled
        Feedback.soundEnabled = model.settings.soundEnabled
        engines.preferStockfish = model.settings.preferStockfish
    }
}
