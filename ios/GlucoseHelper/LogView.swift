import Charts
import SwiftUI

private enum LogEntry: Identifiable {
    case glucose(GlucoseEntry)
    case insulin(InsulinEntry)
    case meal(MealEntry)

    var id: UUID {
        switch self {
        case .glucose(let e): return e.id
        case .insulin(let e): return e.id
        case .meal(let e): return e.id
        }
    }

    var date: Date {
        switch self {
        case .glucose(let e): return e.date
        case .insulin(let e): return e.date
        case .meal(let e): return e.date
        }
    }
}

private enum LogSheet: String, Identifiable {
    case glucose, insulin
    var id: String { rawValue }
}

struct LogView: View {
    @EnvironmentObject private var store: Store
    @State private var days = 1
    @State private var sheet: LogSheet?

    private var settings: Settings { store.settings }
    private var unit: GlucoseUnit { settings.unit }

    private var start: Date {
        days == 1
            ? Calendar.current.startOfDay(for: .now)
            : Date.now.addingTimeInterval(-Double(days) * 86_400)
    }

    private var readings: [GlucoseEntry] {
        store.glucose.filter { $0.date >= start }.sorted { $0.date < $1.date }
    }

    private var entries: [LogEntry] {
        let all = store.glucose.map(LogEntry.glucose)
            + store.insulin.map(LogEntry.insulin)
            + store.meals.map(LogEntry.meal)
        return all.filter { $0.date >= start }.sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Range", selection: $days) {
                        Text("Today").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }
                    .pickerStyle(.segmented)
                    GlucoseChart(readings: readings, settings: settings)
                }
                statsSection
                Section("Entries") {
                    if entries.isEmpty {
                        Text("Nothing logged yet.").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        EntryRow(entry: entry, settings: settings)
                    }
                    .onDelete(perform: delete)
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Glucose reading", systemImage: "drop") { sheet = .glucose }
                        Button("Insulin dose", systemImage: "syringe") { sheet = .insulin }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $sheet) { kind in
                switch kind {
                case .glucose: AddGlucoseView().environmentObject(store)
                case .insulin: AddInsulinView().environmentObject(store)
                }
            }
        }
    }

    private var statsSection: some View {
        let values = readings.map(\.mgdl)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let inRange = values.filter { $0 >= settings.lowMgdl && $0 <= settings.highMgdl }.count
        let lows = values.filter { $0 < settings.lowMgdl }.count
        let insulinTotal = store.insulin.filter { $0.date >= start }.reduce(0) { $0 + $1.units }
        let carbTotal = store.meals.filter { $0.date >= start }.reduce(0) { $0 + $1.carbs }

        return Section("Summary") {
            LabeledContent("Average glucose", value: average.map { "\(unit.format($0)) \(unit.rawValue)" } ?? "–")
            LabeledContent("Time in range", value: values.isEmpty ? "–" : "\(inRange * 100 / values.count)%")
            LabeledContent("Lows", value: "\(lows)")
            LabeledContent("Insulin", value: "\(Fmt.units(insulinTotal)) u")
            LabeledContent("Carbs", value: "\(Fmt.grams(carbTotal)) g")
        }
    }

    private func delete(at offsets: IndexSet) {
        let list = entries
        for index in offsets {
            switch list[index] {
            case .glucose(let e): store.glucose.removeAll { $0.id == e.id }
            case .insulin(let e): store.insulin.removeAll { $0.id == e.id }
            case .meal(let e): store.meals.removeAll { $0.id == e.id }
            }
        }
    }
}

private struct GlucoseChart: View {
    let readings: [GlucoseEntry]
    let settings: Settings

    var body: some View {
        let unit = settings.unit
        if readings.isEmpty {
            Text("No readings in this range.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Chart {
                RuleMark(y: .value("Low", unit.fromMgdl(settings.lowMgdl)))
                    .foregroundStyle(Color.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                RuleMark(y: .value("High", unit.fromMgdl(settings.highMgdl)))
                    .foregroundStyle(Color.orange.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                ForEach(readings) { reading in
                    LineMark(
                        x: .value("Time", reading.date),
                        y: .value("Glucose", unit.fromMgdl(reading.mgdl))
                    )
                    .foregroundStyle(Color.gray.opacity(0.5))
                    PointMark(
                        x: .value("Time", reading.date),
                        y: .value("Glucose", unit.fromMgdl(reading.mgdl))
                    )
                    .foregroundStyle(GlucoseColor.color(reading.mgdl, settings))
                }
            }
            .frame(height: 200)
        }
    }
}

private struct EntryRow: View {
    let entry: LogEntry
    let settings: Settings

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 24)
            VStack(alignment: .leading) {
                Text(title)
                Text(entry.date, format: .dateTime.weekday().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch entry {
        case .glucose(let e):
            Image(systemName: "drop.fill").foregroundStyle(GlucoseColor.color(e.mgdl, settings))
        case .insulin:
            Image(systemName: "syringe.fill").foregroundStyle(.blue)
        case .meal:
            Image(systemName: "fork.knife").foregroundStyle(.brown)
        }
    }

    private var title: String {
        switch entry {
        case .glucose(let e):
            let text = "\(settings.unit.format(e.mgdl)) \(settings.unit.rawValue)"
            return e.note.isEmpty ? text : "\(text) · \(e.note)"
        case .insulin(let e):
            return "\(Fmt.units(e.units)) u \(e.kind.rawValue.lowercased())"
        case .meal(let e):
            return "\(e.name) · \(Fmt.grams(e.carbs)) g carbs · \(Fmt.grams(e.calories)) kcal"
        }
    }
}

private struct AddGlucoseView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var note = ""
    @State private var date = Date.now
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                NumberRow(title: "Glucose", unit: store.settings.unit.rawValue, text: $value, focus: $focused)
                DatePicker("Time", selection: $date)
                TextField("Note (optional)", text: $note)
            }
            .navigationTitle("Glucose reading")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton($focused)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let v = Double(parsing: value) else { return }
                        store.glucose.append(GlucoseEntry(date: date, mgdl: store.settings.unit.toMgdl(v), note: note))
                        dismiss()
                    }
                    .disabled(Double(parsing: value) == nil)
                }
            }
        }
    }
}

private struct AddInsulinView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var units = ""
    @State private var kind = InsulinKind.rapid
    @State private var date = Date.now
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                NumberRow(title: "Dose", unit: "u", text: $units, focus: $focused)
                Picker("Type", selection: $kind) {
                    ForEach(InsulinKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker("Time", selection: $date)
            }
            .navigationTitle("Insulin dose")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton($focused)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let u = Double(parsing: units), u > 0 else { return }
                        store.insulin.append(InsulinEntry(date: date, units: u, kind: kind))
                        dismiss()
                    }
                    .disabled((Double(parsing: units) ?? 0) <= 0)
                }
            }
        }
    }
}
