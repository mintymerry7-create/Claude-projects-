import XCTest

/// Captures App Store–style screenshots of the main screens.
/// Set SCREENSHOT_DIR (via TEST_RUNNER_SCREENSHOT_DIR) to write PNGs to disk.
final class ScreenshotTests: XCTestCase {
    var app: XCUIApplication!
    var index = 0

    func shot(_ name: String) {
        sleep(1)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            index += 1
            let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%02d-%@.png", index, name))
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: url)
        }
    }

    func testCaptureScreens() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uitest-reset"]
        app.launch()

        let start = app.buttons["Start learning"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        shot("onboarding")
        start.tap()
        shot("home")

        // Openings explorer and an opening page.
        app.tabBars.buttons["Openings"].tap()
        shot("openings")
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("Najdorf")
            let cell = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Najdorf'")).firstMatch
            if cell.waitForExistence(timeout: 5) {
                cell.tap()
                shot("opening-detail")
                let learn = app.buttons["Start learning"]
                if learn.waitForExistence(timeout: 5) {
                    learn.tap()
                    shot("depth-picker")
                    let confirm = app.buttons["Start"]
                    if confirm.waitForExistence(timeout: 5) {
                        confirm.tap()
                        sleep(2)
                        let play = app.buttons["Play move"]
                        for _ in 0..<5 where play.waitForExistence(timeout: 3) {
                            if play.isEnabled { play.tap() }
                            sleep(1)
                        }
                        shot("trainer-learn")
                        let back = app.buttons["Back"].firstMatch
                        if back.exists { back.tap() }
                        sleep(1)
                    }
                }
            }
        }

        // Practice: fundamentals lesson and a puzzle.
        app.tabBars.buttons["Practice"].tap()
        shot("practice")
        let lessons = app.buttons["All lessons"]
        if lessons.waitForExistence(timeout: 5) {
            lessons.tap()
            let lesson = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Forks'")).firstMatch
            if lesson.waitForExistence(timeout: 5) {
                lesson.tap()
                let cont = app.buttons["Continue"]
                if cont.waitForExistence(timeout: 5) { cont.tap() }
                shot("lesson")
            }
        }

        // Play against the bot.
        app.tabBars.buttons["Play"].tap()
        shot("play-setup")
        let startGame = app.buttons["Start game"]
        if startGame.waitForExistence(timeout: 5) {
            startGame.tap()
            let e2 = app.descendants(matching: .any)["e2, White pawn"]
            if e2.waitForExistence(timeout: 8) {
                e2.tap()
                app.descendants(matching: .any)["e4, legal destination"].firstMatch.tap()
                sleep(4)
            }
            shot("game")
        }

        app.tabBars.buttons["Profile"].tap()
        shot("profile")
    }
}
