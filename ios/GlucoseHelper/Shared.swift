import SwiftUI

enum Fmt {
    static func units(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)))
    }

    static func signedUnits(_ value: Double) -> String {
        (value > 0 ? "+" : "") + units(value)
    }

    static func grams(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

extension Double {
    /// Accepts both "5.5" and "5,5".
    init?(parsing text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        self = value
    }
}

enum GlucoseColor {
    static func color(_ mgdl: Double, _ settings: Settings) -> Color {
        if mgdl < settings.lowMgdl { return .red }
        if mgdl > settings.highMgdl { return .orange }
        return .green
    }
}

struct NumberRow: View {
    let title: String
    let unit: String
    @Binding var text: String
    var placeholder = "0"
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack {
            Text(title)
            TextField(placeholder, text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused(focus)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}

struct KeyboardDoneButton: ViewModifier {
    var focus: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus.wrappedValue = false }
            }
        }
    }
}

extension View {
    func keyboardDoneButton(_ focus: FocusState<Bool>.Binding) -> some View {
        modifier(KeyboardDoneButton(focus: focus))
    }
}

let disclaimerText = """
T1D Helper is a personal calculator, not a medical device. It only does math with the numbers you enter. \
Always check the result and follow the plan from your diabetes team. If a number looks wrong, don't inject: \
check again or ask your team.
"""
