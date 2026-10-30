// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
extension ShellVitreusDrawerTests {
    func testOnlyTheSegControlsDrawerDropsTheWobbleAndShrinksAwayOverItsLastFewPercent() throws {
        let wobble: [Double] = [220, -260, -520, 300, -160]
        for (layout, name) in [("seg", "controls"), ("seg", "calendar"), ("ftop", "controls")] {
            let label = layout + " " + name
            let fixture = try fixture()
            VitreusFixture.settings(fixture.widget, ["layout": .string(layout)])
            trigger(fixture, "drawer-" + name)
            let recipe = try morph(fixture, "drawer-frame-" + name)
            let tail = layout == "seg" && name == "controls"
            XCTAssertEqual(recipe.impulses.map(\.velocity), tail ? [220] : wobble, label)
            XCTAssertEqual(recipe.impulses.first?.pivot, .anchor, label)
            for stop in recipe.stops {
                let shrink = tail ? min(1, max(0, 16 * stop.at - 0.1)) : 1
                let settled = min(1, stop.at)
                XCTAssertEqual(stop.width, (1 - 0.28 * settled * (1 - settled)) * shrink, accuracy: 1e-5, label)
                XCTAssertEqual(stop.height, shrink, accuracy: 1e-5, label)
            }
            XCTAssertEqual(recipe.stop(at: 0.0625).height, tail ? 0.9 : 1, accuracy: 1e-5, label)
        }
    }
}
