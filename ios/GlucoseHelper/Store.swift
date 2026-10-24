import Foundation

@MainActor
final class Store: ObservableObject {
    @Published var settings = Settings() { didSet { save() } }
    @Published var glucose: [GlucoseEntry] = [] { didSet { save() } }
    @Published var insulin: [InsulinEntry] = [] { didSet { save() } }
    @Published var meals: [MealEntry] = [] { didSet { save() } }
    @Published var foods: [Food] = [] { didSet { save() } }

    // Not saved: a meal handed from the Food tab to the dose calculator.
    @Published var draftCarbs = ""
    @Published var draftMealName = ""
    @Published var draftCalories = 0.0
    @Published var selectedTab = AppTab.dose

    private struct Snapshot: Codable {
        var settings: Settings
        var glucose: [GlucoseEntry]
        var insulin: [InsulinEntry]
        var meals: [MealEntry]
        var foods: [Food]
    }

    private var loading = false
    private let url = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("data.json")

    init() {
        load()
    }

    /// Rapid insulin still active, assuming it wears off linearly over the active insulin time.
    func insulinOnBoard(at now: Date = .now) -> Double {
        let duration = settings.insulinDurationHours * 3600
        guard duration > 0 else { return 0 }
        return insulin.filter { $0.kind == .rapid }.reduce(0) { sum, entry in
            let elapsed = now.timeIntervalSince(entry.date)
            guard elapsed >= 0, elapsed < duration else { return sum }
            return sum + entry.units * (1 - elapsed / duration)
        }
    }

    func clearDraft() {
        draftCarbs = ""
        draftMealName = ""
        draftCalories = 0
    }

    func deleteLogs() {
        glucose = []
        insulin = []
        meals = []
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            foods = Food.starters
            return
        }
        loading = true
        settings = snapshot.settings
        glucose = snapshot.glucose
        insulin = snapshot.insulin
        meals = snapshot.meals
        foods = snapshot.foods
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let snapshot = Snapshot(settings: settings, glucose: glucose, insulin: insulin, meals: meals, foods: foods)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
