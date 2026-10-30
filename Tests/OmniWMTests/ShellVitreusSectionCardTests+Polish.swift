// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
extension ShellVitreusSectionCardTests {
    func pagesFixture() throws -> ShellVitreusDrawerTests.Fixture {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        let widget = try VitreusFixture.desk(shell)
        let fixture = ShellVitreusDrawerTests.Fixture(
            widget: widget, monitor: VitreusFixture.monitor(), clock: .init(), scene: widget.surface.scene
        )
        windows.seed(widget)
        widget.set("calendar") {
            ShellCalendar(access: "full", month: .init(
                title: "October 2026", year: 2026, month: 10, days: 31, offset: 3, today: 28,
                weekdays: ["M", "T", "W", "T", "F", "S", "S"], marked: [28]
            ), selectedDay: "2026-10-28").write(into: &$0)
        }
        windows.show(fixture)
        return fixture
    }

    func testReturnAppearanceIsConsumedAndLaterOpensRestoreTheNormalRise() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-calendar")
        try dragCard(fixture, "calendar-month", to: CGPoint(x: 100, y: 650))
        windows.trigger(fixture, "drawer-calendar")
        var target = try VitreusFixture.element(fixture.widget, key: "drawer-content-calendar-month")
        XCTAssertNotEqual(fixture.widget.surface.layout.core.paint(of: target).appear, 0)
        windows.show(fixture)
        XCTAssertEqual(fixture.widget.surface.layout.core.paint(of: target).appear, 0)
        windows.trigger(fixture, "drawer-calendar")
        windows.trigger(fixture, "drawer-calendar")
        target = try VitreusFixture.element(fixture.widget, key: "drawer-content-calendar-month")
        XCTAssertEqual(fixture.widget.surface.layout.core.paint(of: target).appear, 0)
        let rise = try VitreusFixture.element(fixture.widget, key: "card-rise-calendar-month")
        XCTAssertNotEqual(fixture.widget.surface.layout.core.paint(of: rise).appear, 0)
    }

    func testVisibleHomeSlotWinsOverTheOpenShelf() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-calendar")
        let home = try windows.frame(fixture, "drawer-content-calendar-month")
        try dragCard(fixture, "calendar-month", to: CGPoint(x: 100, y: 650))
        windows.shelfOpen = true
        windows.show(fixture)
        try dragCard(fixture, "calendar-month", to: CGPoint(x: home.minX + 20, y: home.minY + 20))
        let target = try VitreusFixture.element(fixture.widget, key: "drawer-content-calendar-month")
        XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: target), try VitreusFixture.element(
            fixture.widget, key: "drawer-content-calendar"
        ))
        windows.shelfOpen = false
        windows.show(fixture)
        XCTAssertTrue(windows.has(fixture, "drawer-content-calendar-month"))
    }

    func testCalendarPacksItsRemainingSectionsAndRetainsItsPermanentControls() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-calendar")
        try dragCard(fixture, "calendar-month", to: CGPoint(x: 100, y: 650))
        XCTAssertEqual(try windows.frame(fixture, "drawer-content-calendar").height, 295 * 1.5525, accuracy: 0.01)
        try dragCard(fixture, "calendar-events", to: CGPoint(x: 650, y: 650))
        let panel = try windows.frame(fixture, "drawer-content-calendar")
        XCTAssertEqual(panel.height, 213 * 1.5525, accuracy: 0.01)
        for key in ["calendar-clock", "calendar-weather-plate", "calendar-add"] {
            let frame = try windows.frame(fixture, key)
            XCTAssertTrue(panel.insetBy(dx: -0.01, dy: -0.01).contains(frame), key)
        }
        windows.trigger(fixture, "drawer-calendar")
        XCTAssertEqual(try windows.frame(fixture, "drawer-content-calendar").height, 373 * 1.5525, accuracy: 0.01)
    }

    func testDropdownAndCapturedSectionsStayAboveShelfPagesAndFloatingCards() throws {
        let fixture = try pagesFixture()
        windows.shelfOpen = true
        windows.show(fixture)
        windows.trigger(fixture, "drawer-calendar")
        let day = try windows.frame(fixture, "calendar-day-2026-10-28")
        XCTAssertEqual(fixture.widget.surface.command(at: CGPoint(x: day.midX, y: day.midY)), "calendar day 2026-10-28")
        try dragCard(fixture, "page-pad", to: CGPoint(x: 100, y: 450))
        let point = try windows.grab(fixture, id: "calendar-month", to: CGPoint(x: 100, y: 450))
        let parent = try VitreusFixture.element(fixture.widget, key: "drawer-content-calendar")
        let pad = try VitreusFixture.element(fixture.widget, key: "drawer-content-page-pad")
        try ShellLayerScene.engineQueue.sync {
            let front = try XCTUnwrap(fixture.scene.displayedLayer(parent.slot))
            let behind = try XCTUnwrap(fixture.scene.displayedLayer(pad.slot))
            XCTAssertTrue(front.superlayer === behind.superlayer)
            let siblings = try XCTUnwrap(front.superlayer?.sublayers)
            XCTAssertGreaterThan(
                try XCTUnwrap(siblings.firstIndex(of: front)),
                try XCTUnwrap(siblings.firstIndex(of: behind))
            )
        }
        windows.drop(fixture, at: point)
    }

    func testFloatingAlbumRemainsGrabbableAboveTheDesk() throws {
        let fixture = try pagesFixture()
        windows.trigger(fixture, "drawer-player")
        try moveCard(fixture, id: "player-album", to: CGPoint(x: 1500, y: 450))
        XCTAssertTrue(windows.has(fixture, "desk"))
        try moveCard(fixture, id: "player-album", to: CGPoint(x: 1450, y: 500))
        XCTAssertEqual(try windows.frame(fixture, "media-card").minY, 500, accuracy: 0.01)
    }

    func testASectionLeavingAShelvedPanelRestoresItsNaturalScale() throws {
        let fixture = try pagesFixture()
        windows.trigger(fixture, "drawer-calendar")
        let natural = try windows.frame(fixture, "drawer-content-calendar-month").width
        windows.shelfOpen = true
        windows.show(fixture)
        try windows.store(fixture, id: "calendar")
        windows.trigger(fixture, "drawer-controls")
        try windows.store(fixture, id: "controls")
        XCTAssertLessThan(try windows.frame(fixture, "drawer-content-calendar-month").width, natural)
        try dragCard(fixture, "calendar-month", to: CGPoint(x: 100, y: 650))
        XCTAssertEqual(try windows.frame(fixture, "drawer-content-calendar-month").width, natural, accuracy: 0.01)
    }

    func testPinningAnAlbumBringsItsStoredPlayerOutOfAClosedShelf() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-player")
        try moveCard(fixture, id: "player-album", to: CGPoint(x: 100, y: 650))
        windows.shelfOpen = true
        windows.show(fixture)
        try windows.store(fixture, id: "player")
        windows.shelfOpen = false
        windows.show(fixture)
        XCTAssertFalse(windows.has(fixture, "drawer-content-player"))
        _ = try windows.invoke(fixture, "media-card-pin")
        let parent = try VitreusFixture.element(fixture.widget, key: "drawer-content-player")
        let album = try VitreusFixture.element(fixture.widget, key: "media-card")
        XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: album), parent)
        XCTAssertEqual(try windows.frame(fixture, "drawer-content-player").minY, 62, accuracy: 0.01)
        windows.trigger(fixture, "drawer-player")
        XCTAssertFalse(windows.has(fixture, "drawer-content-player"))
    }

    func testExposedMixerSitsBelowThePostToggleSlidersAndReturnsHomeOnClose() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-controls")
        try dragCard(fixture, "controls-sliders", to: CGPoint(x: 1000, y: 400))
        _ = try windows.invoke(fixture, "controls-mixer-toggle")
        let sliders = try windows.frame(fixture, "drawer-content-controls-sliders")
        let mixer = try windows.frame(fixture, "drawer-content-controls-mixer")
        XCTAssertGreaterThanOrEqual(mixer.minY, sliders.maxY)
        XCTAssertFalse(windows.has(fixture, "card-slot-controls-mixer"))
        _ = try windows.invoke(fixture, "controls-mixer-toggle")
        XCTAssertFalse(windows.has(fixture, "drawer-content-controls-mixer"))
        _ = try windows.invoke(fixture, "controls-mixer-toggle")
        XCTAssertTrue(windows.has(fixture, "drawer-content-controls-mixer"))
    }

    func testTheTilesGripStaysEntirelyInsideTheRowGap() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-controls")
        let grip = try windows.frame(fixture, "window-grip-controls-toggles")
        for key in ["controls-tile-wifi", "controls-tile-caffeine", "controls-tile-notifications"] {
            XCTAssertLessThanOrEqual(try windows.frame(fixture, key).maxY, grip.minY + 0.01)
        }
        for key in ["controls-tile-bluetooth", "controls-tile-capture", "controls-tile-power"] {
            XCTAssertGreaterThanOrEqual(try windows.frame(fixture, key).minY, grip.maxY - 0.01)
        }
    }

    func testRemovedAlbumCancellationClearsItsHeldGlassBeforeReopening() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-player")
        let grab = try windows.frame(fixture, "media-card-grab")
        let begin = CGPoint(x: grab.midX, y: grab.midY)
        var index = fixture.widget.events.count
        fixture.widget.surface.press(at: begin)
        fixture.widget.surface.drag(to: CGPoint(x: begin.x + 150, y: begin.y + 200), screen: .zero)
        windows.deliver(fixture, from: index)
        XCTAssertNotNil(fixture.widget.surface.manipulation)
        index = fixture.widget.events.count
        windows.trigger(fixture, "drawer-close")
        XCTAssertNil(fixture.widget.surface.manipulation)
        windows.deliver(fixture, from: index)
        windows.trigger(fixture, "drawer-player")
        XCTAssertFalse(windows.has(fixture, "media-card-glass"))
        XCTAssertTrue(windows.has(fixture, "media-card-grab"))
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    func testFocusingARowFromADetachedListDoesNotRedockItsFloatingPlayer() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-player")
        try windows.move(fixture, id: "player", to: CGPoint(x: 100, y: 400))
        try dragCard(fixture, "player-windows", to: CGPoint(x: 900, y: 600))
        let before = try windows.frame(fixture, "drawer-content-player")
        var bar = VitreusFixture.bar(fixture.monitor)
        bar.workspaces = [.init(id: "1", name: "1", focused: true, windows: [.init(
            id: "app", bundle: "test.app", name: "App", focused: true, count: 1, hidden: 0,
            windows: [.init(id: "one", title: "Document", focused: true, hidden: false)]
        )])]
        fixture.widget.render(bar)
        let row = try VitreusFixture.element(fixture.widget, key: "player-task-one")
        let action = fixture.widget.surface.layout.core.content(of: row).pressAction
        var event = ShellEvent()
        event.phase = .down
        XCTAssertEqual(fixture.widget.invoke(action, event: event), ["window focus one"])
        windows.show(fixture)
        XCTAssertEqual(try windows.frame(fixture, "drawer-content-player").origin, before.origin)
        XCTAssertTrue(windows.has(fixture, "drawer-content-player-windows"))
    }
}

@MainActor
extension ShellVitreusMediaCardTests {
    func testFrameTitleClickStillClosesThePlayerAndLeavesAFloatingAlbumOut() throws {
        let fixture = try fixture()
        VitreusFixture.settings(fixture.widget, ["layout": .string("ftop")])
        show(fixture)
        try float(fixture, by: CGVector(dx: -400, dy: 350))
        VitreusFixture.trigger(fixture.widget.instance, "drawer-player", fixture.bar.monitorId)
        show(fixture)
        XCTAssertFalse(has(fixture, "drawer-content-player"))
        XCTAssertTrue(has(fixture, "media-card-glass"))
    }

    func testAnAlbumGrabReleasedInsideTheVisiblePlayerDocksDespiteItsOffset() throws {
        let fixture = try fixture()
        try float(fixture, by: CGVector(dx: -600, dy: 400))
        let parent = try frame(fixture, "drawer-content-player")
        let grab = try cover(fixture)
        drag(fixture, at: grab, by: CGVector(dx: parent.midX - grab.x, dy: parent.midY - grab.y))
        XCTAssertFalse(has(fixture, "media-card-glass"))
        Self.assertRect(try frame(fixture, "media-card"), try docked(fixture))
    }
}

@MainActor
extension ShellVitreusDockTests {
    func testWindowContentDoesNotInterceptCornerGesturesOutsideItsBounds() throws {
        let widget = try island(["pins": .strings([Self.safari, Self.notes]), "addons": .strings(["pad", "notes"])])
        VitreusFixture.trigger(widget.instance, "drawer-calendar", VitreusFixture.bar().monitorId)
        VitreusFixture.show(widget)
        let frame = try VitreusFixture.frame(widget, key: "dock-pill")
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let end = CGPoint(x: start.x + 1300, y: start.y - 200)
        var index = widget.events.count
        widget.surface.press(at: start, timestamp: 0)
        widget.surface.drag(to: end, screen: .zero, timestamp: 0.01)
        XCTAssertNotNil(widget.surface.manipulation)
        _ = deliver(widget, from: index)
        index = widget.events.count
        widget.surface.release(at: end, timestamp: 0.02)
        XCTAssertEqual(deliver(widget, from: index), ["shell trigger vitreus dock-corner 1"])
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    func testTheDeskLabelTracksAPagesActualLocation() throws {
        let fixture = try pagesFixture()
        windows.shelfOpen = true
        windows.show(fixture)
        _ = try windows.invoke(fixture, "tab-pad")
        XCTAssertTrue(fixture.widget.strings().contains { $0.hasSuffix("is on the top shelf") })
        try dragCard(fixture, "page-pad", to: CGPoint(x: 100, y: 350))
        XCTAssertTrue(fixture.widget.strings().contains { $0.hasSuffix("is in a floating card") })
        try dragCard(fixture, "page-pad", to: CGPoint(x: 0, y: 350))
        XCTAssertTrue(fixture.widget.strings().contains { $0.hasSuffix("is on the left edge") })
    }
}
