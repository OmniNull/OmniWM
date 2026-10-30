// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellVitreusSectionCardTests: XCTestCase {
    let windows = ShellVitreusWindowShelfTests()

    func testMonthCardKeepsItsCaptureUntilReleaseAndFollowsItsPanelNatively() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-calendar")
        let card = try VitreusFixture.element(fixture.widget, key: "drawer-content-calendar-month")
        let parent = fixture.widget.surface.layout.core.parent(of: card)
        let home = try windows.frame(fixture, "drawer-content-calendar-month")
        let point = try windows.grab(fixture, id: "calendar-month", to: CGPoint(x: 150, y: 650))
        XCTAssertEqual(try VitreusFixture.element(fixture.widget, key: "drawer-content-calendar-month"), card)
        XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: card), parent)
        windows.drop(fixture, at: point)
        let detached = try windows.frame(fixture, "drawer-content-calendar-month")
        XCTAssertEqual(detached.minX, 150, accuracy: 0.01)
        XCTAssertEqual(detached.minY, 650, accuracy: 0.01)
        XCTAssertTrue(windows.has(fixture, "calendar-day-2026-10-28"))
        XCTAssertFalse(windows.has(fixture, "card-slot-calendar-month"))
        try windows.move(fixture, id: "calendar", to: CGPoint(x: 800, y: 400))
        ShellVitreusMediaCardTests.assertRect(try windows.frame(fixture, "drawer-content-calendar-month"), detached)
        windows.trigger(fixture, "drawer-calendar")
        ShellVitreusMediaCardTests.assertRect(try windows.frame(fixture, "drawer-content-calendar-month"), home)
        XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: try VitreusFixture.element(
            fixture.widget, key: "drawer-content-calendar-month"
        )), try VitreusFixture.element(fixture.widget, key: "drawer-content-calendar"))
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    func dragCard(_ fixture: ShellVitreusDrawerTests.Fixture, _ id: String, to point: CGPoint) throws {
        windows.drop(fixture, at: try windows.grab(fixture, id: id, to: point))
    }

    func testSectionsFloatStoreExtractAndReturnToTheirMovedOwningPanel() throws {
        for (owner, id) in [
            ("calendar", "calendar-month"), ("calendar", "calendar-events"),
            ("controls", "controls-toggles"), ("controls", "controls-sliders"),
            ("controls", "controls-mixer"), ("player", "player-windows")
        ] {
            windows.shelfOpen = false
            let fixture = try windows.fixture()
            windows.trigger(fixture, "drawer-" + owner)
            if id == "controls-mixer" { try windows.invoke(fixture, "controls-mixer-toggle") }
            fixture.widget.set("brightness") { ShellBrightness(value: 60, available: true).write(into: &$0) }
            windows.show(fixture)
            let target = "drawer-content-" + id
            let home = try windows.frame(fixture, target)
            let parent = try windows.frame(fixture, "drawer-content-" + owner)
            try dragCard(fixture, id, to: CGPoint(x: 100, y: 400))
            XCTAssertFalse(windows.has(fixture, "card-slot-" + id))
            let floating = try windows.frame(fixture, target)
            XCTAssertEqual(floating.minX, 100, accuracy: 0.01, id)
            let parentAfter = try windows.frame(fixture, "drawer-content-" + owner)
            XCTAssertEqual(parentAfter.width, parent.width, id)
            XCTAssertEqual(parentAfter.height, retractedHeight(id) * 1.5525, accuracy: 0.01, id)
            windows.shelfOpen = true
            windows.show(fixture)
            let shelf = try windows.frame(fixture, "window-shelf")
            let grip = try windows.frame(fixture, "window-grip-" + id)
            let card = try windows.frame(fixture, target)
            try dragCard(
                fixture,
                id,
                to: CGPoint(x: shelf.minX + 15 - floating.width / 2, y: 20 - grip.midY + card.minY)
            )
            windows.shelfOpen = false
            windows.show(fixture)
            XCTAssertFalse(windows.has(fixture, target), id)
            try windows.move(fixture, id: owner, to: CGPoint(x: 900, y: 550))
            windows.shelfOpen = true
            windows.show(fixture)
            try dragCard(fixture, id, to: CGPoint(x: 100, y: 600))
            windows.shelfOpen = false
            windows.show(fixture)
            try windows.move(fixture, id: owner, to: CGPoint(x: 900, y: 400))
            let moved = try windows.frame(fixture, "drawer-content-" + owner)
            let slot = CGPoint(x: moved.minX + home.minX - parent.minX, y: moved.minY + home.minY - parent.minY)
            try dragCard(fixture, id, to: slot)
            let handle = try VitreusFixture.element(fixture.widget, key: target)
            XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: handle), try VitreusFixture.element(
                fixture.widget, key: "drawer-content-" + owner
            ), id)
            XCTAssertEqual(try windows.frame(fixture, target).minX, slot.x, accuracy: 0.01, id)
        }
    }

    func testEdgeHoverOpensTheShelfDuringACapturedDragAndTheDropStoresTheSection() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-calendar")
        let initialCard = try windows.frame(fixture, "drawer-content-calendar-month")
        let initialGrip = try windows.frame(fixture, "window-grip-calendar-month")
        var point = try windows.grab(fixture, id: "calendar-month", to: CGPoint(
            x: 750, y: initialCard.minY - initialGrip.midY
        ))
        var config = ShellDrawerConfig(id: "shelf", edge: .top, widgets: [], hover: true)
        config.island = true
        config.width = 900
        config.closesOnLeave = true
        var hover = ShellEdgeHover()
        let screenPoint = CGPoint(x: point.x, y: fixture.monitor.frame.maxY - point.y)
        XCTAssertEqual(hover.update(
            pointer: screenPoint, drawers: [config], monitors: [fixture.monitor], buttonsDown: true,
            open: nil, islandDragging: fixture.widget.surface.manipulation != nil
        ), .open(drawer: "shelf", monitor: fixture.monitor.id))
        windows.shelfOpen = true
        windows.show(fixture)
        XCTAssertNotNil(fixture.widget.surface.manipulation)
        let shelf = try windows.frame(fixture, "window-shelf")
        point = CGPoint(x: shelf.minX + 15, y: 100)
        fixture.widget.surface.drag(to: point, screen: .zero, timestamp: 0.015)
        XCTAssertNil(hover.update(
            pointer: CGPoint(x: point.x, y: fixture.monitor.frame.maxY - point.y), drawers: [config],
            monitors: [fixture.monitor], buttonsDown: true,
            open: .init(drawer: config, region: nil, islandRegions: [])
        ))
        windows.drop(fixture, at: point)
        windows.shelfOpen = false
        windows.show(fixture)
        XCTAssertFalse(windows.has(fixture, "drawer-content-calendar-month"))
        windows.shelfOpen = true
        windows.show(fixture)
        XCTAssertTrue(windows.has(fixture, "drawer-content-calendar-month"))
    }

    private func cycleFocus(_ fixture: ShellVitreusDrawerTests.Fixture, within focusTarget: ElementHandle) throws {
        let widget = fixture.widget
        let start = try XCTUnwrap(widget.surface.layout.core.elements { $0.action != 0 }.first {
            widget.surface.layout.core.key(of: $0) == VitreusFixture.key("start") && widget.surface.isWithin(
                $0,
                focusTarget
            )
        })
        for expected in ["PAUSED", "FOCUSING"] {
            let rect = CGRect(widget.surface.presentedFrame(of: start))
            let point = CGPoint(x: rect.midX, y: rect.midY)
            let index = widget.events.count
            widget.surface.press(at: point)
            widget.surface.release(at: point)
            windows.deliver(fixture, from: index)
            XCTAssertTrue(widget.strings().contains(expected))
        }
    }

    func testShelfPagesHaveOneStableMountAndPreserveTheirDraftAndTimer() throws {
        let shell = try VitreusFixture.shell()
        defer { VitreusFixture.remove(shell) }
        let widget = try VitreusFixture.desk(shell)
        let fixture = ShellVitreusDrawerTests.Fixture(
            widget: widget, monitor: VitreusFixture.monitor(), clock: .init(), scene: widget.surface.scene
        )
        let originalStart = try VitreusFixture.element(widget, key: "start")
        widget.invoke(widget.surface.layout.core.content(of: originalStart).action)
        VitreusFixture.show(widget)
        XCTAssertTrue(widget.strings().contains("FOCUSING"))
        windows.seed(widget)
        windows.shelfOpen = true
        windows.show(fixture)
        XCTAssertTrue(widget.strings().contains("Focus is on the top shelf"))
        XCTAssertTrue(widget.strings().contains("FOCUSING"))
        let target = try VitreusFixture.element(widget, key: "drawer-content-page-pad")
        let parent = widget.surface.layout.core.parent(of: target)
        let entry = widget.surface.layout.core.elements { $0.action != 0 }.first {
            widget.surface.isWithin($0, target) && widget.surface.layout.core.kind(of: $0) == .input
        }
        var event = ShellEvent()
        event.text = "Keep this draft while floating"
        widget.invoke(widget.surface.layout.core.content(of: try XCTUnwrap(entry)).action, event: event)
        windows.show(fixture)
        try dragCard(fixture, "page-pad", to: CGPoint(x: 100, y: 300))
        XCTAssertEqual(try VitreusFixture.element(widget, key: "drawer-content-page-pad"), target)
        XCTAssertEqual(widget.surface.layout.core.parent(of: target), parent)
        XCTAssertTrue(widget.strings().contains("Keep this draft while floating"))
        let focusTarget = try VitreusFixture.element(widget, key: "drawer-content-page-focus")
        try cycleFocus(fixture, within: focusTarget)
        windows.shelfOpen = false
        windows.show(fixture)
        XCTAssertTrue(windows.has(fixture, "drawer-content-page-pad"))
        let focus = try windows.frame(fixture, "drawer-content-page-focus")
        XCTAssertLessThan(focus.maxX, 0)
        XCTAssertFalse(widget.surface.islandRegions().contains { $0.contains(CGPoint(x: 1800, y: 900)) })
        windows.shelfOpen = true
        windows.show(fixture)
        let all = widget.surface.layout.core.elements { _ in true }
        for id in ["pad", "focus"] {
            XCTAssertEqual(all.count { widget.surface.layout.core.key(of: $0) == VitreusFixture.key(id) }, 1)
        }
        XCTAssertTrue(widget.strings().contains("Keep this draft while floating"))
        XCTAssertTrue(widget.strings().contains("FOCUSING"))
        XCTAssertEqual(try VitreusFixture.element(widget, key: "drawer-content-page-focus"), focusTarget)
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    func testFloatingControlsKeepTheirDetailsAndOpenTheMixerBesideTheSliders() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-controls")
        try dragCard(fixture, "controls-toggles", to: CGPoint(x: 100, y: 400))
        try dragCard(fixture, "controls-sliders", to: CGPoint(x: 1000, y: 400))
        windows.trigger(fixture, "drawer-calendar")
        XCTAssertFalse(windows.has(fixture, "drawer-content-controls"))
        try windows.invoke(fixture, "controls-mixer-toggle")
        XCTAssertTrue(windows.has(fixture, "drawer-content-controls-mixer"))
        XCTAssertTrue(windows.has(fixture, "controls-apps-empty"))
        try windows.invoke(fixture, "controls-tile-power")
        XCTAssertTrue(windows.has(fixture, "controls-power-lock"))
        XCTAssertFalse(windows.has(fixture, "drawer-content-controls"))
        windows.trigger(fixture, "drawer-controls")
        XCTAssertFalse(windows.has(fixture, "card-glass-controls-toggles"))
        XCTAssertFalse(windows.has(fixture, "card-glass-controls-sliders"))
        XCTAssertFalse(windows.has(fixture, "card-glass-controls-mixer"))
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    func testShelfDropUsesTheHeldPointerWhileTheNativeSpringLagsBehindIt() throws {
        let fixture = try windows.drawers.fixture(animations: true)
        windows.seed(fixture.widget)
        windows.trigger(fixture, "drawer-calendar")
        let first = try windows.frame(fixture, "drawer-content-calendar-month")
        let grip = try windows.frame(fixture, "window-grip-calendar-month")
        _ = try windows.grab(fixture, id: "calendar-month", to: CGPoint(x: 100, y: 500))
        windows.shelfOpen = true
        windows.show(fixture)
        let shelf = try windows.frame(fixture, "window-shelf")
        let point = CGPoint(x: shelf.minX + 15, y: shelf.maxY - 5)
        fixture.widget.surface.drag(to: point, screen: .zero, timestamp: 0.015)
        let preview = try XCTUnwrap(fixture.widget.surface.manipulation?.preview)
        XCTAssertGreaterThan(abs(preview.minY - first.minY), 100)
        XCTAssertGreaterThan(grip.minY - first.minY, 100)
        windows.drop(fixture, at: point)
        windows.shelfOpen = false
        windows.show(fixture)
        XCTAssertFalse(windows.has(fixture, "drawer-content-calendar-month"))
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    func testAnotherDisplayRenderCannotReplaceTheCapturedAlbumOffer() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-player")
        let widget = fixture.widget
        let other = try XCTUnwrap(omni_instance_create(widget.vm))
        defer { omni_instance_destroy(other) }
        let monitor = VitreusFixture.monitor(id: 95101, width: 1280, height: 800)
        for key in ["bar", "island"] {
            var writer = ShellValueWriter()
            if key == "bar" { VitreusFixture.bar(monitor).write(to: &writer) }
            else { VitreusFixture.island(monitor).write(to: &writer) }
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_instance_set_value(other, key, $0.baseAddress, $0.count)
            }, OMNI_OK)
        }
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(omni_instance_render(other, OMNI_VIEW_BAR, 100_000_000, &stats, &error, error.count), OMNI_OK)
        let card = try windows.frame(fixture, "media-card")
        let start = CGPoint(x: card.minX + 90, y: card.minY + 100)
        let end = CGPoint(x: start.x + 300, y: start.y + 300)
        let index = widget.events.count
        widget.surface.press(at: start)
        widget.surface.drag(to: end, screen: .zero, timestamp: 0.01)
        windows.deliver(fixture, from: index)
        XCTAssertNotNil(widget.surface.manipulation)
        XCTAssertTrue(windows.has(fixture, "media-card-glass"))
        XCTAssertEqual(omni_instance_render(other, OMNI_VIEW_BAR, 100_000_000, &stats, &error, error.count), OMNI_OK)
        windows.drop(fixture, at: end)
        XCTAssertEqual(try windows.frame(fixture, "media-card").width, card.width, accuracy: 0.01)
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    func testASectionCanReturnIntoItsOwnPanelWhileThatPanelIsStoredOnTheShelf() throws {
        let fixture = try windows.fixture()
        windows.trigger(fixture, "drawer-calendar")
        let home = try windows.frame(fixture, "drawer-content-calendar-month")
        let parent = try windows.frame(fixture, "drawer-content-calendar")
        try dragCard(fixture, "calendar-month", to: CGPoint(x: 100, y: 450))
        windows.shelfOpen = true
        windows.show(fixture)
        try windows.store(fixture, id: "calendar")
        let stored = try windows.frame(fixture, "drawer-content-calendar")
        let scale = stored.width / parent.width
        let slot = CGPoint(
            x: stored.minX + (home.minX - parent.minX) * scale,
            y: stored.minY + (home.minY - parent.minY) * scale
        )
        try dragCard(fixture, "calendar-month", to: slot)
        let child = try VitreusFixture.element(fixture.widget, key: "drawer-content-calendar-month")
        XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: child), try VitreusFixture.element(
            fixture.widget, key: "drawer-content-calendar"
        ))
        XCTAssertEqual(
            try windows.frame(fixture, "drawer-content-calendar-month").width,
            home.width * (try windows.frame(fixture, "drawer-content-calendar").width / parent.width),
            accuracy: 0.01
        )
    }
}

@MainActor
extension ShellVitreusSectionCardTests {
    private func retractedHeight(_ id: String) -> CGFloat {
        switch id {
        case "calendar-month": 295
        case "calendar-events": 373
        case "controls-toggles": 162
        case "controls-sliders": 174
        case "controls-mixer": 322
        case "player-windows": 190
        default: 0
        }
    }
}
