import XCTest

/// Drives the real app to verify the exact interactions that were crashing:
/// selecting a folder, and double-clicking to open it. Requires the catalog to be
/// seeded beforehand (the harness runs a headless `--scan` of a demo tree first).
final class BrowserUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testSelectAndOpenFolderDoesNotCrash() throws {
        let app = XCUIApplication()
        app.launch()

        // The auto-selected drive shows the tree browser. "Photos" is a top-level folder.
        let photos = app.staticTexts["Photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 20), "Browser should display the Photos folder")

        // Single-click selects it (this is what reportedly couldn't be done).
        photos.click()
        XCTAssertEqual(app.state, .runningForeground, "App must stay alive after selecting a folder")

        // Double-click opens it (primary action).
        photos.doubleClick()

        // Opening Photos should reveal its child folder "2019".
        let child = app.staticTexts["2019"]
        XCTAssertTrue(child.waitForExistence(timeout: 10),
                      "Double-clicking Photos should open it and reveal 2019")
        XCTAssertEqual(app.state, .runningForeground, "App must stay alive after opening a folder")
    }

    func testMultiSelectStaysAlive() throws {
        let app = XCUIApplication()
        app.launch()

        let docs = app.staticTexts["Docs"]
        XCTAssertTrue(docs.waitForExistence(timeout: 20))
        docs.click()

        // ⌘-click a second row to extend the selection.
        let photos = app.staticTexts["Photos"]
        if photos.exists {
            XCUIElement.perform(withKeyModifiers: .command) { photos.click() }
        }
        XCTAssertEqual(app.state, .runningForeground, "App must stay alive during multi-select")
    }
}
