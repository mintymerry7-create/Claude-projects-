import SwiftUI

private struct MealItem: Identifiable {
    let id = UUID()
    var name: String
    var grams: Double?
    var carbs: Double
    var calories: Double

    var detail: String {
        let weight = grams.map { "\(Fmt.grams($0)) g" } ?? "custom"
        return "\(weight) · \(Fmt.grams(calories)) kcal"
    }
}

struct FoodView: View {
    @EnvironmentObject private var store: Store
    @State private var items: [MealItem] = []
    @State private var chosen: Food?
    @State private var gramsText = ""
    @State private var customName = ""
    @State private var customCarbs = ""
    @State private var customCalories = ""
    @State private var showNewFood = false
    @FocusState private var focused: Bool

    private var totalCarbs: Double { items.reduce(0) { $0 + $1.carbs } }
    private var totalCalories: Double { items.reduce(0) { $0 + $1.calories } }
    private var todaysMeals: [MealEntry] {
        store.meals
            .filter { Calendar.current.isDateInToday($0.date) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            Form {
                mealSection
                addFromFoodsSection
                addCustomSection
                todaySection
                librarySection
            }
            .navigationTitle("Food")
            .keyboardDoneButton($focused)
            .sheet(isPresented: $showNewFood) {
                NewFoodView().environmentObject(store)
            }
        }
    }

    private var mealSection: some View {
        Section("This meal") {
            if items.isEmpty {
                Text("Add foods below.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.name)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Fmt.grams(item.carbs)) g")
                }
            }
            .onDelete { items.remove(atOffsets: $0) }
            if !items.isEmpty {
                LabeledContent("Total carbs", value: "\(Fmt.grams(totalCarbs)) g").bold()
                LabeledContent("Calories", value: "\(Fmt.grams(totalCalories)) kcal")
                Button("Use in dose calculator") { sendToCalculator() }
                Button("Log meal without a dose") { logMeal() }
            }
        }
    }

    private var addFromFoodsSection: some View {
        Section("Add from my foods") {
            Picker("Food", selection: $chosen) {
                Text("Choose…").tag(Food?.none)
                ForEach(store.foods) { food in
                    Text(food.name).tag(Food?.some(food))
                }
            }
            NumberRow(title: "Weight", unit: "g", text: $gramsText, focus: $focused)
            if let food = chosen, let grams = Double(parsing: gramsText), grams > 0 {
                Text("\(Fmt.grams(food.carbsPer100g * grams / 100)) g carbs · \(Fmt.grams(food.caloriesPer100g * grams / 100)) kcal")
                    .foregroundStyle(.secondary)
            }
            Button("Add") { addChosen() }
                .disabled(chosen == nil || (Double(parsing: gramsText) ?? 0) <= 0)
        }
    }

    private var addCustomSection: some View {
        Section("Add custom") {
            TextField("Name", text: $customName)
            NumberRow(title: "Carbs", unit: "g", text: $customCarbs, focus: $focused)
            NumberRow(title: "Calories", unit: "kcal", text: $customCalories, focus: $focused)
            Button("Add") { addCustom() }
                .disabled(Double(parsing: customCarbs) == nil)
        }
    }

    private var todaySection: some View {
        Section("Today") {
            LabeledContent("Carbs", value: "\(Fmt.grams(todaysMeals.reduce(0) { $0 + $1.carbs })) g")
            LabeledContent("Calories", value: "\(Fmt.grams(todaysMeals.reduce(0) { $0 + $1.calories })) kcal")
            ForEach(todaysMeals) { meal in
                HStack {
                    VStack(alignment: .leading) {
                        Text(meal.name)
                        Text(meal.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Fmt.grams(meal.carbs)) g")
                }
            }
        }
    }

    private var librarySection: some View {
        Section {
            ForEach(store.foods) { food in
                VStack(alignment: .leading) {
                    Text(food.name)
                    Text("\(Fmt.grams(food.carbsPer100g)) g carbs · \(Fmt.grams(food.caloriesPer100g)) kcal per 100 g")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                chosen = nil
                store.foods.remove(atOffsets: offsets)
            }
            Button("New food") { showNewFood = true }
        } header: {
            Text("My foods")
        } footer: {
            Text("Starter values are averages. Check the label on your food.")
        }
    }

    private func addChosen() {
        guard let food = chosen, let grams = Double(parsing: gramsText), grams > 0 else { return }
        items.append(MealItem(
            name: food.name,
            grams: grams,
            carbs: food.carbsPer100g * grams / 100,
            calories: food.caloriesPer100g * grams / 100
        ))
        gramsText = ""
        focused = false
    }

    private func addCustom() {
        guard let carbs = Double(parsing: customCarbs) else { return }
        let name = customName.trimmingCharacters(in: .whitespaces)
        items.append(MealItem(
            name: name.isEmpty ? "Custom" : name,
            grams: nil,
            carbs: carbs,
            calories: Double(parsing: customCalories) ?? 0
        ))
        customName = ""
        customCarbs = ""
        customCalories = ""
        focused = false
    }

    private var mealName: String {
        items.map(\.name).joined(separator: ", ")
    }

    private func sendToCalculator() {
        store.draftCarbs = String(format: "%g", (totalCarbs * 10).rounded() / 10)
        store.draftMealName = mealName
        store.draftCalories = totalCalories
        items = []
        store.selectedTab = .dose
    }

    private func logMeal() {
        store.meals.append(MealEntry(date: .now, name: mealName, carbs: totalCarbs, calories: totalCalories))
        items = []
    }
}

struct NewFoodView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var carbs = ""
    @State private var calories = ""
    @FocusState private var focused: Bool

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && Double(parsing: carbs) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    NumberRow(title: "Carbs", unit: "g / 100 g", text: $carbs, focus: $focused)
                    NumberRow(title: "Calories", unit: "kcal / 100 g", text: $calories, focus: $focused)
                } footer: {
                    Text("Copy the per-100 g numbers from the nutrition label.")
                }
            }
            .navigationTitle("New food")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton($focused)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.foods.append(Food(
                            name: name.trimmingCharacters(in: .whitespaces),
                            carbsPer100g: Double(parsing: carbs) ?? 0,
                            caloriesPer100g: Double(parsing: calories) ?? 0
                        ))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}
