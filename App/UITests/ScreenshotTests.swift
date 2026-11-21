import XCTest

/// Erzeugt Screenshots für Website und App Store gegen eine Demo-Instanz.
///
/// Gesteuert über Umgebungsvariablen (xcodebuild reicht `TEST_RUNNER_<NAME>` als `<NAME>` durch,
/// siehe scripts/screenshots.sh):
/// - `DZ_LINK`: Verbindungslink `doorzign://edge?…` der Demo-Instanz
/// - `DZ_USER`, `DZ_PASSWORD`: Demo-Benutzer mit Bearbeiten-Recht
/// - `DZ_LANGUAGE`: `de` oder `en`
/// - `DZ_DISPLAY`: Teil des Namens des Displays für Detail-/Editor-Aufnahmen (sonst das erste der Liste)
/// - `DZ_ADHOC_DISPLAY`, `DZ_SCHEDULE_DISPLAY`: Displays für Ad-hoc- und Zeitplan-Aufnahmen (optional)
///
/// Speichert nichts auf der Instanz: Editoren werden nur geöffnet und wieder verlassen.
@MainActor
final class ScreenshotTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let app = XCUIApplication()

    func testScreenshots() throws {
        continueAfterFailure = false
        let language = env["DZ_LANGUAGE"] ?? "de"
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "de" ? "de_DE" : "en_US"]
        if let link = env["DZ_LINK"] {
            app.launchArguments += ["-DZPairingLink", link]
        }
        app.launch()

        // Willkommen (nur sichtbar, solange noch kein Profil gespeichert ist).
        let username = app.textFields["login.username"]
        if !username.waitForExistence(timeout: 4) {
            if app.buttons["display.row"].firstMatch.exists == false, app.staticTexts.count > 0 {
                snap("00-willkommen")
            }
        }
        let alert = app.alerts.firstMatch
        if !username.waitForExistence(timeout: 20), alert.exists {
            XCTFail("Verbindung fehlgeschlagen: \(alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " – "))")
            return
        }
        if username.exists {
            username.tap()
            username.typeText(try XCTUnwrap(env["DZ_USER"], "DZ_USER fehlt"))
            let password = app.secureTextFields["login.password"]
            password.tap()
            password.typeText(try XCTUnwrap(env["DZ_PASSWORD"], "DZ_PASSWORD fehlt"))
            app.buttons["login.submit"].tap()
        }

        // Display-Liste.
        let rows = app.buttons.matching(identifier: "display.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "Display-Liste nicht geladen")
        settle(4)  // Miniaturen laden
        snap("01-displays")

        // Detail, Kartenmenü und Editor (DZ_DISPLAY).
        openDisplay(env["DZ_DISPLAY"])
        settle(3)
        snap("02-detail")
        let card = ["slot.card.2", "slot.card.3", "slot.card.1"].map { app.buttons[$0] }.first { $0.exists }
        if let card {
            card.tap()
            let edit = app.buttons["slot.edit"]
            if edit.waitForExistence(timeout: 5) {
                settle(1)
                snap("03-ansicht-menue")
                edit.tap()
                settle(5)  // Live-Vorschau
                snap("04-editor")
                goBack()
            }
        }
        goBack()

        // Aktive Ad-hoc-Nachricht im Detail (DZ_ADHOC_DISPLAY).
        if let name = env["DZ_ADHOC_DISPLAY"], !name.isEmpty {
            openDisplay(name)
            if scrollTo(app.buttons["adhoc.open"]) {
                settle(1)
                snap("05-adhoc")
            }
            goBack()
        }

        // Zeitpläne und „Neuer Zeitplan“ (DZ_SCHEDULE_DISPLAY), ohne Speichern.
        if let name = env["DZ_SCHEDULE_DISPLAY"], !name.isEmpty {
            openDisplay(name)
            if scrollTo(app.buttons["schedules.open"]) {
                app.buttons["schedules.open"].tap()
                settle(2)
                snap("06-zeitplaene")
                let add = app.buttons["schedules.add"]
                if add.waitForExistence(timeout: 5) {
                    add.tap()
                    settle(2)
                    snap("07-zeitplan-neu")
                    app.navigationBars.buttons.element(boundBy: 0).tap()  // Abbrechen
                    settle(1)
                }
                goBack()
            }
            goBack()
        }

        // Übertragungen (zweiter Tab).
        let tabs = app.tabBars.buttons
        if tabs.count >= 2 {
            tabs.element(boundBy: 1).tap()
            settle(2)
            snap("08-uebertragungen")
        }
    }

    /// Öffnet das Display, dessen Zeile den Namen enthält (sonst das erste), und wartet auf die Ansichten.
    private func openDisplay(_ name: String?) {
        let rows = app.buttons.matching(identifier: "display.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "Display-Liste nicht sichtbar")
        var row = rows.firstMatch
        if let name, !name.isEmpty {
            row = rows.containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            if !row.exists { row = rows.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch }
        }
        XCTAssertTrue(scrollTo(row), "Display „\(name ?? "")“ nicht gefunden")
        row.tap()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'slot.card.'"))
        _ = cards.firstMatch.waitForExistence(timeout: 20)
    }

    // MARK: Hilfen

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [expectation(description: "warten")], timeout: seconds)
    }

    private func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        settle(1)
    }

    /// Scrollt die Detailliste, bis das Element sichtbar ist.
    private func scrollTo(_ element: XCUIElement, attempts: Int = 6) -> Bool {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }
}
