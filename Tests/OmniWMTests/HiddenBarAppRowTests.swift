// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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

        XCTAssertEqual(rows.map(\.bundleID), ["calc", "chess", "kept"])
        XCTAssertEqual(rows.map(\.name), ["Calculator", "Chess", "kept"])
        XCTAssertEqual(rows.map(\.isOffInSystemSettings), [false, true, false])
        XCTAssertNotNil(rows[0].icon)
        XCTAssertNil(rows[2].icon)
    }
}
