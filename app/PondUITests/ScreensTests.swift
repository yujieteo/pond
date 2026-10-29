import XCTest

/// The simulator proof of the plan editor, the grid and the experiments. It needs no server: the entries wait in the
/// outbox, and `-github` keeps the plan off the network. TEST_RUNNER_POND_SHOTS is a directory for the screenshots.
@MainActor
final class ScreensTests: XCTestCase {
    let env = ProcessInfo.processInfo.environment

    /// A slot: its words in place, its day buttons, "Remove" with "Undo", and the commit that waits for a token.
    func testPlanEditor() throws {
        let shots = try XCTUnwrap(env["POND_SHOTS"], "set TEST_RUNNER_POND_SHOTS")
        let app = launch()
        app.buttons["Plan"].tap()
        save("plan", in: shots)

        app.buttons["+ Add a slot"].tap()
        let new = app.otherElements["New slot"]
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        let name = "Text (1): one paper \(Int.random(in: 1000...9999))"
        let field = new.descendants(matching: .any).matching(NSPredicate(format: "label == 'Slot'")).firstMatch
        // A tap at the right end puts the cursor after "New slot".
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + name + "\n")

        let slot = app.otherElements[name]
        XCTAssertTrue(slot.waitForExistence(timeout: 5))
        let monday = slot.buttons["Monday"]
        let before = monday.value as? String
        monday.tap()
        XCTAssertNotEqual(slot.buttons["Monday"].value as? String, before, "a tap adds the day or takes it away")
        slot.buttons["Friday"].tap()
        save("plan-slot", in: shots)

        // "Remove" goes at once, and "Undo" brings the slot back.
        slot.buttons["Remove slot"].tap()
        XCTAssertFalse(app.otherElements[name].exists)
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.otherElements[name].waitForExistence(timeout: 5))
        app.otherElements[name].buttons["Remove slot"].tap()
        XCTAssertFalse(app.otherElements[name].exists)

        // With no site copy and no token, the change waits on the phone.
        let status = app.staticTexts["planStatus"]
        XCTAssertTrue(status.label.hasPrefix("Waiting") || status.label.hasPrefix("Not sent"), status.label)
        app.swipeUp()
        XCTAssertTrue(app.secureTextFields["Token"].exists || app.buttons["Remove token"].exists)
        save("plan-token", in: shots)
    }

    /// "Done" on the "not visited" choice fills its dot. An empty dot gives "Pick for today".
    func testGrid() throws {
        let shots = try XCTUnwrap(env["POND_SHOTS"], "set TEST_RUNNER_POND_SHOTS")
        let app = launch()
        let card = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Not visited yet'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        // "Not visited yet · Music · live"
        let parts = card.label.components(separatedBy: " · ")
        let place = "\(parts[1]), \(parts[2])"
        card.tap()
        app.buttons["Done"].firstMatch.tap()

        app.buttons["Grid"].tap()
        let dot = app.buttons[place]
        XCTAssertTrue(dot.waitForExistence(timeout: 5))
        XCTAssertEqual(dot.value as? String, "visited")
        XCTAssertTrue(app.staticTexts["gridCount"].label.contains(" of 68 places in "))
        save("grid", in: shots)
        // The "Fun?" toast goes after 10 seconds. A dot under the bar comes up with a swipe.
        let fun = app.staticTexts["Fun?"]
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: fun)], timeout: 12)
        if dot.frame.maxY > app.buttons["Today"].frame.minY - 8 { app.swipeUp() }
        dot.tap()
        XCTAssertTrue(app.staticTexts["\(parts[1]) · \(parts[2])"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Pick for today"].exists)
        save("grid-cell", in: shots)
        app.swipeDown(velocity: .fast)

        let empty = app.buttons.matching(NSPredicate(format: "value == 'not visited yet'")).firstMatch
        let emptyPlace = empty.label.components(separatedBy: ", ")
        empty.tap()
        app.buttons["Pick for today"].tap()
        // Today, with the empty cell as the pick.
        let picked = app.staticTexts["Not visited yet · \(emptyPlace[0]) · \(emptyPlace[1])"]
        XCTAssertTrue(picked.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].exists)
        save("grid-pick", in: shots)
        app.buttons["Something else"].tap()
    }

    /// Start "Align with a stuck task", "Done" on its choice, then close it with a private notice, with "Undo" first.
    func testExperiment() throws {
        let shots = try XCTUnwrap(env["POND_SHOTS"], "set TEST_RUNNER_POND_SHOTS")
        let app = launch()
        app.buttons["Experiments"].tap()
        // An earlier run can leave an active experiment.
        if app.buttons["Close"].exists { close(app, notice: "") }

        let card = app.otherElements["E2"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.buttons["Start for 7 days"].tap()
        let progress = app.staticTexts["experimentProgress"]
        XCTAssertEqual(progress.label, "Day 1 of 7 · done on 0 days")
        save("experiment", in: shots)

        // The experiment is the last choice on Today. "Done" counts the day and makes no entry.
        app.buttons["Today"].tap()
        let choice = app.staticTexts["Experiment · day 1 of 7"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        save("experiment-today", in: shots)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Fun?"].waitForExistence(timeout: 2), "no entry, so no fun mark")
        app.buttons["Experiments"].tap()
        XCTAssertEqual(app.staticTexts["experimentProgress"].label, "Day 1 of 7 · done on 1 day")

        let notice = "The no was about the first step \(Int.random(in: 1000...9999))"
        close(app, notice: notice)
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts["experimentProgress"].waitForExistence(timeout: 5))
        close(app, notice: notice)
        XCTAssertTrue(app.staticTexts[notice].waitForExistence(timeout: 5))
        app.swipeUp()
        save("experiment-closed", in: shots)
    }

    private func close(_ app: XCUIApplication, notice: String) {
        app.buttons["Close"].tap()
        let field = app.textViews["Notice"].exists ? app.textViews["Notice"] : app.textFields["Notice"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        if !notice.isEmpty {
            field.tap()
            field.typeText(notice)
        }
        save("experiment-notice", in: env["POND_SHOTS"] ?? NSTemporaryDirectory())
        app.buttons["Keep private"].tap()
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-server", "http://127.0.0.1:9", "-github", "http://127.0.0.1:9"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        return app
    }

    private func save(_ name: String, in dir: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(filePath: "\(dir)/\(name).png"))
    }
}
