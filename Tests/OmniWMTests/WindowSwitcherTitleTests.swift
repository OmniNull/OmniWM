// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class WindowSwitcherTitleTests: XCTestCase {
    func testEmptyAndDuplicateTitlesUseAppName() {
        XCTAssertEqual(WindowSwitcherTitle.label(appName: "Zed", title: "  "), "Zed")
        XCTAssertEqual(WindowSwitcherTitle.label(appName: "Zed", title: "zed"), "Zed")
    }

    func testPathsUseLastComponentWithoutChangingOtherTitles() {
        XCTAssertEqual(WindowSwitcherTitle.label(appName: "Finder", title: "/Users/luke/personal"), "Finder — personal")
        XCTAssertEqual(WindowSwitcherTitle.label(appName: "Helium", title: "org/repo"), "Helium — org/repo")
    }

    func testAppNameIsNotRepeatedAndMultilineTitlesAreFlattened() {
        XCTAssertEqual(WindowSwitcherTitle.label(appName: "Zed", title: "project — Zed"), "Zed — project")
        XCTAssertEqual(WindowSwitcherTitle.label(appName: "Zed", title: "Zed - project"), "Zed - project")
        XCTAssertEqual(WindowSwitcherTitle.label(appName: "Zed", title: "project\nfile"), "Zed — project file")
    }
}
