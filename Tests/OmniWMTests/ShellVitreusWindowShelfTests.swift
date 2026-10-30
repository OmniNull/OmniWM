// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellVitreusWindowShelfTests: XCTestCase {
    typealias Fixture = ShellVitreusDrawerTests.Fixture
    let drawers = ShellVitreusDrawerTests()
    let docks = ShellVitreusDockTests()
    var shelfOpen = false
    var barOverride: ShellBarData?

    func fixture() throws -> Fixture {
        let value = try drawers.fixture()
        seed(value.widget)
        show(value)
        return value
    }

    func seed(_ widget: ShellRenderedWidget) {
        var media = ShellMedia()
        media.title = "A song"
        media.artist = "An artist"
        media.bundle = "test.music"
        widget.set("media") { media.write(into: &$0) }
        widget.set("clock") { $0.string("3:00 PM") }
        widget.set("date") { $0.string("Thu 29") }
    }

    func show(_ fixture: Fixture) {
        let island = ShellIslandData(
            monitor: fixture.monitor, geometry: ShellIslandGeometry(
                monitor: fixture.monitor,
                size: fixture.monitor.frame.size
            ),
            visible: true, fullscreen: false, drawer: shelfOpen ? "shelf" : nil
        )
        fixture.widget.set("island") { island.write(to: &$0) }
        fixture.widget.render(
            barOverride ?? VitreusFixture.bar(fixture.monitor),
            acknowledgement: fixture.widget.invocation ?? 0
        )
        fixture.widget.surface.view.frame = CGRect(origin: .zero, size: fixture.widget.surface.size)
    }

    func trigger(_ fixture: Fixture, _ name: String) {
        VitreusFixture.trigger(fixture.widget.instance, name, VitreusFixture.bar(fixture.monitor).monitorId)
        show(fixture)
    }

    func frame(_ fixture: Fixture, _ key: String) throws -> CGRect {
        try VitreusFixture.frame(fixture.widget, key: key)
    }

    func has(_ fixture: Fixture, _ key: String) -> Bool {
        ShellVitreusBarTests.has(fixture.widget, key)
    }

    @discardableResult
    func invoke(_ fixture: Fixture, _ key: String) throws -> [String] {
        let content = fixture.widget.surface.layout.core.content(of: try VitreusFixture.element(
            fixture.widget,
            key: key
        ))
        let result = fixture.widget.invoke(content.action)
        show(fixture)
        return result
    }

    func deliver(_ fixture: Fixture, from index: Int) {
        for click in fixture.widget.events.dropFirst(index) where click.action & OMNI_ACTION_HANDLER != 0 {
            fixture.widget.invoke(click.action, event: click.event)
        }
        show(fixture)
    }

    func grab(_ fixture: Fixture, id: String, to origin: CGPoint) throws -> CGPoint {
        let target = try frame(fixture, "drawer-content-" + id)
        let grip = try frame(fixture, "window-grip-" + id)
        let start = CGPoint(x: grip.midX, y: grip.midY)
        let end = CGPoint(x: start.x + origin.x - target.minX, y: start.y + origin.y - target.minY)
        let handle = try VitreusFixture.element(fixture.widget, key: "drawer-content-" + id)
        let parent = fixture.widget.surface.layout.core.parent(of: handle)
        let index = fixture.widget.events.count
        fixture.widget.surface.press(at: start, timestamp: 0)
        fixture.widget.surface.drag(to: end, screen: .zero, timestamp: 0.01)
        deliver(fixture, from: index)
        XCTAssertEqual(fixture.widget.surface.manipulation?.target, handle)
        XCTAssertEqual(try VitreusFixture.element(fixture.widget, key: "drawer-content-" + id), handle)
        XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: handle), parent)
        return end
    }

    func drop(_ fixture: Fixture, at point: CGPoint) {
        let index = fixture.widget.events.count
        fixture.widget.surface.release(at: point, timestamp: 0.02)
        deliver(fixture, from: index)
        fixture.widget.surface.finishSettle()
        XCTAssertNil(fixture.widget.surface.manipulation)
    }

    func move(_ fixture: Fixture, id: String, to origin: CGPoint) throws {
        let handle = try VitreusFixture.element(fixture.widget, key: "window-grip-" + id)
        drop(fixture, at: try grab(fixture, id: id, to: origin))
        XCTAssertEqual(try VitreusFixture.element(fixture.widget, key: "window-grip-" + id), handle)
    }

    func openThree(_ fixture: Fixture) throws {
        for (id, origin) in [
            ("calendar", CGPoint(x: 80, y: 350)),
            ("controls", CGPoint(x: 1100, y: 450)),
            ("player", CGPoint(x: 100, y: 750))
        ] {
            trigger(fixture, "drawer-" + id)
            try move(fixture, id: id, to: origin)
        }
    }

    func store(_ fixture: Fixture, id: String) throws {
        let storage = try frame(fixture, "window-shelf")
        let target = try frame(fixture, "drawer-content-" + id)
        try move(fixture, id: id, to: CGPoint(x: storage.midX - target.width / 2, y: 80))
    }

    func assertUnique(_ fixture: Fixture) {
        let layout = fixture.widget.surface.layout
        let elements = layout.core.elements { _ in true }
        for id in ["calendar", "controls", "player"] {
            for key in ["drawer-content-" + id, "window-grip-" + id] {
                XCTAssertEqual(elements.count { layout.core.key(of: $0) == VitreusFixture.key(key) }, 1)
            }
        }
    }
}

@MainActor
extension ShellVitreusWindowShelfTests {
    func testShelfUsesTheEngineDrawerStateAndOnlyShowsItsHintWhenEmpty() throws {
        let fixture = try fixture()
        XCTAssertFalse(has(fixture, "window-shelf"))
        shelfOpen = true
        show(fixture)
        XCTAssertTrue(fixture.widget.strings().contains("Drag a drop-down here to keep it"))
        let body = try frame(fixture, "window-shelf-glass")
        XCTAssertEqual(body.minY, 0)
        XCTAssertLessThan(body.height, 220)
        XCTAssertLessThan(body.width, fixture.widget.surface.size.width)
        XCTAssertFalse(fixture.widget.surface.islandRegions().contains { $0.contains(CGPoint(x: 10, y: 900)) })
        let close = try frame(fixture, "window-shelf-close")
        XCTAssertEqual(fixture.widget.surface.command(at: CGPoint(x: close.midX, y: close.midY)), "shell toggle shelf")
        let handle = try VitreusFixture.element(fixture.widget, key: "window-shelf")
        let action = fixture.widget.surface.layout.core.content(of: handle).outsidePressAction
        var event = ShellEvent()
        event.claimed = true
        XCTAssertEqual(fixture.widget.invoke(action, event: event), [])
        event.claimed = false
        XCTAssertEqual(fixture.widget.invoke(action, event: event), ["shell toggle shelf"])
        shelfOpen = false
        show(fixture)
        XCTAssertFalse(has(fixture, "window-shelf"))
    }

    func testThreeIndependentWindowsStoreHideReopenExtractAndReturnHome() throws {
        let fixture = try fixture()
        try openThree(fixture)
        let input = try VitreusFixture.element(fixture.widget, key: "calendar-entry-1")
        var edit = ShellEvent()
        edit.text = "Keep my shelf draft"
        fixture.widget.invoke(fixture.widget.surface.layout.core.content(of: input).action, event: edit)
        show(fixture)
        assertUnique(fixture)
        shelfOpen = true
        show(fixture)
        for id in ["calendar", "controls", "player"] { try store(fixture, id: id) }
        XCTAssertFalse(fixture.widget.strings().contains("Drag a drop-down here to keep it"))
        assertUnique(fixture)
        shelfOpen = false
        show(fixture)
        for id in ["calendar", "controls", "player"] { XCTAssertFalse(has(fixture, "drawer-content-" + id)) }
        shelfOpen = true
        show(fixture)
        assertUnique(fixture)
        let restored = try VitreusFixture.element(fixture.widget, key: "calendar-entry-1")
        XCTAssertEqual(
            fixture.widget.text.string(fixture.widget.surface.layout.core.content(of: restored).text),
            edit.text
        )
        for (id, point) in [
            ("calendar", CGPoint(x: 80, y: 750)),
            ("controls", CGPoint(x: 1100, y: 750)),
            ("player", CGPoint(x: 800, y: 800))
        ] {
            try move(fixture, id: id, to: point)
        }
        shelfOpen = false
        show(fixture)
        assertUnique(fixture)
        for id in ["calendar", "controls", "player"] {
            trigger(fixture, "drawer-" + id)
            XCTAssertTrue(has(fixture, "drawer-content-" + id))
            trigger(fixture, "drawer-" + id)
            XCTAssertFalse(has(fixture, "drawer-content-" + id))
        }
    }

    func testOpenShelfWinsOverHomeAndStoredWindowCanReturnByItsWidget() throws {
        let fixture = try fixture()
        trigger(fixture, "drawer-calendar")
        let home = try frame(fixture, "drawer-content-calendar")
        shelfOpen = true
        show(fixture)
        try move(fixture, id: "calendar", to: CGPoint(x: home.minX + 5, y: home.minY + 5))
        shelfOpen = false
        show(fixture)
        XCTAssertFalse(has(fixture, "drawer-content-calendar"))
        trigger(fixture, "drawer-calendar")
        ShellVitreusMediaCardTests.assertRect(try frame(fixture, "drawer-content-calendar"), home)
    }

    func testDetachedControlsKeepTheirMixerWhenTheCalendarOpens() throws {
        let fixture = try fixture()
        fixture.widget.set("audioApps") {
            ShellAudioApps(
                access: .granted,
                apps: [.init(id: "test.music", name: "Music", playing: true, volume: 50, muted: false)]
            )
            .write(into: &$0)
        }
        trigger(fixture, "drawer-controls")
        try move(fixture, id: "controls", to: CGPoint(x: 100, y: 400))
        try invoke(fixture, "controls-mixer-toggle")
        XCTAssertTrue(has(fixture, "controls-app-test.music"))
        trigger(fixture, "drawer-calendar")
        XCTAssertTrue(has(fixture, "controls-app-test.music"))
        let button = try frame(fixture, "controls-app-mute-test.music")
        XCTAssertEqual(
            fixture.widget.surface.command(at: CGPoint(x: button.midX, y: button.midY)),
            "volume app test.music mute"
        )
    }

    func testPlayerCarriesItsNestedAlbumNativelyAndLeavesAFloatingAlbumIndependent() throws {
        let fixture = try fixture()
        trigger(fixture, "drawer-player")
        XCTAssertTrue(has(fixture, "media-card"))
        let album = try VitreusFixture.element(fixture.widget, key: "media-card")
        let moved = try grab(fixture, id: "player", to: CGPoint(x: 100, y: 400))
        XCTAssertEqual(try VitreusFixture.element(fixture.widget, key: "media-card"), album)
        let preview = try XCTUnwrap(fixture.widget.surface.manipulation?.preview)
        let presented = CGRect(fixture.widget.surface.presentedFrame(of: album))
        XCTAssertEqual(presented.midX, preview.midX, accuracy: 0.01)
        XCTAssertEqual(presented.minY, preview.minY + 12 * 1.5525, accuracy: 0.01)
        drop(fixture, at: moved)
        let player = try frame(fixture, "drawer-content-player")
        let card = try frame(fixture, "media-card")
        XCTAssertLessThan(try frame(fixture, "window-grip-player").maxY, card.minY)
        XCTAssertEqual(card.midX, player.midX, accuracy: 0.01)
        XCTAssertEqual(card.minY, player.minY + 12 * 1.5525, accuracy: 0.01)
        let handle = try VitreusFixture.element(fixture.widget, key: "media-card")
        let parent = fixture.widget.surface.layout.core.parent(of: handle)
        let start = CGPoint(x: card.minX + 90, y: card.minY + 100)
        let end = CGPoint(x: start.x + 800, y: start.y + 80)
        let index = fixture.widget.events.count
        fixture.widget.surface.press(at: start, timestamp: 0)
        fixture.widget.surface.drag(to: end, screen: .zero, timestamp: 0.01)
        deliver(fixture, from: index)
        XCTAssertEqual(fixture.widget.surface.manipulation?.target, handle)
        XCTAssertEqual(fixture.widget.surface.layout.core.parent(of: handle), parent)
        drop(fixture, at: end)
        XCTAssertTrue(has(fixture, "media-card-glass"))
        let floatingHandle = try VitreusFixture.element(fixture.widget, key: "media-card")
        let floating = try frame(fixture, "media-card")
        let destination = try grab(fixture, id: "player", to: CGPoint(x: 100, y: 600))
        XCTAssertTrue(has(fixture, "media-card"))
        XCTAssertEqual(try VitreusFixture.element(fixture.widget, key: "media-card"), floatingHandle)
        drop(fixture, at: destination)
        ShellVitreusMediaCardTests.assertRect(try frame(fixture, "media-card"), floating)
    }
}

@MainActor
extension ShellVitreusWindowShelfTests {
    func testControlsAndPlayerStickRightAndRedockUnderTheirOwnWidget() throws {
        for id in ["controls", "player"] {
            let fixture = try fixture()
            trigger(fixture, "drawer-" + id)
            let home = try frame(fixture, "drawer-content-" + id)
            try move(fixture, id: id, to: CGPoint(x: 1920 - home.width - 20, y: 300))
            XCTAssertEqual(try frame(fixture, "drawer-content-" + id).maxX, 1920, accuracy: 0.01)
            let bulge = try drawers.morph(fixture, id + "-window-bulge")
            XCTAssertEqual(bulge.source?.target, VitreusFixture.key("drawer-content-" + id))
            trigger(fixture, "drawer-" + id)
            ShellVitreusMediaCardTests.assertRect(try frame(fixture, "drawer-content-" + id), home)
            XCTAssertFalse(has(fixture, id + "-window-bulge"))
        }
    }

    func testStoredWindowsFitANarrowShelfAndCanBePulledBelowIt() throws {
        let base = try fixture()
        let fixture = Fixture(
            widget: base.widget,
            monitor: VitreusFixture.monitor(width: 1280, height: 800),
            clock: base.clock,
            scene: base.scene
        )
        shelfOpen = true
        show(fixture)
        for id in ["calendar", "controls", "player"] {
            trigger(fixture, "drawer-" + id)
            try store(fixture, id: id)
        }
        let shelf = try frame(fixture, "window-shelf")
        for id in ["calendar", "controls", "player"] {
            let window = try frame(fixture, "drawer-content-" + id)
            XCTAssertGreaterThanOrEqual(window.minX, shelf.minX)
            XCTAssertLessThanOrEqual(window.maxX, shelf.maxX)
            XCTAssertLessThanOrEqual(window.maxY, shelf.maxY)
        }
        try move(fixture, id: "calendar", to: CGPoint(x: 0, y: 700))
        shelfOpen = false
        show(fixture)
        XCTAssertTrue(has(fixture, "drawer-content-calendar"))
        XCTAssertEqual(try frame(fixture, "drawer-content-calendar").maxY, 800, accuracy: 0.001)
        XCTAssertFalse(has(fixture, "drawer-content-controls"))
        XCTAssertFalse(has(fixture, "drawer-content-player"))
    }
}

@MainActor
extension ShellVitreusWindowShelfTests {
    func testAllBuiltInTargetsAndThreeLooseWindowsFitBudgetsWithShelfOpen() throws {
        let widget = try docks.island(["pins": .strings([ShellVitreusDockTests.safari]), "addons": .strings(["notes"])])
        let fixture = Fixture(
            widget: widget,
            monitor: VitreusFixture.monitor(),
            clock: .init(),
            scene: widget.surface.scene
        )
        seed(widget)
        show(fixture)
        trigger(fixture, "desk-open")
        try invoke(fixture, "addon-pin-notes")
        try openThree(fixture)
        shelfOpen = true
        show(fixture)
        XCTAssertEqual(widget.surface.manipulationTargets.count, 15)
        let layout = widget.surface.layout
        let elements = layout.core.elements { _ in true }
        let counts = elements.filter { layout.core.kind(of: $0) == .glass }.map { body in
            elements.count { layout.core.parent(of: $0) == body }
        }
        XCTAssertTrue(counts.allSatisfy { $0 <= 64 })
        XCTAssertFalse(widget.surface.islandRegions().contains { $0.contains(CGPoint(x: 10, y: 900)) })
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            omni_instance_render(
                widget.instance,
                OMNI_VIEW_BAR,
                ShellWidgetPackage.renderBudget,
                &stats,
                &error,
                error.count
            ),
            OMNI_OK,
            String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        )
        print(
            "WINDOW-SHELF-BUDGET targets=\(widget.surface.manipulationTargets.count) shapes=\(counts) cpu_ns=\(stats.cpu_ns) encode_ns=\(stats.encode_cpu_ns)"
        )
    }

    func testShelfConfigurationUsesIslandPresentationWithoutAnyWidgetPanel() throws {
        let shell = try VitreusFixture.shell()
        defer { VitreusFixture.remove(shell) }
        let config = try VitreusFixture.config(shell)
        let shelf = try XCTUnwrap(config.drawers.first { $0.id == "shelf" })
        XCTAssertTrue(shelf.island)
        XCTAssertEqual(shelf.edge, .top)
        XCTAssertTrue(shelf.hover)
        XCTAssertTrue(shelf.closesOnLeave)
        XCTAssertTrue(shelf.widgets.isEmpty)
    }
}

@MainActor
extension ShellVitreusWindowShelfTests {
    func testShelfDropUsesThePointerRatherThanTheWindowCentre() throws {
        let fixture = try fixture()
        trigger(fixture, "drawer-calendar")
        shelfOpen = true
        show(fixture)
        let shelf = try frame(fixture, "window-shelf")
        let grip = try frame(fixture, "window-grip-calendar")
        let start = CGPoint(x: grip.minX + 2, y: grip.midY)
        let end = CGPoint(x: shelf.minX - 5, y: 80)
        let index = fixture.widget.events.count
        fixture.widget.surface.press(at: start, timestamp: 0)
        fixture.widget.surface.drag(to: end, screen: .zero, timestamp: 0.01)
        deliver(fixture, from: index)
        XCTAssertNotNil(fixture.widget.surface.manipulation)
        drop(fixture, at: end)
        shelfOpen = false
        show(fixture)
        XCTAssertTrue(has(fixture, "drawer-content-calendar"))
    }
}
