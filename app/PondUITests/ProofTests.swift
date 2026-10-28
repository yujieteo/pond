import XCTest

/// The simulator proof of build steps 6 and 7. Run it with a local test server (see "The app" in README.md).
/// TEST_RUNNER_POND_KEYS is the server's keys/ directory, and TEST_RUNNER_POND_SHOTS a directory for the screenshots.
@MainActor
final class ProofTests: XCTestCase {
    let env = ProcessInfo.processInfo.environment
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    var server: String { env["POND_SERVER"] ?? "http://127.0.0.1:8787" }

    /// Step 6: enrol this phone's key, record one entry from Today and see it sent.
    func testRecordOneEntry() throws {
        let shots = try XCTUnwrap(env["POND_SHOTS"], "set TEST_RUNNER_POND_SHOTS")
        let app = try launchAndEnrol()

        save("today", in: shots)
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
        save("today-done", in: shots)
        row.tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5))
        sleep(1)
        save("entry", in: shots)
    }

    /// Step 7: the invite notification at the invite time, a pick in it, the widgets with the pick, and "Done" in the
    /// Home Screen widget. The entry must then be on the server's /log/. Add the Home Screen widget (medium) and the
    /// Lock Screen widget of Waldenlog by hand before the run, for their screenshots.
    func testInvite() throws {
        let shots = try XCTUnwrap(env["POND_SHOTS"], "set TEST_RUNNER_POND_SHOTS")
        let app = try launchAndEnrol()

        // An earlier run can leave a pick or "Done" on today: a pick and "Something else" clear them.
        let card = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Today' AND label CONTAINS 'slot'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        app.buttons["Something else"].tap()

        // The invite time: the next minute that is at least 40 seconds away.
        var time = Calendar.current.date(bySetting: .second, value: 0, of: .now + 60)!
        if time.timeIntervalSinceNow < 40 { time += 60 }
        app.datePickers["Invite time"].tap()
        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.firstMatch.waitForExistence(timeout: 5))
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: String((parts.hour! + 11) % 12 + 1))
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: String(format: "%02d", parts.minute!))
        wheels.element(boundBy: 2).adjust(toPickerWheelValue: parts.hour! < 12 ? "AM" : "PM")
        app.buttons["PopoverDismissRegion"].tap()
        save("today-invite-time", in: shots)
        XCUIDevice.shared.press(.home)

        // The notification comes at the invite time, with the choices as buttons.
        let invite = notification("What do you want today?")
        XCTAssertTrue(invite.waitForExistence(timeout: time.timeIntervalSinceNow + 30))
        save("notification-banner", in: shots)
        invite.press(forDuration: 1)
        // The first choice is today's slot.
        let slot = NSPredicate(format: "label BEGINSWITH '📄' OR label BEGINSWITH '🎬' OR label BEGINSWITH '🎵'")
        let choice = springboard.buttons.matching(slot).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        save("notification", in: shots)
        let title = String(choice.label.dropFirst(2))
        choice.tap()

        // The pick changes the widgets, and the notification in place: in the list, with no banner and no sound.
        sleep(2)
        save("widget-home-pick", in: shots)
        lock()
        // The earlier notifications are under the Lock Screen: a swipe up shows them.
        springboard.swipeUp()
        let picked = notification("Today: \(title)")
        XCTAssertTrue(picked.waitForExistence(timeout: 10))
        save("widget-lock-pick", in: shots)
        // The simulator does not open a notification in the list for its buttons, so the test taps "✓ Done" in the
        // Home Screen widget: the same action as "✓ Done" in the notification.
        XCUIDevice.shared.press(.home)
        let widget = springboard.icons.matching(NSPredicate(format: "label == 'Waldenlog' AND value == 'Widget'")).firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 5))
        if widget.frame.minX > springboard.frame.maxX { springboard.swipeLeft() }
        // The widget gives no element for its buttons: "✓ Done" is the row above "Something else", at the bottom.
        let done = widget.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.51))

        // "Done" records, signs and sends the entry: one more entry with its title is on the server's /log/.
        let before = entries(title)
        done.tap()
        let deadline = Date.now + 30
        while Date.now < deadline, entries(title) == before { sleep(1) }
        XCTAssertEqual(entries(title), before + 1, "the entry is on /log/")
        // The widget shows the change when WidgetKit reloads it, some seconds later.
        sleep(5)
        lock()
        save("widget-lock-done", in: shots)
        XCUIDevice.shared.press(.home)
        sleep(2)
        save("widget-home-done", in: shots)
        app.launch()
        save("today-after-invite", in: shots)
    }

    /// Launches the app and enrols its key: the key file goes in the server's keys/, as the captain does by hand.
    private func launchAndEnrol() throws -> XCUIApplication {
        let keys = try XCTUnwrap(env["POND_KEYS"], "set TEST_RUNNER_POND_KEYS")
        unlock()
        let app = XCUIApplication()
        app.launchArguments = ["-server", server]
        app.launch()
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        app.buttons["Show key"].tap()
        let file = try XCTUnwrap(app.staticTexts["keyFile"].label.firstMatch(of: /keys\/(phone-[a-z0-9-]+\.pub)/)?.1)
        let key = app.staticTexts["publicKey"].label
        try (key + "\n").write(toFile: "\(keys)/\(file)", atomically: true, encoding: .utf8)
        app.swipeDown(velocity: .fast)
        return app
    }

    /// A notification of Waldenlog with `text`, on the Lock Screen or as a banner.
    private func notification(_ text: String) -> XCUIElement {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'NotificationShortLookView' AND label CONTAINS %@", text)).firstMatch
    }

    private func unlock() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        if springboard.staticTexts["Swipe up to open"].exists { springboard.swipeUp() }
    }

    /// Locks the phone and wakes it: the Lock Screen shows the notification and the Lock Screen widget.
    private func lock() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
    }

    /// The number of entries with `title` on the server's /log/.
    private func entries(_ title: String) -> Int {
        let log = (try? String(contentsOf: URL(string: "\(server)/log/")!, encoding: .utf8)) ?? ""
        let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return log.components(separatedBy: escaped).count - 1
    }

    private func save(_ name: String, in dir: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(filePath: "\(dir)/\(name).png"))
    }
}
