// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
extension ShellVitreusDrawerTests {
    func testSwitchingLayoutsAfterADrawerClosedKeepsRenderingWithoutStaleCrests() throws {
        for path in [["seg", "ftop"], ["ftop", "island", "ftop"], ["ftop", "left", "ftop"], ["ftop", "fbottom"]] {
            let fixture = try fixture()
            VitreusFixture.settings(fixture.widget, ["layout": .string(path[0])])
            trigger(fixture, "drawer-calendar")
            advance(fixture, by: 1)
            trigger(fixture, "drawer-close")
            advance(fixture, by: 1)
            for layout in path.dropFirst() {
                VitreusFixture.settings(fixture.widget, ["layout": .string(layout)])
                show(fixture)
            }
            XCTAssertFalse(has(fixture, "drawer-ripple-calendar-close--1"), path.joined(separator: " > "))
            trigger(fixture, "drawer-calendar")
            XCTAssertTrue(has(fixture, "drawer-frame-calendar"), path.joined(separator: " > "))
        }
    }
}
