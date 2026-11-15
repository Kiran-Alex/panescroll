import XCTest
@testable import ReelCore

final class KeyComboTests: XCTestCase {
    func testParsesModifiersAndArrow() throws {
        let c = try XCTUnwrap(KeyCombo("ctrl+opt+left"))
        XCTAssertEqual(c.keyCode, 123)
        XCTAssertEqual(c.modifiers, [.control, .option])
        XCTAssertEqual(c.display, "⌃⌥←")
    }

    func testAliasesAndCase() throws {
        let c = try XCTUnwrap(KeyCombo("Command+Alt+Shift+R"))
        XCTAssertEqual(c.modifiers, [.command, .option, .shift])
        XCTAssertEqual(c.display, "⌥⇧⌘R")
    }

    func testPunctuationKeys() {
        XCTAssertEqual(KeyCombo("ctrl+opt+[")?.keyCode, 33)
        XCTAssertEqual(KeyCombo("ctrl+opt+,")?.keyCode, 43)
    }

    func testRejectsUnknownKeysAndModifiers() {
        XCTAssertNil(KeyCombo("ctrl+opt+f13"))
        XCTAssertNil(KeyCombo("hyper+a"))
        XCTAssertNil(KeyCombo(""))
    }

    func testEveryDefaultShortcutParses() {
        for (action, combo) in Config.defaultShortcuts {
            XCTAssertNotNil(KeyCombo(combo), action)
        }
    }

    func testDefaultShortcutsAreUnique() {
        let combos = Config.defaultShortcuts.values.map { $0.lowercased() }
        XCTAssertEqual(Set(combos).count, combos.count)
    }

    func testEveryActionHasADefault() {
        for action in Config.actions {
            XCTAssertNotNil(Config.defaultShortcuts[action.id], action.id)
        }
    }

    func testScrollModifierParsing() {
        XCTAssertEqual(Modifiers(string: "ctrl+opt")?.cgFlags, [.maskControl, .maskAlternate])
        XCTAssertEqual(Modifiers(string: "")?.cgFlags, [])
        XCTAssertNil(Modifiers(string: "ctrl+banana"))
    }
}

final class ConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testEmptyFileGivesDefaults() throws {
        let c = try decode("{}")
        let d = Config()
        XCTAssertEqual(c.gap, d.gap)
        XCTAssertEqual(c.widthPresets, d.widthPresets)
        XCTAssertNil(c.newWindowWidth)
        XCTAssertEqual(c.scrollModifiers, d.scrollModifiers)
        XCTAssertTrue(c.animate)
        XCTAssertEqual(c.shortcuts, Config.defaultShortcuts)
    }

    func testPartialShortcutsMergeWithDefaults() throws {
        let c = try decode(#"{"shortcuts": {"focusLeft": "cmd+opt+h"}}"#)
        XCTAssertEqual(c.shortcuts["focusLeft"], "cmd+opt+h")
        XCTAssertEqual(c.shortcuts["focusRight"], Config.defaultShortcuts["focusRight"])
    }

    func testRoundTrip() throws {
        var c = Config()
        c.gap = 12
        c.newWindowWidth = 0.5
        c.scrollSpeed = -1.5
        c.ignoredBundleIDs = ["com.example.app"]
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.gap, 12)
        XCTAssertEqual(back.newWindowWidth, 0.5)
        XCTAssertEqual(back.scrollSpeed, -1.5)
        XCTAssertEqual(back.ignoredBundleIDs, ["com.example.app"])
    }

    func testWrongTypeIsAnError() {
        XCTAssertThrowsError(try decode(#"{"gap": "wide"}"#))
    }
}
