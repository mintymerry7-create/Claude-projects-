// swift-tools-version: 5.9
import PackageDescription

// KnightAcademyKit holds everything that is not SwiftUI: chess rules, engine
// protocol + built-in engine, opening database, learning/progress logic and
// the observable view models. It builds and tests on macOS, iOS and Linux.
let package = Package(
    name: "KnightAcademyKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(
            name: "KnightAcademyKit",
            targets: ["ChessCore", "ChessEngine", "OpeningDatabase", "Learning", "AppFeatures"]
        )
    ],
    targets: [
        .target(name: "ChessCore"),
        .target(name: "ChessEngine", dependencies: ["ChessCore"]),
        .target(
            name: "OpeningDatabase",
            dependencies: ["ChessCore"],
            resources: [.copy("Resources/openings.json")]
        ),
        .target(
            name: "Learning",
            dependencies: ["ChessCore", "ChessEngine", "OpeningDatabase"],
            resources: [.copy("Resources/curriculum.json"), .copy("Resources/puzzles.json")]
        ),
        .target(
            name: "AppFeatures",
            dependencies: ["ChessCore", "ChessEngine", "OpeningDatabase", "Learning"]
        ),
        .testTarget(name: "ChessCoreTests", dependencies: ["ChessCore"]),
        .testTarget(name: "ChessEngineTests", dependencies: ["ChessEngine"]),
        .testTarget(name: "OpeningDatabaseTests", dependencies: ["OpeningDatabase"]),
        .testTarget(name: "LearningTests", dependencies: ["Learning"]),
        .testTarget(name: "AppFeaturesTests", dependencies: ["AppFeatures"]),
    ]
)
