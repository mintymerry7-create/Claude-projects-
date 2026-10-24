import SwiftUI

@main
struct GlucoseHelperApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        if store.settings.acceptedDisclaimer {
            TabView(selection: $store.selectedTab) {
                CalculatorView()
                    .tabItem { Label("Dose", systemImage: "syringe") }
                    .tag(AppTab.dose)
                FoodView()
                    .tabItem { Label("Food", systemImage: "fork.knife") }
                    .tag(AppTab.food)
                LogView()
                    .tabItem { Label("Log", systemImage: "chart.xyaxis.line") }
                    .tag(AppTab.log)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
            .tint(Color(red: 1, green: 0.42, blue: 0.21))
        } else {
            DisclaimerView()
        }
    }
}

struct DisclaimerView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "drop.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.21))
            Text("T1D Helper").font(.largeTitle.bold())
            Text(disclaimerText).foregroundStyle(.secondary)
            Spacer()
            Button {
                store.settings.acceptedDisclaimer = true
            } label: {
                Text("I understand").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color(red: 1, green: 0.42, blue: 0.21))
        }
        .padding(24)
    }
}
