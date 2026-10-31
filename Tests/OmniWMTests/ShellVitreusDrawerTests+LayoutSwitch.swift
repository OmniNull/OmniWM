// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
extension ShellVitreusDrawerTests {
    func testTheVerticalClockAndTheIslandCalendarNeedNoRenderEachSecond() throws {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        for (layout, drawer) in [("left", nil), ("island", "drawer-calendar")] as [(String, String?)] {
            let widget = try ShellRenderedWidget(
                source: VitreusFixture.source(shell), resources: VitreusFixture.resources(shell)
            )
            VitreusFixture.settings(widget, ["layout": .string(layout)])
            VitreusFixture.show(widget)
            if let drawer {
                VitreusFixture.trigger(widget.instance, drawer, VitreusFixture.bar().monitorId)
                VitreusFixture.show(widget)
                XCTAssertNoThrow(try VitreusFixture.element(widget, key: "drawer-content-calendar"), layout)
            }
            VitreusFixture.show(widget)
            XCTAssertFalse(omni_instance_needs_render(widget.instance, OMNI_VIEW_BAR, ShellDataKey.seconds.bit), layout)
        }
    }

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

    func testAnOpenFrameDrawerStopsRenderingEachSecondOnceItsDropSettles() throws {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        for layout in ["ftop", "fbottom", "left", "right", "seg"] {
            let widget = try ShellRenderedWidget(
                source: VitreusFixture.source(shell), resources: VitreusFixture.resources(shell)
            )
            VitreusFixture.settings(widget, ["layout": .string(layout)])
            VitreusFixture.show(widget)
            _ = VitreusFixture.drain(widget)
            VitreusFixture.trigger(widget.instance, "drawer-calendar", VitreusFixture.bar().monitorId)
            VitreusFixture.show(widget)
            XCTAssertNoThrow(try VitreusFixture.element(widget, key: "drawer-frame-calendar"), layout)
            XCTAssertTrue(omni_instance_needs_render(widget.instance, OMNI_VIEW_BAR, ShellDataKey.seconds.bit), layout)
            let timers = VitreusFixture.drain(widget).filter { $0.kind == OMNI_SERVICE_TIMER && !$0.cancelled }
            XCTAssertEqual(timers.count, 1, layout)
            for timer in timers {
                VitreusFixture.complete(widget, timer)
            }
            VitreusFixture.show(widget)
            XCTAssertFalse(omni_instance_needs_render(widget.instance, OMNI_VIEW_BAR, ShellDataKey.seconds.bit), layout)
        }
    }

    func testOnlyTheLatestSettleTimerEndsTheOpenImpulsesAndTheSettledMorphMatchesTheClock() throws {
        let fixture = try fixture()
        VitreusFixture.settings(fixture.widget, ["layout": .string("ftop")])
        show(fixture)
        _ = VitreusFixture.drain(fixture.widget)
        trigger(fixture, "drawer-calendar")
        XCTAssertTrue(try morph(fixture, "drawer-frame-calendar").impulses.contains { $0.phase == .open })
        let first = try XCTUnwrap(VitreusFixture.drain(fixture.widget).first { $0.kind == OMNI_SERVICE_TIMER })
        trigger(fixture, "drawer-controls")
        let requests = VitreusFixture.drain(fixture.widget).filter { $0.kind == OMNI_SERVICE_TIMER }
        XCTAssertEqual(requests.filter(\.cancelled).map(\.id), [first.id])
        let second = try XCTUnwrap(requests.first { !$0.cancelled })
        VitreusFixture.complete(fixture.widget, first)
        show(fixture)
        XCTAssertTrue(try morph(fixture, "drawer-frame-controls").impulses.contains { $0.phase == .open })
        advance(fixture, by: 2 * second.seconds)
        show(fixture)
        let clocked = try morph(fixture, "drawer-frame-controls").impulses
        XCTAssertFalse(clocked.isEmpty)
        XCTAssertTrue(clocked.allSatisfy { $0.phase == .close })
        VitreusFixture.complete(fixture.widget, second)
        show(fixture)
        XCTAssertEqual(try morph(fixture, "drawer-frame-controls").impulses, clocked)
    }
}
