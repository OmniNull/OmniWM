// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
extension ShellVitreusSectionCardTests {
    func dropCard(_ fixture: ShellVitreusDrawerTests.Fixture, _ id: String, on point: CGPoint) throws {
        let grip = try windows.frame(fixture, "window-grip-" + id)
        let index = fixture.widget.events.count
        fixture.widget.surface.press(at: CGPoint(x: grip.midX, y: grip.midY), timestamp: 0)
        fixture.widget.surface.drag(to: point, screen: .zero, timestamp: 0.01)
        windows.deliver(fixture, from: index)
        XCTAssertNotNil(fixture.widget.surface.manipulation)
        windows.drop(fixture, at: point)
    }

    func testARetractedParentAcceptsItsSectionAnywhereBeforeTheOpenShelf() throws {
        for (owner, id) in [("calendar", "calendar-month"), ("player", "player-windows")] {
            let fixture = try windows.fixture()
            if owner == "player" {
                var bar = VitreusFixture.bar(fixture.monitor)
                bar.workspaces = [.init(id: "1", name: "1", focused: true, windows: [.init(
                    id: "app", bundle: "test.app", name: "App", focused: true, count: 2, hidden: 0,
                    windows: ["one", "two"].map { .init(id: $0, title: $0, focused: false, hidden: false) }
                )])]
                windows.barOverride = bar
            }
            windows.trigger(fixture, "drawer-" + owner)
            try dragCard(fixture, id, to: CGPoint(x: 100, y: 650))
            windows.shelfOpen = true
            windows.show(fixture)
            let parent = try windows.frame(fixture, "drawer-content-" + owner)
            try dropCard(fixture, id, on: CGPoint(x: parent.minX + 20, y: parent.minY + 20))
            let card = try VitreusFixture.element(fixture.widget, key: "drawer-content-" + id)
            XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: card), try VitreusFixture.element(
                fixture.widget, key: "drawer-content-" + owner
            ))
            windows.shelfOpen = false
            windows.show(fixture)
            XCTAssertTrue(windows.has(fixture, "drawer-content-" + id))
            windows.barOverride = nil
        }
    }

    func testShelfPagesAndStoredSectionsStayBelowTheDeskAndItsOpener() throws {
        let fixture = try pagesFixture()
        windows.trigger(fixture, "drawer-calendar")
        try dragCard(fixture, "calendar-month", to: CGPoint(x: 100, y: 650))
        windows.shelfOpen = true
        windows.show(fixture)
        let shelf = try windows.frame(fixture, "window-shelf")
        try dropCard(fixture, "calendar-month", on: CGPoint(x: shelf.minX + 15, y: 25))
        let lower = try ["window-shelf", "drawer-content-page-pad", "drawer-content-calendar-month"].map {
            try VitreusFixture.element(fixture.widget, key: $0)
        }
        let upper = try ["desk-opener", "desk", "drawer-content-calendar"].map {
            try VitreusFixture.element(fixture.widget, key: $0)
        }
        try ShellLayerScene.engineQueue.sync {
            for below in lower {
                let layer = try XCTUnwrap(fixture.scene.displayedLayer(below.slot))
                let siblings = try XCTUnwrap(layer.superlayer?.sublayers)
                for above in upper {
                    let front = try XCTUnwrap(fixture.scene.displayedLayer(above.slot))
                    XCTAssertTrue(front.superlayer === layer.superlayer)
                    XCTAssertLessThan(
                        try XCTUnwrap(siblings.firstIndex(of: layer)),
                        try XCTUnwrap(siblings.firstIndex(of: front))
                    )
                }
            }
        }
    }

    func testAnArrivalExpiresWhenDetailsOrMixerOffHidesItsCardForOneRender() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-controls")
        try dragCard(fixture, "controls-toggles", to: CGPoint(x: 100, y: 500))
        _ = try windows.invoke(fixture, "controls-tile-power")
        windows.trigger(fixture, "drawer-controls")
        XCTAssertFalse(windows.has(fixture, "drawer-content-controls-toggles"))
        _ = try windows.invoke(fixture, "controls-back")
        let toggles = try VitreusFixture.element(fixture.widget, key: "drawer-content-controls-toggles")
        XCTAssertEqual(fixture.widget.surface.layout.core.paint(of: toggles).appear, 0)
        _ = try windows.invoke(fixture, "controls-mixer-toggle")
        try dragCard(fixture, "controls-mixer", to: CGPoint(x: 100, y: 600))
        _ = try windows.invoke(fixture, "controls-mixer-toggle")
        XCTAssertFalse(windows.has(fixture, "drawer-content-controls-mixer"))
        _ = try windows.invoke(fixture, "controls-mixer-toggle")
        let mixer = try VitreusFixture.element(fixture.widget, key: "drawer-content-controls-mixer")
        XCTAssertEqual(fixture.widget.surface.layout.core.paint(of: mixer).appear, 0)
    }

    func testAReturningSectionSubtractsItsParentsTravelFromTheArrival() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-calendar")
        try windows.move(fixture, id: "calendar", to: CGPoint(x: 100, y: 400))
        try dragCard(fixture, "calendar-month", to: CGPoint(x: 1100, y: 600))
        let oldParent = try windows.frame(fixture, "drawer-content-calendar")
        let oldCard = try windows.frame(fixture, "drawer-content-calendar-month")
        windows.trigger(fixture, "drawer-calendar")
        let parent = try windows.frame(fixture, "drawer-content-calendar")
        let card = try VitreusFixture.element(fixture.widget, key: "drawer-content-calendar-month")
        let rect = try windows.frame(fixture, "drawer-content-calendar-month")
        let paint = fixture.widget.surface.layout.core.paint(of: card)
        let appear = try XCTUnwrap(fixture.widget.surface.presence(paint.appear, for: card))
        XCTAssertEqual(appear.offset.x, oldCard.minX - rect.minX - (oldParent.minX - parent.minX), accuracy: 0.01)
        XCTAssertEqual(appear.offset.y, oldCard.minY - rect.minY - (oldParent.minY - parent.minY), accuracy: 0.01)
    }

    func testTheOutAlbumAndItsStickyPiecesShareTheDeskGlassBody() throws {
        let fixture = try pagesFixture()
        windows.trigger(fixture, "drawer-player")
        try moveCard(fixture, id: "player-album", to: CGPoint(x: 1300, y: 400))
        try moveCard(fixture, id: "player-album", to: CGPoint(x: 1920 - 308 * 1.5525, y: 400))
        let body = try VitreusFixture.element(fixture.widget, key: "desk-glass")
        for key in ["media-card-glass", "player-album-card-lip", "player-album-card-bulge"] {
            let shape = try VitreusFixture.element(fixture.widget, key: key)
            XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: shape), body)
        }
    }

    func testMovingAResizedAlbumDoesNotResetItsScaleWhenItsParentIsStored() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-player")
        try moveCard(fixture, id: "player-album", to: CGPoint(x: 100, y: 500))
        let resize = try windows.frame(fixture, "media-card-resize-se")
        let begin = CGPoint(x: resize.midX, y: resize.midY)
        let index = fixture.widget.events.count
        fixture.widget.surface.press(at: begin, timestamp: 0)
        fixture.widget.surface.drag(to: CGPoint(x: begin.x - 600, y: begin.y - 600), screen: .zero, timestamp: 0.01)
        windows.deliver(fixture, from: index)
        windows.drop(fixture, at: CGPoint(x: begin.x - 600, y: begin.y - 600))
        let width = try windows.frame(fixture, "media-card").width
        XCTAssertEqual(width, 154 * 1.5525, accuracy: 0.01)
        windows.shelfOpen = true
        windows.show(fixture)
        try windows.store(fixture, id: "player")
        windows.shelfOpen = false
        windows.show(fixture)
        try moveCard(fixture, id: "player-album", to: CGPoint(x: 200, y: 500))
        XCTAssertEqual(try windows.frame(fixture, "media-card").width, width, accuracy: 0.01)
    }

    func testMixerOpensAboveBottomSlidersAndDetailsClosesItConsistently() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-controls")
        let card = try windows.frame(fixture, "drawer-content-controls-sliders")
        try dragCard(fixture, "controls-sliders", to: CGPoint(x: 1000, y: 1080 - card.height))
        _ = try windows.invoke(fixture, "controls-mixer-toggle")
        let sliders = try windows.frame(fixture, "drawer-content-controls-sliders")
        let mixer = try windows.frame(fixture, "drawer-content-controls-mixer")
        XCTAssertLessThanOrEqual(mixer.maxY, sliders.minY)
        _ = try windows.invoke(fixture, "controls-tile-power")
        XCTAssertFalse(windows.has(fixture, "drawer-content-controls-mixer"))
        _ = try windows.invoke(fixture, "controls-back")
        _ = try windows.invoke(fixture, "controls-mixer-toggle")
        XCTAssertTrue(windows.has(fixture, "drawer-content-controls-mixer"))
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    func testFocusingANestedListKeepsTheWholeFloatingPlayerAndDismissesTheOpenDropdown() throws {
        let fixture = try windows.fixture()
        var bar = VitreusFixture.bar(fixture.monitor)
        bar.workspaces = [.init(id: "1", name: "1", focused: true, windows: [.init(
            id: "app", bundle: "test.app", name: "App", focused: true, count: 2, hidden: 0,
            windows: ["one", "two"].map { .init(id: $0, title: $0, focused: false, hidden: false) }
        )])]
        windows.barOverride = bar
        windows.trigger(fixture, "drawer-player")
        try windows.move(fixture, id: "player", to: CGPoint(x: 100, y: 400))
        let before = try windows.frame(fixture, "drawer-content-player")
        windows.trigger(fixture, "drawer-calendar")
        omni_instance_clear_messages(fixture.widget.instance)
        let row = try VitreusFixture.element(fixture.widget, key: "player-task-one")
        var event = ShellEvent()
        event.phase = .down
        XCTAssertEqual(fixture.widget.invoke(
            fixture.widget.surface.layout.core.content(of: row).pressAction,
            event: event
        ), ["window focus one"])
        windows.show(fixture)
        XCTAssertEqual(try windows.frame(fixture, "drawer-content-player").origin, before.origin)
        XCTAssertFalse(windows.has(fixture, "drawer-content-calendar"))
    }
}
