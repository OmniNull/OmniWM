// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import QuartzCore
import XCTest

@MainActor
extension ShellVitreusDrawerTests {
    func testAnIslandCloseRingsFromThePillAtTheCloseWobblesCrossing() throws {
        let fixture = try fixture(animations: true)
        let crests = VitreusFixture.crests("island", phase: "close")
        _ = VitreusFixture.drain(fixture.widget)
        trigger(fixture, "drawer-calendar")
        XCTAssertFalse(crests.contains { has(fixture, $0) })
        let wobble = try XCTUnwrap(morph(fixture, "drawer").impulses.first { $0.phase == .close })
        let drawer = try handle(fixture, "drawer").slot
        let opening = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.scene.shapeTracks.entries[drawer]?.plan)
        }
        advance(fixture, by: opening.duration)
        trigger(fixture, "drawer-close")
        let carrier = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.scene.shapeTracks.entries.values.first { $0.carrier != nil })
        }
        let crossing = try XCTUnwrap(carrier.plan?.crossings(at: wobble.time, rising: false).first)
        for name in crests {
            let trigger = try XCTUnwrap(morph(fixture, name).trigger)
            XCTAssertEqual(trigger.shape, VitreusFixture.key("drawer"), name)
            XCTAssertEqual(trigger.at, wobble.time, name)
            XCTAssertFalse(trigger.rising, name)
            let slot = try handle(fixture, name).slot
            let entry = try ShellLayerScene.engineQueue.sync {
                try XCTUnwrap(fixture.scene.shapeTracks.entries[slot])
            }
            XCTAssertEqual(entry.plan?.begin, crossing, name)
        }
        XCTAssertFalse(VitreusFixture.drain(fixture.widget).contains { $0.kind == OMNI_SERVICE_TIMER })
        show(fixture)
        XCTAssertTrue(crests.allSatisfy { has(fixture, $0) })
        trigger(fixture, "drawer-calendar")
        XCTAssertFalse(crests.contains { has(fixture, $0) })
        trigger(fixture, "drawer-close")
        XCTAssertTrue(crests.allSatisfy { has(fixture, $0) })
        for layout in ["ftop", "island"] {
            VitreusFixture.settings(fixture.widget, ["layout": .string(layout)])
            show(fixture)
        }
        XCTAssertFalse(crests.contains { has(fixture, $0) })
    }
}
