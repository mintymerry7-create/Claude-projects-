import SwiftUI

struct CalculatorView: View {
    @EnvironmentObject private var store: Store
    @State private var bgText = ""
    @State private var takenText = ""
    @State private var showSaved = false
    @FocusState private var focused: Bool

    private var unit: GlucoseUnit { store.settings.unit }
    private var bgMgdl: Double? { Double(parsing: bgText).map(unit.toMgdl) }
    private var carbs: Double { Double(parsing: store.draftCarbs) ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                if store.settings.isComplete {
                    inputs
                    dose(BolusCalculator.calculate(
                        carbs: carbs,
                        bgMgdl: bgMgdl,
                        iob: store.insulinOnBoard(),
                        settings: store.settings
                    ))
                } else {
                    Section {
                        Text("Add your carb ratio, correction factor and target glucose in Settings first. Use the numbers from your diabetes team.")
                        Button("Open Settings") { store.selectedTab = .settings }
                    }
                }
            }
            .navigationTitle("Dose")
            .keyboardDoneButton($focused)
            .alert("Saved to log", isPresented: $showSaved) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private var inputs: some View {
        Section("Now") {
            NumberRow(title: "Glucose", unit: unit.rawValue, text: $bgText, focus: $focused)
            NumberRow(title: "Carbs", unit: "g", text: $store.draftCarbs, focus: $focused)
            if !store.draftMealName.isEmpty {
                Text(store.draftMealName).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Insulin on board", value: "\(Fmt.units(store.insulinOnBoard())) u")
        }
    }

    @ViewBuilder
    private func dose(_ r: BolusResult) -> some View {
        if r.isLow {
            Section {
                Label("Low glucose", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("Treat the low first: about 15 g of fast-acting carbs, then recheck in 15 minutes. Follow your hypo plan.")
            }
        }

        Section("Suggested dose") {
            LabeledContent("For carbs", value: "\(Fmt.units(r.carbDose)) u")
            LabeledContent("Correction", value: "\(Fmt.signedUnits(r.correction)) u")
            if r.iobUsed > 0 {
                LabeledContent("Insulin on board", value: "−\(Fmt.units(r.iobUsed)) u")
            }
            HStack {
                Text("Total").font(.headline)
                Spacer()
                Text("\(Fmt.units(r.rounded)) u")
                    .font(.largeTitle.bold())
                    .foregroundStyle(r.isLow ? Color.red : Color.primary)
            }
            Text("Exact \(Fmt.units(r.raw, digits: 2)) u, rounded down to the nearest \(Fmt.units(store.settings.roundingStep)) u.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !r.warnings.isEmpty {
            Section {
                ForEach(r.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
        }

        Section {
            NumberRow(title: "Dose taken", unit: "u", text: $takenText, placeholder: Fmt.units(r.rounded), focus: $focused)
            Button("Save to log") { save(r) }
                .disabled(bgMgdl == nil && carbs == 0 && taken(r) == 0)
        } footer: {
            Text("Check every number before you inject.")
        }
    }

    private func taken(_ r: BolusResult) -> Double {
        Double(parsing: takenText) ?? r.rounded
    }

    private func save(_ r: BolusResult) {
        let now = Date()
        let units = taken(r)
        if let bg = bgMgdl {
            store.glucose.append(GlucoseEntry(date: now, mgdl: bg))
        }
        if carbs > 0 {
            let name = store.draftMealName.isEmpty ? "Meal" : store.draftMealName
            store.meals.append(MealEntry(date: now, name: name, carbs: carbs, calories: store.draftCalories))
        }
        if units > 0 {
            store.insulin.append(InsulinEntry(date: now, units: units, kind: .rapid))
        }
        bgText = ""
        takenText = ""
        store.clearDraft()
        focused = false
        showSaved = true
    }
}
