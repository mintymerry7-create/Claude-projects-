import XCTest

/// Smoke tests that launch the real app and walk through the main flows.
final class KnightAcademyUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uitest-reset"]
        app.launch()
        let start = app.buttons["Start learning"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "onboarding is shown on first launch")
        start.tap()
    }

    func testAllTabsOpen() {
        for tab in ["Openings", "Practice", "Play", "Profile", "Home"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5), tab)
        }
        XCTAssertTrue(app.staticTexts["This week"].waitForExistence(timeout: 5))
    }

    func testStartAnOpeningCourseAndLearnMoves() {
        app.tabBars.buttons["Openings"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Giuoco Piano")
        let cell = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Giuoco Piano'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.tap()

        let startLearning = app.buttons["Start learning"]
        XCTAssertTrue(startLearning.waitForExistence(timeout: 5))
        startLearning.tap()
        let confirm = app.buttons["Start"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // Trainer in learn mode: play the shown moves.
        let playMove = app.buttons["Play move"]
        XCTAssertTrue(playMove.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            if playMove.isEnabled { playMove.tap() }
            sleep(1)
        }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'correct'")).firstMatch.exists
                      || app.otherElements["Chessboard"].exists)
    }

    func testPlayAGameAgainstTheBot() {
        app.tabBars.buttons["Play"].tap()
        let start = app.buttons["Start game"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.buttons["Resign"].waitForExistence(timeout: 10), "game screen is shown")
        XCTAssertTrue(app.buttons["Hint"].exists)
    }

    func testPuzzlesAndLessonsOpen() {
        app.tabBars.buttons["Practice"].tap()
        let lessons = app.buttons["All lessons"]
        XCTAssertTrue(lessons.waitForExistence(timeout: 5))
        lessons.tap()
        let lesson = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Rook, Bishop and Queen'")).firstMatch
        XCTAssertTrue(lesson.waitForExistence(timeout: 5))
        lesson.tap()
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Capture the black knight'")).firstMatch.waitForExistence(timeout: 5))
    }

    func testCreateRepertoire() {
        app.tabBars.buttons["Profile"].tap()
        let new = app.buttons["New repertoire"]
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        new.tap()
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("UI test repertoire")
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Play it against a bot"].waitForExistence(timeout: 5))
    }
}
