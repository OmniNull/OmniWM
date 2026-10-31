// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
extension ShellVitreusDrawerTests {
    func testBeatCrestsLeaveThePlayerControlsOnTheBarsLowerEdgeOnlyWithTheVisualiser() throws {
        let fixture = try fixture(animations: true)
        let crests = VitreusFixture.crests("beat", phase: "close")
        fixture.widget.set("media") { ShellMedia(title: "Song", app: "Music", playing: true).write(into: &$0) }
        show(fixture)
        XCTAssertFalse(crests.contains { has(fixture, $0) })
        VitreusFixture.settings(fixture.widget, ["visualiser": .bool(true)])
        show(fixture)
        let pill = try VitreusFixture.frame(fixture.widget, key: "shell")
        let player = try VitreusFixture.frame(fixture.widget, key: "title-play")
        for name in crests {
            let morph = try morph(fixture, name)
            XCTAssertTrue(morph.beat, name)
            XCTAssertNil(morph.trigger, name)
            let frame = try VitreusFixture.frame(fixture.widget, key: name)
            XCTAssertEqual(frame.midX, player.midX, accuracy: Double(Float(player.midX).ulp), name)
            XCTAssertEqual(frame.midY, pill.maxY, accuracy: Double(Float(pill.maxY).ulp), name)
        }
        trigger(fixture, "drawer-calendar")
        XCTAssertFalse(crests.contains { has(fixture, $0) })
        trigger(fixture, "drawer-close")
        XCTAssertTrue(crests.allSatisfy { has(fixture, $0) })
        for (layout, shown) in [("left", false), ("seg", false), ("ftop", true)] {
            VitreusFixture.settings(fixture.widget, ["visualiser": .bool(true), "layout": .string(layout)])
            show(fixture)
            XCTAssertEqual(crests.filter { has(fixture, $0) }.count, shown ? crests.count : 0, layout)
        }
    }
}
