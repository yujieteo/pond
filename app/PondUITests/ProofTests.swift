import XCTest

/// The simulator proof of build step 6: enrol this phone's key on a local test server, record one entry
/// and see it sent. Run it with a local test server (see "The app" in README.md). TEST_RUNNER_POND_KEYS is the
/// server's keys/ directory, and TEST_RUNNER_POND_SHOTS a directory for the screenshots.
final class ProofTests: XCTestCase {
    @MainActor
    func testRecordOneEntry() throws {
        let env = ProcessInfo.processInfo.environment
        let keys = try XCTUnwrap(env["POND_KEYS"], "set TEST_RUNNER_POND_KEYS")
        let shots = try XCTUnwrap(env["POND_SHOTS"], "set TEST_RUNNER_POND_SHOTS")
        let app = XCUIApplication()
        app.launchArguments = ["-server", env["POND_SERVER"] ?? "http://127.0.0.1:8787"]
        app.launch()

        // Enrol: the key file goes in the server's keys/, as the captain does by hand.
        app.buttons["Show key"].tap()
        let file = try XCTUnwrap(app.staticTexts["keyFile"].label.firstMatch(of: /keys\/(phone-[a-z0-9-]+\.pub)/)?.1)
        let key = app.staticTexts["publicKey"].label
        try (key + "\n").write(toFile: "\(keys)/\(file)", atomically: true, encoding: .utf8)
        app.swipeDown(velocity: .fast)

        save(app, "today", in: shots)
        let choice = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Today' AND label CONTAINS 'slot'")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        app.buttons["Done"].firstMatch.tap()

        // The row shows "waiting" until the server accepts the entry.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'at home'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let sent = NSPredicate(format: "NOT (label CONTAINS 'waiting')")
        wait(for: [expectation(for: sent, evaluatedWith: row)], timeout: 15)

        app.buttons["loved it"].firstMatch.tap()
        save(app, "today-done", in: shots)
        row.tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5))
        sleep(1)
        save(app, "entry", in: shots)
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String, in dir: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(filePath: "\(dir)/\(name).png"))
    }
}
