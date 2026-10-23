// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class HiddenBarAppRowTests: XCTestCase {
    func testRowsListInstalledTrackedAppsAndKeepSelectedOnes() {
        let urls = [
            "calc": URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            "chess": URL(fileURLWithPath: "/System/Applications/Chess.app")
        ]
        let rows = HiddenBarAppRow.rows(
            allowance: ["calc": true, "chess": false, "uninstalled": true],
            selected: ["kept"],
            applicationURL: { urls[$0] }
        )

        let expected = [
            ("calc", FileManager.default.displayName(atPath: urls["calc"]!.path), false, true),
            ("chess", FileManager.default.displayName(atPath: urls["chess"]!.path), true, true),
            ("kept", "kept", false, false)
        ].sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }

        XCTAssertEqual(rows.map(\.bundleID), expected.map(\.0))
        XCTAssertEqual(rows.map(\.name), expected.map(\.1))
        XCTAssertEqual(rows.map(\.isOffInSystemSettings), expected.map(\.2))
        XCTAssertEqual(rows.map { $0.icon != nil }, expected.map(\.3))
    }
}
