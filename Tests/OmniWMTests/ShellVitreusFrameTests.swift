// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellVitreusFrameTests: XCTestCase {
    struct Fixture {
        let widget: ShellRenderedWidget
        let shell: URL
        var settings: [String: ShellComponentValue]
        var bar: ShellBarData
    }

    func fixture(
        _ edge: String = "left",
        animations: Bool = false,
        pieces: [String] = ["workspaces", "title", "tray", "search", "omniwm", "controls", "clock"]
    ) throws
        -> Fixture
    {
        let shell = try VitreusFixture.shell()
        addTeardownBlock { VitreusFixture.remove(shell) }
        let source = try VitreusFixture.source(shell)
        let config = try VitreusFixture.config(shell)
        let widget = try ShellRenderedWidget(
            name: source.chunk, source: source.main,
            directories: [try XCTUnwrap(config.widget("vitreus")).deletingLastPathComponent()] + config.directories,
            modules: source.modules, chunk: source.chunk,
            resources: VitreusFixture.resources(shell, animations: animations),
            fonts: ShellFontLibrary.shared.fonts(in: source.fontFolders),
            memoryLimit: ShellWidgetPackage.memoryLimit, moduleLimit: source.moduleLimit
        )
        widget.configure(ShellComponentCatalog.configurationBytes(
            instances: source.components, descriptors: source.componentDescriptors
        ))
        var bar = VitreusFixture.bar()
        bar.workspaces = ["1", "2", "3"].map { id in
            ShellBarWorkspace(id: id, name: id, focused: id == "1", windows: [ShellBarItem(
                id: id, bundle: "test.app", name: "App", focused: id == "1", count: 1, hidden: 0,
                windows: [.init(id: "window-" + id, title: "Window " + id, focused: id == "1", hidden: false)]
            )])
        }
        widget.set("clock") { $0.string("6:42 pm") }
        widget.set("date") { $0.string("Tue 28") }
        widget.set("app") { $0.string("Test App") }
        widget.set("title") { $0.string("A document in a vertical strip") }
        widget.set("battery") { $0.number(68) }
        widget.set("charging") { $0.bool(false) }
        widget.set("hiddenBar") { ShellHiddenBarData(items: []).write(into: &$0) }
        let result = Fixture(
            widget: widget,
            shell: shell,
            settings: ["layout": .string(edge), "pieces": .strings(pieces)],
            bar: bar
        )
        show(result)
        omni_instance_clear_messages(widget.instance)
        return result
    }

    func show(_ fixture: Fixture) {
        VitreusFixture.settings(fixture.widget, fixture.settings)
        fixture.widget.set("seconds") { $0.number(1000) }
        fixture.widget.set("island") { VitreusFixture.island(VitreusFixture.monitor()).write(to: &$0) }
        fixture.widget.render(fixture.bar)
        fixture.widget.surface.view.frame = CGRect(origin: .zero, size: fixture.widget.surface.size)
    }

    func has(_ fixture: Fixture, _ name: String) -> Bool {
        ShellVitreusBarTests.has(fixture.widget, name)
    }

    func frame(_ fixture: Fixture, _ name: String) throws -> CGRect {
        try VitreusFixture.frame(fixture.widget, key: name)
    }

    func content(_ fixture: Fixture, _ name: String) throws -> Content {
        fixture.widget.surface.layout.core.content(of: try VitreusFixture.element(fixture.widget, key: name))
    }

    @discardableResult
    func click(_ fixture: Fixture, _ name: String) throws -> [String] {
        let value = try content(fixture, name)
        let result = value.action & OMNI_ACTION_HANDLER != 0 ? fixture.widget.invoke(value.action)
            : [fixture.widget.text.string(value.action)]
        show(fixture)
        return result
    }

    func hover(_ fixture: Fixture, at point: CGPoint?) {
        let start = fixture.widget.events.count
        fixture.widget.surface.hover(at: point)
        for click in fixture.widget.events.dropFirst(start) where click.action & OMNI_ACTION_HANDLER != 0 {
            fixture.widget.invoke(click.action, event: click.event)
        }
        show(fixture)
    }
}

extension ShellVitreusFrameTests {
    func testEachEdgeHasTheThinRingAndOffsetStripWithAClearInputHole() throws {
        for edge in ["left", "right", "ftop", "fbottom"] {
            let fixture = try fixture(edge)
            let handle = try VitreusFixture.element(fixture.widget, key: "frame")
            let shape = try XCTUnwrap(ShellLayerScene.engineQueue
                .sync { fixture.widget.surface.scene.glassShapes[handle.slot] })
            XCTAssertEqual(shape.kind, 2)
            let hole = shape.rect.insetBy(dx: shape.thickness, dy: shape.thickness)
            XCTAssertEqual(shape.radius - shape.thickness, 25.27, accuracy: 0.001)
            let edges = [hole.minX, 1920 - hole.maxX, hole.minY, 1080 - hole.maxY]
            let selected = ["left": 0, "right": 1, "ftop": 2, "fbottom": 3][edge]!
            for (index, value) in edges.enumerated() {
                XCTAssertEqual(value, index == selected ? 62.1 : 10.8, accuracy: 0.001, edge)
            }
            XCTAssertFalse(fixture.widget.surface.containsShape(at: CGPoint(x: 960, y: 540)))
            XCTAssertTrue(fixture.widget.surface.containsShape(at: CGPoint(x: 5, y: 540)))
            XCTAssertFalse(has(fixture, "desk-opener"))
            XCTAssertTrue(has(fixture, "bar-hover"))
        }
    }

    func testIslandHasNoFrameAndSwitchingBackKeepsTheNativeClosingRing() throws {
        var fixture = try fixture("island", animations: true)
        XCTAssertFalse(has(fixture, "frame"))
        let renderer = try ShellLayerScene.engineQueue.sync {
            let root = fixture.widget.surface.scene.container
            root.frame = CGRect(origin: .zero, size: fixture.widget.surface.size)
            let renderer = try ShellOffscreenRenderer(root: root, width: 1920, height: 1080)
            root.speed = 0
            root.timeOffset = CACurrentMediaTime()
            return renderer
        }
        fixture.settings["layout"] = .string("left")
        show(fixture)
        let handle = try VitreusFixture.element(fixture.widget, key: "frame")
        try ShellLayerScene.engineQueue.sync {
            XCTAssertNotNil(fixture.widget.surface.scene.glassShapes[handle.slot])
            XCTAssertFalse(fixture.widget.surface.scene.shapeTracks.entries.isEmpty)
            _ = try renderer.render()
        }
        let settled = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.widget.surface.scene.shapeTracks.entries[handle.slot]?.plan?.end) + 0.01
        }
        fixture.widget.surface.clock = { settled }
        try ShellLayerScene.engineQueue.sync { _ = try renderer.render(paused: settled) }
        fixture.settings["layout"] = .string("island")
        show(fixture)
        XCTAssertFalse(has(fixture, "frame"))
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.widget.surface.scene
            XCTAssertFalse(scene.shapeTracks.retired.isEmpty)
            let closing = try XCTUnwrap(scene.shapeTracks.entries.values.first {
                $0.carrier != nil && $0.base.target.kind == 2
            })
            XCTAssertEqual(closing.plan?.target, 0)
            XCTAssertFalse(closing.animations.isEmpty)
            XCTAssertTrue(scene.layers[closing.body]?.sublayers?.first === closing.carrier)
            let body = try XCTUnwrap(scene.glassBodies[closing.body])
            XCTAssertNil(body.failure)
            _ = try renderer.render()
        }
    }

    func testVerticalPiecesAreStackedAndTheTitleReadsUpTheStrip() throws {
        for edge in ["left", "right"] {
            let fixture = try fixture(edge)
            let overview = try frame(fixture, "workspace-overview")
            let first = try frame(fixture, "workspace-hit-1")
            let second = try frame(fixture, "workspace-hit-2")
            XCTAssertEqual(overview.midX, edge == "left" ? 31.05 : 1888.95, accuracy: 0.001)
            XCTAssertGreaterThan(first.midY, overview.midY)
            XCTAssertGreaterThan(second.midY, first.midY)
            let controls = try frame(fixture, "bar-controls")
            let logo = try frame(fixture, "bar-omniwm")
            let search = try frame(fixture, "bar-search")
            XCTAssertEqual(controls.midY - logo.midY, 32 * 1.35, accuracy: 0.001)
            XCTAssertEqual(logo.midY - search.midY, 32 * 1.35, accuracy: 0.001)
            XCTAssertTrue(has(fixture, "clock-hour"))
            XCTAssertTrue(fixture.widget.strings().contains("A document in a vertical strip"))
        }
    }

    func testBarWideHoverWorksInGapsAndOnPiecesWithoutATitle() throws {
        for edge in ["island", "left", "right", "ftop", "fbottom"] {
            let fixture = try fixture(edge, pieces: ["omniwm", "clock"])
            let area = try frame(fixture, "bar-hover")
            hover(fixture, at: CGPoint(x: area.minX + 2, y: area.midY))
            let slot = try VitreusFixture.element(fixture.widget, key: "battery-track").slot
            try ShellLayerScene.engineQueue.sync {
                XCTAssertGreaterThan(try XCTUnwrap(fixture.widget.surface.scene.layers[slot]).opacity, 0)
            }
            let logo = try frame(fixture, "bar-omniwm")
            hover(fixture, at: CGPoint(x: logo.midX, y: logo.midY))
            try ShellLayerScene.engineQueue.sync {
                XCTAssertGreaterThan(try XCTUnwrap(fixture.widget.surface.scene.layers[slot]).opacity, 0)
            }
            hover(fixture, at: nil)
            try ShellLayerScene.engineQueue.sync {
                XCTAssertEqual(try XCTUnwrap(fixture.widget.surface.scene.layers[slot]).opacity, 0)
            }
        }
    }

    func testTabsUseTheAnalyticHoldThresholdAndNativeDelays() throws {
        let fixture = try fixture("left")
        let hot = try frame(fixture, "frame-hover-top")
        hover(fixture, at: CGPoint(x: hot.midX, y: hot.midY))
        let shape = try VitreusFixture.element(fixture.widget, key: "frame-tab-top")
        let reveal = try XCTUnwrap(ShellRevealRecipe(fixture.widget.text.string(
            fixture.widget.surface.layout.core.paint(of: shape).reveal
        )))
        let spring = ShellMorphRecipe.Spring(response: 2 * .pi * 0.28 / 6.64, bounce: 0).parameters
        let opening = ShellReveal(begin: 0, progress: 0, target: 1, spring: spring)
        let closing = ShellReveal(begin: 0, progress: 1, target: 0, spring: spring)
        XCTAssertEqual(reveal.delay, try XCTUnwrap(opening.crossings(at: 0.3, rising: true).first), accuracy: 0.00001)
        XCTAssertEqual(reveal.hold, try XCTUnwrap(closing.crossings(at: 0.3, rising: false).first), accuracy: 0.00001)
        XCTAssertEqual(reveal.delay, 0.046, accuracy: 0.001)
        XCTAssertEqual(reveal.hold, 0.103, accuracy: 0.001)
        XCTAssertEqual(try click(fixture, "frame-hit-top"), ["open-command-palette"])
        hover(fixture, at: nil)
        XCTAssertFalse(has(fixture, "frame-tab-top"))
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(fixture.widget.surface.scene.shapeTracks.retired.isEmpty)
        }
    }

    func testDisabledBarKeepsTheThinFrameWithoutPieceOrTabHitRegions() throws {
        var fixture = try fixture("left")
        fixture.bar.barEnabled = false
        show(fixture)
        let handle = try VitreusFixture.element(fixture.widget, key: "frame")
        let shape = try XCTUnwrap(ShellLayerScene.engineQueue
            .sync { fixture.widget.surface.scene.glassShapes[handle.slot] })
        let hole = shape.rect.insetBy(dx: shape.thickness, dy: shape.thickness)
        XCTAssertEqual(hole.minX, 10.8, accuracy: 0.001)
        XCTAssertEqual(hole.minY, 10.8, accuracy: 0.001)
        XCTAssertEqual(hole.width, 1898.4, accuracy: 0.001)
        XCTAssertEqual(hole.height, 1058.4, accuracy: 0.001)
        XCTAssertFalse(has(fixture, "bar-hover"))
        XCTAssertFalse(has(fixture, "frame-hover-top"))
        XCTAssertFalse(has(fixture, "bar-clock"))
    }

    func testPrivacyLightsRemainWithoutTheTrayAndDoNotDuplicateWithIt() throws {
        for edge in ["island", "left", "ftop"] {
            var fixture = try fixture(edge, pieces: ["omniwm", "clock"])
            fixture.widget.set("privacy") { writer in
                writer.map(2)
                writer.key("microphone")
                writer.bool(true)
                writer.key("camera")
                writer.bool(true)
            }
            show(fixture)
            XCTAssertTrue(has(fixture, "tray-microphone"))
            XCTAssertTrue(has(fixture, "tray-camera"))
            fixture.settings["pieces"] = .strings(["privacy", "tray", "omniwm", "clock"])
            show(fixture)
            let elements = fixture.widget.surface.layout.core.elements { _ in true }
            XCTAssertEqual(
                elements
                    .count { fixture.widget.surface.layout.core.key(of: $0) == VitreusFixture.key("tray-microphone") },
                1
            )
            XCTAssertEqual(
                elements.count { fixture.widget.surface.layout.core.key(of: $0) == VitreusFixture.key("tray-camera") },
                1
            )
        }
    }
}
