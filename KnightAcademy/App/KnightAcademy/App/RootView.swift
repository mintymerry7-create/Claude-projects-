import SwiftUI
import OpeningDatabase
import AppFeatures

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            NavigationStack(path: $router.homePath) {
                HomeView().withRoutes()
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(AppTab.home)

            NavigationStack(path: $router.openingsPath) {
                OpeningsView().withRoutes()
            }
            .tabItem { Label("Openings", systemImage: "book") }
            .tag(AppTab.openings)

            NavigationStack(path: $router.practicePath) {
                PracticeView().withRoutes()
            }
            .tabItem { Label("Practice", systemImage: "target") }
            .tag(AppTab.practice)

            NavigationStack(path: $router.playPath) {
                PlayView().withRoutes()
            }
            .tabItem { Label("Play", systemImage: "checkerboard.rectangle") }
            .tag(AppTab.play)

            NavigationStack(path: $router.profilePath) {
                ProfileView().withRoutes()
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(AppTab.profile)
        }
        .fullScreenCover(isPresented: Binding(
            get: { !model.data.hasCompletedOnboarding },
            set: { _ in }
        )) {
            OnboardingView()
        }
        .alert("Your saved data could not be read",
               isPresented: Binding(get: { model.store.recoveredBackupURL != nil && !dismissedRecovery },
                                    set: { if !$0 { dismissedRecovery = true } })) {
            Button("OK", role: .cancel) { dismissedRecovery = true }
        } message: {
            Text("A damaged progress file was moved aside and a fresh one was started. The old file was kept in the app's data folder.")
        }
    }

    @State private var dismissedRecovery = false
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var level: Difficulty = .beginner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KA.Spacing.xl) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(KA.Palette.accent)
                        .accessibilityHidden(true)
                    Text("Welcome to \(AppInfo.name)").font(.largeTitle.bold())
                    Text("Learn openings, sharpen tactics and play real engine opponents — all offline, no account needed.")
                        .foregroundStyle(KA.Palette.textSecondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("What should we call you?").font(.headline)
                    TextField("Your name (optional)", text: $name)
                        .textContentType(.givenName)
                        .padding(12)
                        .background(KA.Palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("How much chess do you know?").font(.headline)
                    ForEach(Difficulty.allCases) { d in
                        Button {
                            level = d
                            Feedback.selection()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: level == d ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(level == d ? KA.Palette.accent : KA.Palette.textSecondary)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.displayName).font(.headline)
                                    Text(levelText(d)).font(.subheadline).foregroundStyle(KA.Palette.textSecondary)
                                }
                                Spacer()
                            }
                            .card(padding: 14)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(level == d ? .isSelected : [])
                    }
                }

                Button("Start learning") {
                    model.completeOnboarding(name: name.trimmingCharacters(in: .whitespaces), level: level)
                    Feedback.success()
                }
                .buttonStyle(.primary)
            }
            .padding(KA.Spacing.xl)
        }
        .screenBackground()
        .interactiveDismissDisabled()
    }

    private func levelText(_ d: Difficulty) -> String {
        switch d {
        case .beginner: return "I know how the pieces move, or I'm just starting."
        case .intermediate: return "I play regularly and know some openings and tactics."
        case .advanced: return "I study theory and want deep variations."
        }
    }
}
