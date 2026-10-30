// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellVitreusDockTests: XCTestCase {
    static let unit = 1.35
    static let panel = 1.5525
    static let thick = 34 * unit
    static let reach = 12 * unit
    static let safari = "com.apple.Safari"
    static let notes = "com.apple.Notes"
    static let mail = "com.apple.mail"
    static let components = [
        ShellComponentInstance(id: "pad", widget: "desk-pad"),
        ShellComponentInstance(id: "focus", widget: "desk-focus"),
        ShellComponentInstance(id: "notes", widget: "vitreus-notes")
    ]

    static func long(_ count: Int) -> Double {
        Double(count) * 30 * unit + 8 * unit
    }

    static func assertRect(_ actual: CGRect, _ expected: CGRect, _ label: String = "", line: UInt = #line) {
        for (value, target) in [
            (actual.minX, expected.minX), (actual.minY, expected.minY),
            (actual.width, expected.width), (actual.height, expected.height)
        ] {
            XCTAssertEqual(value, target, accuracy: 0.001, label, line: line)
        }
    }

    static func assertSpring(_ motion: ShellMotion?, _ stiffness: Double, _ damping: Double, line: UInt = #line) {
        guard case let .spring(response, bounce)? = motion else {
            return XCTFail("\(String(describing: motion))", line: line)
        }
        XCTAssertEqual(response, 2 * .pi / stiffness.squareRoot(), accuracy: 1e-4, line: line)
        XCTAssertEqual(bounce, 1 - damping / (2 * stiffness.squareRoot()), accuracy: 1e-4, line: line)
    }

    static func assertSize(_ actual: CGSize, _ expected: CGSize, _ label: String = "", line: UInt = #line) {
        assertRect(CGRect(origin: .zero, size: actual), CGRect(origin: .zero, size: expected), label, line: line)
    }

    func shell() throws -> URL {
        let shell = try VitreusFixture.shell()
        let root = shell.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let folder = shell.appendingPathComponent("widgets/vitreus-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("title = 'Notes'\nicon = 'note.text'\nviews = ['addon']\n".utf8)
            .write(to: folder.appendingPathComponent("component.toml"))
        try Data("""
        return { views = { addon = function(ctx)
            return ui.stack({ w = ctx.view.w, h = ctx.view.h, ui.text({ text = "notes " .. ctx.view.props.cu }) })
        end } }
        """.utf8).write(to: folder.appendingPathComponent("component.luau"))
        return shell
    }

    func island(
        _ settings: [String: ShellComponentValue] = [:], monitor: Monitor = VitreusFixture.monitor(), scale: CGFloat = 2
    ) throws -> ShellRenderedWidget {
        let shell = try shell()
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell, components: Self.components), scale: scale,
            resources: VitreusFixture.resources(shell)
        )
        XCTAssertEqual(omni_vm_set_configuration_enabled(widget.vm, true), OMNI_OK)
        let catalog = try ShellComponentCatalog.catalogBytes(
            ShellComponentCatalog.installed(directories: VitreusFixture.config(shell).directories)
        )
        XCTAssertEqual(catalog.withUnsafeBufferPointer {
            omni_instance_set_value(widget.instance, "catalog", $0.baseAddress, $0.count)
        }, OMNI_OK)
        var values: [String: ShellComponentValue] = [
            "layout": .string("island"), "size": .number(1), "pins": .strings([]), "addons": .strings([]),
            "dockOverlap": .bool(false)
        ]
        values.merge(settings) { $1 }
        VitreusFixture.settings(widget, values)
        VitreusFixture.show(widget, on: monitor)
        return widget
    }

    func content(_ widget: ShellRenderedWidget, _ name: String) throws -> Content {
        try widget.surface.layout.core.content(of: VitreusFixture.element(widget, key: name))
    }

    func recipe(_ widget: ShellRenderedWidget, _ name: String) throws -> ShellManipulationRecipe {
        try XCTUnwrap(ShellManipulationRecipe(widget.text.string(content(widget, name).gestureTrack)), name)
    }

    func commit(_ widget: ShellRenderedWidget, _ name: String) throws -> String {
        try widget.text.string(content(widget, name).manipulationCommit)
    }

    func follow(_ widget: ShellRenderedWidget, _ name: String) throws -> ShellMotion? {
        try ShellMotion(recipe: widget.text.string(content(widget, name).manipulationFollow))
    }

    func deliver(_ widget: ShellRenderedWidget, from index: Int) -> [String] {
        var requests: [String] = []
        for click in widget.events.dropFirst(index) where click.action & OMNI_ACTION_HANDLER != 0 {
            requests += widget.invoke(click.action, event: click.event)
        }
        VitreusFixture.show(widget, acknowledgement: widget.invocation ?? 0)
        return requests
    }

    @discardableResult
    func move(_ widget: ShellRenderedWidget, key name: String, by offset: CGVector) throws -> [String] {
        let frame = try VitreusFixture.frame(widget, key: name)
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let end = CGPoint(x: start.x + offset.dx, y: start.y + offset.dy)
        var index = widget.events.count
        widget.surface.press(at: start, timestamp: 0)
        widget.surface.drag(to: end, screen: .zero, timestamp: 0.01)
        var requests = deliver(widget, from: index)
        index = widget.events.count
        widget.surface.release(at: end, timestamp: 0.02)
        requests += deliver(widget, from: index)
        return requests
    }

    func press(_ widget: ShellRenderedWidget, key name: String, button: ShellEvent.Button = .left) throws -> [String] {
        let frame = try VitreusFixture.frame(widget, key: name)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let index = widget.events.count
        widget.surface.press(at: point, button: button)
        widget.surface.release(at: point, event: ShellEvent(button: button))
        return deliver(widget, from: index)
    }

    func testPinsFromTheRootSettingSitInTheCornerAndTheDockHidesWithoutPins() throws {
        let empty = try island()
        XCTAssertFalse(ShellVitreusBarTests.has(empty, "dock-pill"))
        XCTAssertFalse(ShellVitreusBarTests.has(empty, "dock-pill-glass"))
        let pins = [Self.safari, Self.notes, Self.safari, "not a bundle", Self.mail]
        let widget = try island(["pins": .strings(pins)])
        let (thick, reach, long) = (Self.thick, Self.reach, Self.long(3))
        Self.assertRect(try VitreusFixture.frame(widget, key: "dock-pill"), CGRect(
            x: 0, y: 1080 - thick, width: long, height: thick
        ))
        let glass = try VitreusFixture.element(widget, key: "dock-pill-glass")
        let layout = widget.surface.layout
        XCTAssertEqual(layout.core.kind(of: glass), .shape)
        XCTAssertEqual(layout.core.parent(of: glass), try VitreusFixture.element(widget, key: "corner-glass"))
        XCTAssertEqual(layout.core.content(of: glass).glassFollow, VitreusFixture.key("dock-pill"))
        XCTAssertEqual(Double(layout.core.paint(of: glass).cornerRadius), 17 * Self.unit, accuracy: 1e-4)
        Self.assertRect(CGRect(layout.core.absoluteFrame(of: glass)), CGRect(
            x: -reach, y: 1080 - thick, width: long + reach, height: thick + reach
        ))
        XCTAssertTrue(widget.surface.containsShape(at: CGPoint(x: 1, y: 1079)))
        for (index, bundle) in [Self.safari, Self.notes, Self.mail].enumerated() {
            let icon = try VitreusFixture.frame(widget, key: "dock-pin-" + bundle)
            Self.assertRect(icon, CGRect(
                x: 9 + 40 * Double(index) - 3.5 * Self.unit, y: 1041 - 4.5 * Self.unit,
                width: 31 * Self.unit, height: 33 * Self.unit
            ), bundle)
            let command = try XCTUnwrap(widget.surface.command(at: CGPoint(x: icon.midX, y: icon.midY)))
            XCTAssertEqual(command, "notifications open " + bundle)
            XCTAssertEqual(ShellAction(command), .notifications(.open(bundle: bundle)))
        }
        XCTAssertFalse(ShellVitreusBarTests.has(widget, "dock-pin-not a bundle"))
        let full = try island(["pins": .strings((1 ... 10).map { "com.example.app\($0)" })])
        XCTAssertEqual(try VitreusFixture.frame(full, key: "dock-pill").width, Self.long(8), accuracy: 0.001)
        XCTAssertFalse(ShellVitreusBarTests.has(full, "dock-pin-com.example.app9"))
    }

    func testRightClickUnpinsByWritingTheRootSettingAndAShortPressLaunches() throws {
        let pins = [Self.safari, Self.notes, Self.safari, "not a bundle", Self.mail]
        let widget = try island(["pins": .strings(pins)])
        _ = VitreusFixture.drain(widget)
        _ = try press(widget, key: "dock-pin-" + Self.safari, button: .right)
        let request = try XCTUnwrap(VitreusFixture.drain(widget).first { $0.kind == OMNI_SERVICE_CONFIG })
        XCTAssertEqual(request.owner.owner, 0)
        let fields = try XCTUnwrap(ShellServiceValue.decode(request.bytes).fields)
        XCTAssertEqual(fields["op"]?.string, "rootSetting")
        XCTAssertEqual(fields["key"]?.string, "pins")
        XCTAssertEqual(fields["value"]?.values?.compactMap(\.string), [Self.notes, "not a bundle", Self.mail])
        try move(widget, key: "dock-pin-" + Self.notes, by: CGVector(dx: 5, dy: 0))
        XCTAssertEqual(widget.clicks.last?.action, "notifications open " + Self.notes)
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "dock-pill").minX, 0, accuracy: 0.001)
        XCTAssertEqual(try content(widget, "dock-pill").manipulationCommit, 0)
    }

    func testBothPillsDragPastEightPointsFollowTheDockSpringAndSwapCornersOnDrop() throws {
        let widget = try island(["pins": .strings([Self.safari, Self.notes]), "addons": .strings(["pad", "notes"])])
        let (dock, addon) = (Self.long(2), Self.long(1))
        Self.assertRect(try VitreusFixture.frame(widget, key: "addon-pill"), CGRect(
            x: 1920 - addon, y: 1080 - Self.thick, width: addon, height: Self.thick
        ))
        for (name, width) in [("dock-pill", dock), ("addon-pill", addon)] {
            let grab = try content(widget, name + "-grab")
            XCTAssertEqual(grab.gesture.axis, .free, name)
            XCTAssertEqual(grab.gesture.threshold, 8, name)
            let track = try recipe(widget, name + "-grab")
            XCTAssertEqual(track.mode, .move, name)
            XCTAssertEqual(track.target, VitreusFixture.key(name), name)
            Self.assertRect(track.bounds, CGRect(
                x: -width / 2, y: -Self.thick / 2, width: 1920 + width, height: 1080 + Self.thick
            ), name)
            Self.assertSize(track.minimum, CGSize(width: width, height: Self.thick), name)
            Self.assertSize(track.maximum, CGSize(width: width, height: Self.thick), name)
            Self.assertSpring(try follow(widget, name), 380, 30)
        }
        let requests = try move(widget, key: "dock-pill", by: CGVector(dx: 1300, dy: -200))
        XCTAssertNil(widget.surface.manipulation)
        XCTAssertEqual(requests, ["shell trigger vitreus dock-corner 1"])
        XCTAssertTrue(try commit(widget, "dock-pill").hasPrefix("placement-"))
        XCTAssertEqual(try commit(widget, "addon-pill"), "dock-swap-1")
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "dock-pill").minX, 1920 - dock, accuracy: 0.001)
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "addon-pill").minX, 0, accuracy: 0.001)
        let glass = try VitreusFixture.frame(widget, key: "dock-pill-glass")
        Self.assertRect(glass, CGRect(
            x: 1920 - dock, y: 1080 - Self.thick, width: dock + Self.reach, height: Self.thick + Self.reach
        ))
        XCTAssertEqual(try move(widget, key: "dock-pill", by: CGVector(dx: -200, dy: -100)), [])
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "dock-pill").minX, 1920 - dock, accuracy: 0.001)
        XCTAssertEqual(
            try move(widget, key: "addon-pill", by: CGVector(dx: 1400, dy: 0)), ["shell trigger vitreus dock-corner 0"]
        )
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "dock-pill").minX, 0, accuracy: 0.001)
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "addon-pill").minX, 1920 - addon, accuracy: 0.001)
        XCTAssertTrue(try commit(widget, "addon-pill").hasPrefix("placement-"))
        XCTAssertEqual(try commit(widget, "dock-pill"), "dock-swap-2")
        VitreusFixture.trigger(widget.instance, "dock-corner", "1")
        VitreusFixture.show(widget)
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "dock-pill").minX, 1920 - dock, accuracy: 0.001)
        XCTAssertEqual(try commit(widget, "dock-pill"), "dock-swap-3")
    }

    func testFrameLayoutsPutTheDockOnTheEdgeOppositeTheStrip() throws {
        let thin = 8 * Self.unit
        let left = try island(["layout": .string("left"), "pins": .strings([Self.safari, Self.notes])])
        Self.assertRect(try VitreusFixture.frame(left, key: "dock-pill"), CGRect(
            x: 1920 - thin - Self.thick, y: thin, width: Self.thick, height: Self.long(2)
        ))
        Self.assertRect(try VitreusFixture.frame(left, key: "dock-pill-glass"), CGRect(
            x: 1920 - thin - Self.thick, y: thin - Self.reach, width: Self.thick + Self.reach,
            height: Self.long(2) + Self.reach
        ))
        let bottom = try island(["layout": .string("fbottom"), "pins": .strings([Self.safari])])
        Self.assertRect(try VitreusFixture.frame(bottom, key: "dock-pill"), CGRect(
            x: thin, y: thin, width: Self.long(1), height: Self.thick
        ))
        let hidden = try island(["pins": .strings([Self.safari])])
        VitreusFixture.show(hidden, bar: VitreusFixture.bar(enabled: false))
        XCTAssertFalse(ShellVitreusBarTests.has(hidden, "dock-pill"))
    }
}

@MainActor
extension ShellVitreusDockTests {
    static let drawer = CGSize(width: 300 * panel, height: 280 * panel)
    static let home = CGRect(origin: CGPoint(x: 1920 - drawer.width, y: 1080 - drawer.height), size: drawer)

    static func slot(of rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + 14 * panel, y: rect.minY + 38 * panel, width: rect.width - 28 * panel,
            height: rect.height - 38 * panel - thick - 14 * panel
        )
    }

    func opened(_ addons: [String] = ["notes"], scale: CGFloat = 2) throws -> ShellRenderedWidget {
        let widget = try island(["addons": .strings(addons)], scale: scale)
        XCTAssertEqual(
            try press(widget, key: "addon-pin-notes"),
            ["shell trigger vitreus addon-opened \(VitreusFixture.bar().monitorId)"]
        )
        return widget
    }

    func testAddonComponentsFillTheAddonPillAndOpenTheirDrawerFromItsCorner() throws {
        let closed = try island(["addons": .strings(["notes", "pad", "notes", "missing"])])
        XCTAssertTrue(ShellVitreusBarTests.has(closed, "addon-pin-notes"))
        XCTAssertFalse(ShellVitreusBarTests.has(closed, "addon-pin-pad"))
        XCTAssertFalse(ShellVitreusBarTests.has(closed, "addon-drawer"))
        XCTAssertEqual(try VitreusFixture.frame(closed, key: "addon-pill").width, Self.long(1), accuracy: 0.001)
        let widget = try opened(["notes", "pad"])
        let home = Self.home
        Self.assertRect(try VitreusFixture.frame(widget, key: "addon-drawer"), home)
        Self.assertSpring(try follow(widget, "addon-drawer"), 300, 20)
        let layout = widget.surface.layout
        let glass = try VitreusFixture.element(widget, key: "addon-drawer-glass")
        XCTAssertEqual(layout.core.parent(of: glass), try VitreusFixture.element(widget, key: "corner-glass"))
        XCTAssertEqual(layout.core.content(of: glass).glassFollow, VitreusFixture.key("addon-drawer"))
        XCTAssertEqual(Double(layout.core.paint(of: glass).cornerRadius), 26 * Self.unit, accuracy: 1e-4)
        let edge = 26 * Self.panel
        Self.assertRect(CGRect(layout.core.absoluteFrame(of: glass)), CGRect(
            x: home.minX, y: home.minY, width: home.width + edge, height: home.height + edge
        ))
        Self.assertRect(try VitreusFixture.frame(widget, key: "notes"), Self.slot(of: home))
        XCTAssertTrue(widget.strings().contains("notes 1.5525"))
        XCTAssertTrue(widget.strings().contains("Notes"))
        let grip = try content(widget, "addon-grip")
        XCTAssertEqual(grip.gesture.threshold, 1)
        let move = try recipe(widget, "addon-grip")
        XCTAssertEqual(move.mode, .move)
        XCTAssertEqual(move.target, VitreusFixture.key("addon-drawer"))
        Self.assertRect(move.bounds, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        Self.assertSize(move.minimum, home.size)
        Self.assertSize(move.maximum, home.size)
        let close = try VitreusFixture.frame(widget, key: "addon-close")
        XCTAssertEqual(close.midX, home.maxX - 28 * Self.panel, accuracy: 0.001)
        XCTAssertEqual(close.midY, home.minY + 24 * Self.panel, accuracy: 0.001)
        XCTAssertEqual(try press(widget, key: "addon-pin-notes"), [])
        XCTAssertFalse(ShellVitreusBarTests.has(widget, "addon-drawer"))
        XCTAssertFalse(ShellVitreusBarTests.has(widget, "addon-drawer-glass"))
    }

    func testAddonDrawerGripSnapsHomeWithinSixtyPointsAndStaysWhereDroppedBeyond() throws {
        let widget = try opened()
        let home = Self.home
        try move(widget, key: "addon-grip", by: CGVector(dx: -30, dy: -40))
        XCTAssertNil(widget.surface.manipulation)
        Self.assertRect(try VitreusFixture.frame(widget, key: "addon-drawer"), home)
        XCTAssertTrue(try commit(widget, "addon-drawer").hasPrefix("placement-"))
        try move(widget, key: "addon-grip", by: CGVector(dx: -400, dy: -300))
        let placed = home.offsetBy(dx: -400, dy: -300)
        Self.assertRect(try VitreusFixture.frame(widget, key: "addon-drawer"), placed)
        Self.assertRect(try VitreusFixture.frame(widget, key: "addon-drawer-glass"), placed)
        Self.assertRect(try VitreusFixture.frame(widget, key: "notes"), Self.slot(of: placed))
        _ = try press(widget, key: "addon-close")
        XCTAssertFalse(ShellVitreusBarTests.has(widget, "addon-drawer"))
        _ = try press(widget, key: "addon-pin-notes")
        Self.assertRect(try VitreusFixture.frame(widget, key: "addon-drawer"), home)
        VitreusFixture.trigger(widget.instance, "addon-opened", VitreusFixture.bar().monitorId)
        VitreusFixture.show(widget)
        XCTAssertTrue(ShellVitreusBarTests.has(widget, "addon-drawer"))
        VitreusFixture.trigger(widget.instance, "addon-opened", "display:1")
        VitreusFixture.show(widget)
        XCTAssertFalse(ShellVitreusBarTests.has(widget, "addon-drawer"))
    }

    func testAddonDrawerCornersResizeDownToTheMinimumWithoutAnOutline() throws {
        let widget = try opened()
        for (edge, mask) in [("nw", 5), ("ne", 6), ("sw", 9), ("se", 10)] {
            let name = "addon-resize-" + edge
            let track = try recipe(widget, name)
            XCTAssertEqual(track.mode, .resize, name)
            XCTAssertEqual(track.resizeMask, UInt8(mask), name)
            Self.assertSize(track.minimum, CGSize(width: 240, height: 160), name)
            Self.assertSize(track.maximum, CGSize(width: 1920, height: 1080), name)
            XCTAssertEqual(track.outline?.enabled, false, name)
            XCTAssertEqual(try content(widget, name).cursor, .grab, name)
        }
        try move(widget, key: "addon-resize-nw", by: CGVector(dx: 400, dy: 400))
        XCTAssertNil(widget.surface.manipulation)
        let smallest = CGRect(x: 1680, y: 920, width: 240, height: 160)
        Self.assertRect(try VitreusFixture.frame(widget, key: "addon-drawer"), smallest)
        Self.assertRect(try VitreusFixture.frame(widget, key: "notes"), Self.slot(of: smallest))
        _ = try press(widget, key: "addon-close")
        _ = try press(widget, key: "addon-pin-notes")
        Self.assertRect(try VitreusFixture.frame(widget, key: "addon-drawer"), smallest)
    }

    func testDockAndAddonDrawerSnapshotAsCornerGlassMeltedIntoTheScreenEdges() throws {
        let widget = try island([
            "pins": .strings([Self.safari, Self.notes, Self.mail]), "addons": .strings(["notes"])
        ], scale: 1)
        _ = try press(widget, key: "addon-pin-notes")
        let body = try VitreusFixture.body(widget, key: "corner-glass")
        guard ShellLayerScene.engineQueue.sync(execute: { body.nativeAvailable }) else {
            throw XCTSkip("Native glass is unavailable")
        }
        let crop = CGRect(x: 0, y: 540, width: 1920, height: 540)
        let pixels = try VitreusFixture.pixels(widget, crop: crop, scale: 1, shadowless: true)
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            pixels[((y - Int(crop.minY)) * Int(crop.width) + x) * 4 + 3]
        }
        let dock = CGRect(x: 0, y: 1080 - Self.thick, width: Self.long(3), height: Self.thick)
        XCTAssertGreaterThan(alpha(Int(dock.midX), Int(dock.midY)), 0)
        XCTAssertGreaterThan(alpha(1, 1079), 0)
        XCTAssertGreaterThan(alpha(Int(dock.maxX) - 2, 1078), 0)
        XCTAssertEqual(alpha(Int(dock.maxX) - 1, Int(dock.minY) + 1), 0)
        XCTAssertEqual(alpha(Int(dock.maxX) + 6, Int(dock.midY)), 0)
        XCTAssertGreaterThan(alpha(Int(Self.home.midX), Int(Self.home.midY)), 0)
        XCTAssertGreaterThan(alpha(1919, 1079), 0)
        XCTAssertEqual(alpha(960, 1060), 0)
        XCTAssertEqual(alpha(Int(Self.home.minX) - 6, Int(Self.home.midY)), 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: Int(crop.width), height: Int(crop.height), bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: Int(crop.width) * 4, space: space,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little
                      .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return XCTFail("The snapshot could not be encoded") }
        try ShellVitreusDeskTests.write(image, name: "vitreus-docks-1920x1080-1x")
    }
}
