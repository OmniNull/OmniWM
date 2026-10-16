// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import TOML
import XCTest

final class ShellTOMLTextTests: XCTestCase {
    private func tree(_ text: String) throws -> [String: TOMLNode] {
        try TOMLDecoder().decode([String: TOMLNode].self, from: Data(text.utf8))
    }

    func testEditingTableAndDottedSettingsPreservesUnrelatedValues() throws {
        let original = """
        profile = "look"
        profiles.default.leading = ["clock"]
        name = "x]["
        when = 1979-05-27 07:32:00Z
        trailing = ["a]", 'b[']
        [profiles.look.workspaceBar]
        height = 60
        [weather]
        city = "Toronto"
        """
        let updated = try ShellTOMLText.setting([
            (["profiles", "look", "workspaceBar", "height"], "80"),
            (["profiles", "default", "leading"], "[\"battery\"]")
        ], in: original)
        var expected = try tree(original)
        expected["profiles"] = .table([
            "default": .table(["leading": .array([.string("battery")])]),
            "look": .table(["workspaceBar": .table(["height": .integer(80)])])
        ])
        XCTAssertEqual(try tree(updated), expected)
        XCTAssertTrue(try ShellTOMLText.contains(["profiles", "look", "workspaceBar", "height"], in: updated))
        XCTAssertFalse(try ShellTOMLText.contains(["profiles", "look", "workspaceBar", "position"], in: updated))
    }

    func testQuotedKeysAndEscapedValuesRoundTrip() throws {
        let value = "quote \" line\nslash \\ tab\t"
        let updated = try ShellTOMLText.setting([
            (["profiles", "my look", "theme"], ShellTOMLText.quoted(value))
        ], in: "'profile' = 'default'\n")
        XCTAssertEqual(try tree(updated), [
            "profile": .string("default"),
            "profiles": .table(["my look": .table(["theme": .string(value)])])
        ])
    }

    func testRemovingOneProfileTableLeavesOtherProfilesAndSettings() throws {
        let updated = try ShellTOMLText.setting([
            (["profiles", "look", "workspaceBar"], nil)
        ], in: """
        profile = "look"
        [profiles.look]
        leading = ["clock"]
        [profiles.look.workspaceBar]
        height = 60
        [profiles.default.workspaceBar]
        height = 24
        """)
        XCTAssertEqual(try tree(updated), [
            "profile": .string("look"),
            "profiles": .table([
                "look": .table(["leading": .array([.string("clock")])]),
                "default": .table(["workspaceBar": .table(["height": .integer(24)])])
            ])
        ])
    }

    func testNoOpPreservesTheOriginalText() throws {
        let original = "# keep formatting\nprofile = 'default'\n"
        XCTAssertEqual(try ShellTOMLText.setting([(["profile"], "\"default\"")], in: original), original)
        XCTAssertEqual(try ShellTOMLText.setting([(["missing"], nil)], in: original), original)
    }

    func testInvalidInputCannotOverwriteExistingValues() {
        XCTAssertThrowsError(try ShellTOMLText.setting([(["profile"], "\"look\"")], in: "trailing = ["))
        XCTAssertThrowsError(try ShellTOMLText.setting([(["trailing"], "[")], in: "profile = 'default'"))
        XCTAssertThrowsError(try ShellTOMLText.setting(
            [(["profiles", "look", "height"], "60")],
            in: "profiles.look = 42"
        ))
    }

    func testTypedMonitorSettingsAndColorsRoundTrip() throws {
        let monitor = MonitorBarSettings(monitorName: "Main", monitorDisplayId: 7, position: .right, height: 60)
        let color = SettingsColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        let updated = try ShellTOMLText.settingNodes([
            (["profiles", "look", "monitorBarOverrides"], try ShellTOMLText.node([monitor])),
            (["profiles", "look", "workspaceBar", "accentColor"], try ShellTOMLText.node(color))
        ], in: "")
        let parsed = try tree(updated)
        guard case let .table(profiles)? = parsed["profiles"],
              case let .table(look)? = profiles["look"],
              let monitors = look["monitorBarOverrides"],
              case let .table(bar)? = look["workspaceBar"], let accent = bar["accentColor"]
        else {
            return XCTFail("Expected profile settings")
        }
        XCTAssertEqual(try ShellTOMLText.decode([MonitorBarSettings].self, from: monitors), [monitor])
        XCTAssertEqual(try ShellTOMLText.decode(SettingsColor.self, from: accent), color)
    }
}
