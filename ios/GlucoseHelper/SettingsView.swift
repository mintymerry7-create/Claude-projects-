import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    private var unit: String { store.settings.unit.rawValue }

    var body: some View {
        NavigationStack {
            Form {
                Section("Glucose unit") {
                    Picker("Unit", selection: $store.settings.unit) {
                        ForEach(GlucoseUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    SettingField(title: "Carb ratio", suffix: "g per 1 u", value: $store.settings.carbRatio, focus: $focused)
                    SettingField(title: "Correction factor", suffix: "\(unit) per 1 u", value: glucose(\.correctionFactor), focus: $focused)
                    SettingField(title: "Target", suffix: unit, value: glucose(\.targetMgdl), focus: $focused)
                } header: {
                    Text("Your ratios")
                } footer: {
                    Text("Use the numbers from your diabetes team. Carb ratio: grams of carbs covered by 1 unit. Correction factor: how much 1 unit lowers your glucose.")
                }

                Section("Range") {
                    SettingField(title: "Low below", suffix: unit, value: glucose(\.lowMgdl), focus: $focused)
                    SettingField(title: "High above", suffix: unit, value: glucose(\.highMgdl), focus: $focused)
                }

                Section {
                    Stepper(
                        "Active insulin time: \(Fmt.units(store.settings.insulinDurationHours)) h",
                        value: $store.settings.insulinDurationHours,
                        in: 2...8,
                        step: 0.5
                    )
                    Picker("Round doses to", selection: $store.settings.roundingStep) {
                        Text("0.1 u").tag(0.1)
                        Text("0.5 u").tag(0.5)
                        Text("1 u").tag(1.0)
                    }
                    SettingField(title: "Max single dose", suffix: "u", value: $store.settings.maxBolus, focus: $focused)
                } header: {
                    Text("Rapid insulin")
                } footer: {
                    Text("Active insulin time is how long your rapid insulin keeps working. It's used to estimate insulin on board.")
                }

                Section {
                    Button("Delete all log data", role: .destructive) { confirmDelete = true }
                }

                Section("About") {
                    Text(disclaimerText).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .keyboardDoneButton($focused)
            .confirmationDialog("Delete all glucose, insulin and meal entries?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { store.deleteLogs() }
            }
        }
    }

    /// Shows a mg/dL setting in the chosen unit.
    private func glucose(_ key: WritableKeyPath<Settings, Double>) -> Binding<Double> {
        Binding(
            get: { store.settings.unit.fromMgdl(store.settings[keyPath: key]) },
            set: { store.settings[keyPath: key] = store.settings.unit.toMgdl($0) }
        )
    }
}

private struct SettingField: View {
    let title: String
    let suffix: String
    @Binding var value: Double
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack {
            Text(title)
            TextField("0", value: $value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused(focus)
            Text(suffix).font(.caption).foregroundStyle(.secondary)
        }
    }
}
