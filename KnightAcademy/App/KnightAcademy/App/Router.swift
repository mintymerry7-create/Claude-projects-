import SwiftUI
import Observation
import ChessCore
import AppFeatures

enum AppTab: Hashable {
    case home, openings, practice, play, profile
}

/// Every pushable screen. Value-based so any tab can navigate anywhere.
enum Route: Hashable {
    case opening(String)
    case trainer(openingID: String, mode: TrainerMode, side: PieceColor?, startNode: Int)
    case explorer(openingID: String)
    case reviews
    case puzzles(theme: String?, puzzleID: String?)
    case curriculum
    case lesson(String)
    case game(GameSetup)
    case savedGame(UUID)
    case repertoire(UUID)
    case repertoireTrainer(UUID, TrainerMode)
    case gameHistory
    case bookmarks
    case settings
    case about
}

@Observable
final class Router {
    var tab: AppTab = .home
    var homePath = NavigationPath()
    var openingsPath = NavigationPath()
    var practicePath = NavigationPath()
    var playPath = NavigationPath()
    var profilePath = NavigationPath()

    /// Pushes a route on the current tab's stack.
    func push(_ route: Route) {
        switch tab {
        case .home: homePath.append(route)
        case .openings: openingsPath.append(route)
        case .practice: practicePath.append(route)
        case .play: playPath.append(route)
        case .profile: profilePath.append(route)
        }
    }

    /// Switches tab and pushes a route there.
    func open(_ route: Route, in tab: AppTab) {
        self.tab = tab
        push(route)
    }
}

/// Resolves routes to screens; attached to every NavigationStack.
struct RouteDestination: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            switch route {
            case .opening(let id): OpeningDetailView(openingID: id)
            case let .trainer(id, mode, side, start): TrainerScreen(openingID: id, mode: mode, side: side, startNode: start)
            case .explorer(let id): VariationExplorerView(openingID: id)
            case .reviews: ReviewScreen()
            case let .puzzles(theme, puzzleID): PuzzleScreen(theme: theme, initialPuzzleID: puzzleID)
            case .curriculum: CurriculumView()
            case .lesson(let id): LessonScreen(lessonID: id)
            case .game(let setup): GameScreen(setup: setup)
            case .savedGame(let id): GameReviewView(gameID: id)
            case .repertoire(let id): RepertoireEditorScreen(repertoireID: id)
            case let .repertoireTrainer(id, mode): RepertoireTrainerScreen(repertoireID: id, mode: mode)
            case .gameHistory: GameHistoryView()
            case .bookmarks: BookmarksView()
            case .settings: SettingsView()
            case .about: AboutView()
            }
        }
    }
}

extension View {
    func withRoutes() -> some View { modifier(RouteDestination()) }
}
