import XCTest

/// The simulator proof of the plan editor, the grid, the experiments, daily reading, the interests, live events and the log. It needs no server: the entries wait in the
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

    /// A daily read added in the plan editor is a button of the "Every day" row on Today, and a tap puts it in the log.
    func testDailyReading() throws {
        let shots = try XCTUnwrap(env["POND_SHOTS"], "set TEST_RUNNER_POND_SHOTS")
        let app = launch()
        app.buttons["Plan"].tap()
        app.buttons["+ Add a daily read"].tap()
        let new = app.otherElements["New daily read"]
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        let name = "Poetry \(Int.random(in: 1000...9999))"
        let field = new.descendants(matching: .any).matching(NSPredicate(format: "label == 'Slot'")).firstMatch
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 14) + "Text (1): \(name), one poem\n")
        let slot = app.otherElements["Text (1): \(name), one poem"]
        XCTAssertTrue(slot.waitForExistence(timeout: 5))
        let today = weekday()
        if slot.buttons[today].value as? String == "off" { slot.buttons[today].tap() }
        save("plan-daily", in: shots)

        app.buttons["Today"].tap()
        let button = app.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(app.buttons["✓ \(name)"].waitForExistence(timeout: 5))
        save("today-daily", in: shots)

        app.buttons["Log"].tap()
        let entry = app.descendants(matching: .any)["log \(name)"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.label.contains("waiting"), entry.label)
        save("log", in: shots)

        // A second tap takes it back, with no "Undo".
        app.buttons["Today"].tap()
        app.buttons["✓ \(name)"].tap()
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
        app.buttons["Plan"].tap()
        app.otherElements["Text (1): \(name), one poem"].buttons["Remove slot"].tap()
    }

    /// An interest: its name, a feed, a classic and the "old" days; "Remove interest" with "Undo".
    func testInterest() throws {
        let shots = try XCTUnwrap(env["POND_SHOTS"], "set TEST_RUNNER_POND_SHOTS")
        let app = launch()
        app.buttons["Plan"].tap()
        let add = app.buttons["Add an interest"]
        while !add.isHittable || add.frame.maxY > app.buttons["Today"].frame.minY - 8 { app.swipeUp() }
        save("plan-interests", in: shots)
        add.tap()

        let name = "Optics \(Int.random(in: 1000...9999))"
        let field = app.textFields["Interest name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + name + "\n")
        app.textFields["Feed"].tap()
        app.textFields["Feed"].typeText("physics.optics")
        app.buttons["Add"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["physics.optics"].waitForExistence(timeout: 5))
        app.textFields["Classic title"].tap()
        app.textFields["Classic title"].typeText("Maiman 1960: stimulated optical radiation in ruby")
        app.textFields["Classic link"].tap()
        app.textFields["Classic link"].typeText("https://www.nature.com/articles/187493a0")
        app.buttons.matching(identifier: "Add").element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["Maiman 1960: stimulated optical radiation in ruby"].waitForExistence(timeout: 5))
        save("interest", in: shots)
        app.swipeDown(velocity: .fast)

        let chip = app.buttons[name]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        let old = app.otherElements["Old days"].buttons[weekday()]
        let before = old.value as? String
        old.tap()
        XCTAssertNotEqual(app.otherElements["Old days"].buttons[weekday()].value as? String, before)
        old.tap()

        chip.tap()
        let remove = app.buttons["Remove interest"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertFalse(app.buttons[name].waitForExistence(timeout: 1))
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
        app.buttons[name].tap()
        app.buttons["Remove interest"].tap()
    }

    /// A live event saved for today is the live choice on Today, with "Go" and "Done". "Done" puts it in the log.
    func testLiveEvent() throws {
        let shots = try XCTUnwrap(env["POND_SHOTS"], "set TEST_RUNNER_POND_SHOTS")
        let app = launch()
        // An active experiment can take the last choice of the day.
        app.buttons["Experiments"].tap()
        if app.buttons["Close"].waitForExistence(timeout: 2) { close(app, notice: "") }
        app.buttons["Plan"].tap()
        let save = app.buttons["+ Save a live event"]
        while !save.isHittable || save.frame.maxY > app.buttons["Today"].frame.minY - 8 { app.swipeUp() }
        save.tap()
        let title = "Open mic \(Int.random(in: 1000...9999))"
        let field = app.textFields["Event title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(title)
        app.textFields["Place"].tap()
        app.textFields["Place"].typeText("The Projector, Singapore")
        app.textFields["Cost"].tap()
        app.textFields["Cost"].typeText("free")
        self.save("event", in: shots)
        app.buttons["Save for that day"].tap()
        XCTAssertTrue(app.otherElements["event \(title)"].waitForExistence(timeout: 5))

        app.buttons["Today"].tap()
        let dontAllow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Don’t Allow"]
        if dontAllow.waitForExistence(timeout: 3) { dontAllow.tap() }
        let card = app.staticTexts[title]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Live · 20:00 · free"].exists)
        card.tap()
        XCTAssertTrue(app.links["Go"].exists || app.buttons["Go"].exists)
        self.save("today-live", in: shots)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Fun?"].waitForExistence(timeout: 5))

        app.buttons["Log"].tap()
        let entry = app.descendants(matching: .any)["log \(title)"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.label.contains("live"), entry.label)

        app.buttons["Plan"].tap()
        let row = app.otherElements["event \(title)"]
        while !row.isHittable { app.swipeUp() }
        row.buttons["Remove event"].tap()
        XCTAssertFalse(app.otherElements["event \(title)"].exists)
    }

    /// Today's weekday, as the accessibility label of a day button.
    private func weekday() -> String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][Calendar.current.component(.weekday, from: .now) - 1]
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
