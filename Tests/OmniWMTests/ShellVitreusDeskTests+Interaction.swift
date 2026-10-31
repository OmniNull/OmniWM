// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
private final class VitreusDisplays {
    struct Display {
        let instance: OpaquePointer
        let monitor: Monitor
        let island: Bool
    }

    let widget: ShellRenderedWidget
    let text = ShellTextStore()
    private(set) var displays: [Display] = []

    init(_ widget: ShellRenderedWidget, monitors: [Monitor]) throws {
        self.widget = widget
        for monitor in monitors {
            for island in [false, true] {
                let instance = try XCTUnwrap(omni_instance_create(widget.vm))
                displays.append(Display(instance: instance, monitor: monitor, island: island))
            }
        }
    }

    isolated deinit {
        for display in displays { omni_instance_destroy(display.instance) }
    }

    private func set(_ display: Display, _ key: String, _ write: (inout ShellValueWriter) -> Void) {
        var writer = ShellValueWriter()
        write(&writer)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(display.instance, key, $0.baseAddress, $0.count)
        }, OMNI_OK)
    }

    private func render(_ display: Display) throws -> [omni_wire_node] {
        set(display, "bar") { VitreusFixture.bar(display.monitor).write(to: &$0) }
        if display.island { set(display, "island") { VitreusFixture.island(display.monitor).write(to: &$0) } }
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            omni_instance_render(display.instance, OMNI_VIEW_BAR, 100_000_000, &stats, &error, error.count),
            OMNI_OK, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        )
        var count = 0
        let bytes = try Array(UnsafeBufferPointer(
            start: XCTUnwrap(omni_instance_output(display.instance, OMNI_VIEW_BAR, &count)), count: count
        ))
        text.ingest(wire: bytes)
        return bytes.withUnsafeBytes { buffer in
            let header = buffer.loadUnaligned(as: omni_wire_header.self)
            let stride = MemoryLayout<omni_wire_node>.stride
            return (0 ..< Int(header.node_count)).map {
                buffer.loadUnaligned(
                    fromByteOffset: MemoryLayout<omni_wire_header>.stride + $0 * stride, as: omni_wire_node.self
                )
            }
        }
    }

    func state() throws -> [String] {
        try displays.map { display in
            let nodes = try render(display)
            if display.island {
                return nodes.contains { $0.text != 0 && text.string($0.text) == "Focus" } ? "open" : "closed"
            }
            return try text.string(XCTUnwrap(nodes.first { $0.key == VitreusFixture.key("desk-opener") }).action)
        }
    }

    func send(_ name: String, _ value: String?, source: String? = nil) {
        for display in displays {
            VitreusFixture.trigger(display.instance, name, value, source: source)
        }
    }

    var logs: Int {
        displays.reduce(0) { $0 + omni_instance_message_count($1.instance, OMNI_MESSAGE_LOG) }
            + omni_vm_message_count(widget.vm, OMNI_MESSAGE_LOG)
    }
}

@MainActor
extension ShellVitreusDeskTests {
    private static let du = 1.242
    private static let envelope = CGRect(
        x: 1920 - 7.5 * du - 353 * du, y: 540 - 230 * du, width: 353 * du, height: 460 * du
    )
    private static let cx = envelope.minX + 176.5 * du

    private func assertFrame(
        _ widget: ShellRenderedWidget, _ name: String, x: Double, y: Double, size: CGSize
    ) throws {
        let frame = try VitreusFixture.frame(widget, key: name)
        XCTAssertEqual(frame.midX, x, accuracy: 0.01, name)
        XCTAssertEqual(frame.midY, y, accuracy: 0.01, name)
        XCTAssertEqual(frame.width, size.width, accuracy: 0.01, name)
        XCTAssertEqual(frame.height, size.height, accuracy: 0.01, name)
    }

    func testHitTargetsFollowTheVitreusGeometry() throws {
        let widget = try VitreusFixture.desk(shell())
        let (du, cx, top) = (Self.du, Self.cx, Self.envelope.minY)
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "desk").origin.x, Self.envelope.minX, accuracy: 0.01)
        XCTAssertEqual(try VitreusFixture.frame(widget, key: "desk").origin.y, top, accuracy: 0.01)
        try assertFrame(widget, "grip", x: cx, y: top + 11 * du, size: CGSize(width: 294 * du, height: 22 * du))
        let grip = try VitreusFixture.element(widget, key: "grip")
        let layout = widget.surface.layout
        XCTAssertEqual(layout.core.content(of: grip).hoverOpacity, 1)
        XCTAssertEqual(layout.core.content(of: grip).gesture.axis, .free)
        XCTAssertEqual(Double(layout.core.paint(of: grip).opacity), 0.2 / 0.55, accuracy: 0.001)
        let tab = CGSize(width: 134 * du, height: 34 * du)
        try assertFrame(
            widget,
            "close",
            x: cx + 143 * du,
            y: top + 40 * du,
            size: CGSize(width: 28 * du, height: 28 * du)
        )
        try assertFrame(widget, "tab-pad", x: cx - 85 * du, y: top + 40 * du, size: tab)
        try assertFrame(widget, "tab-focus", x: cx + 49 * du, y: top + 40 * du, size: tab)
        let thumb = CGSize(width: 126 * du, height: 26 * du)
        try assertFrame(widget, "tab-thumb", x: cx + 49 * du, y: top + 40 * du, size: thumb)
        let chip = CGSize(width: 58 * du, height: 32 * du)
        try assertFrame(widget, "chip-15", x: cx - 87 * du, y: top + 302 * du, size: chip)
        try assertFrame(
            widget,
            "start",
            x: cx - 38 * du,
            y: top + 363 * du,
            size: CGSize(width: 144 * du, height: 40 * du)
        )
        try assertFrame(
            widget,
            "reset",
            x: cx + 80 * du,
            y: top + 363 * du,
            size: CGSize(width: 76 * du, height: 40 * du)
        )
        try VitreusFixture.click(widget, key: "tab-pad")
        XCTAssertTrue(widget.strings().contains("Nothing to do. Nice."))
        XCTAssertFalse(widget.strings().contains("READY"))
        try assertFrame(widget, "tab-thumb", x: cx - 85 * du, y: top + 40 * du, size: thumb)
    }

    func testCloseSendsAnExplicitTriggerAndTheDeskBandClaimsPadding() throws {
        let shell = try shell()
        let bar = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), resources: VitreusFixture.resources(shell)
        )
        VitreusFixture.show(bar)
        let widget = try VitreusFixture.desk(shell)
        let close = try VitreusFixture.frame(widget, key: "close")
        let command = try XCTUnwrap(widget.surface.command(at: CGPoint(x: close.midX, y: close.midY)))
        let display = VitreusFixture.bar().monitorId
        XCTAssertEqual(command, "shell trigger vitreus desk-close \(display)")
        XCTAssertEqual(
            ShellAction(command), .trigger(widget: "vitreus", name: "desk-close", value: display)
        )
        let padding = CGPoint(x: Self.envelope.minX + 3 * Self.du, y: Self.envelope.midY)
        XCTAssertTrue(widget.surface.containsShape(at: padding))
        XCTAssertTrue(widget.surface.islandRegions().contains { $0.contains(padding) })
        XCTAssertNil(widget.surface.command(at: padding))
        XCTAssertTrue(widget.surface.hasAction(at: padding))
        let hit = widget.surface.element(at: padding, matching: { $0.acceptsPointer })
        XCTAssertEqual(hit, try VitreusFixture.element(widget, key: "desk-band"))
        VitreusFixture.trigger(widget.instance, "desk-close", nil)
        VitreusFixture.show(widget)
        XCTAssertEqual(widget.surface.islandRegions(), bar.surface.islandRegions())
        XCTAssertFalse(widget.surface.containsShape(at: padding))
    }

    func testToggleFlipsTheDeskOnItsDisplayAndClosesItForAnother() throws {
        let shell = try shell()
        let widget = try ShellRenderedWidget(
            source: VitreusFixture.source(shell), resources: VitreusFixture.resources(shell)
        )
        let display = VitreusFixture.bar().monitorId
        let other = VitreusFixture.bar(VitreusFixture.monitor(id: VitreusFixture.monitor().displayId + 1)).monitorId
        func toggle(_ value: String) -> Bool {
            VitreusFixture.trigger(widget.instance, "toggle", value)
            VitreusFixture.show(widget)
            let layout = widget.surface.layout
            return layout.core.elements { _ in true }.contains { layout.core.key(of: $0) == VitreusFixture.key("desk") }
        }
        VitreusFixture.show(widget)
        XCTAssertTrue(toggle(display))
        XCTAssertFalse(toggle(display))
        XCTAssertTrue(toggle(display))
        XCTAssertFalse(toggle(other))
    }

    func testChipsActOnlyWhenIdleAndResetOnlyWhileBusy() throws {
        let widget = try VitreusFixture.desk(shell())
        let layout = widget.surface.layout
        func actionable(_ name: String) -> Bool {
            layout.core.elements { $0.action != 0 }.contains { layout.core.key(of: $0) == VitreusFixture.key(name) }
        }
        func chips() -> [Bool] {
            [15, 30, 45, 60].map { actionable("chip-\($0)") }
        }
        XCTAssertEqual(chips(), [true, true, true, true])
        XCTAssertFalse(actionable("reset"))
        try VitreusFixture.click(widget, key: "start")
        XCTAssertTrue(widget.strings().contains("FOCUSING"))
        XCTAssertEqual(chips(), [false, false, false, false])
        XCTAssertTrue(actionable("reset"))
        try VitreusFixture.click(widget, key: "start")
        XCTAssertTrue(widget.strings().contains("PAUSED"))
        XCTAssertTrue(actionable("reset"))
        try VitreusFixture.click(widget, key: "reset")
        XCTAssertTrue(widget.strings().contains("READY"))
        XCTAssertEqual(chips(), [true, true, true, true])
    }

    func testOneDeskOpensAcrossBarAndIslandInstancesOfOneVM() throws {
        let widget = try ShellRenderedWidget(source: VitreusFixture.source(shell()))
        let monitors = [
            VitreusFixture.monitor(VitreusFixture.primary, id: 95101),
            VitreusFixture.monitor(VitreusFixture.secondary, id: 95102, width: 2560, height: 1440)
        ]
        let (first, second) = (VitreusFixture.bar(monitors[0]).monitorId, VitreusFixture.bar(monitors[1]).monitorId)
        let displays = try VitreusDisplays(widget, monitors: monitors)
        let opens = { (name: String) in "shell trigger vitreus desk-open \(name)" }
        let closes = { (name: String) in "shell trigger vitreus desk-close \(name)" }
        let closed = [opens(first), "closed", opens(second), "closed"]
        XCTAssertEqual(try displays.state(), closed)
        XCTAssertEqual(ShellAction(opens(first)), .trigger(widget: "vitreus", name: "desk-open", value: first))
        displays.send("desk-open", first)
        XCTAssertEqual(try displays.state(), [closes(first), "open", opens(second), "closed"])
        displays.send("desk-open", second)
        XCTAssertEqual(try displays.state(), [opens(first), "closed", closes(second), "open"])
        displays.send("desk", first)
        XCTAssertEqual(try displays.state(), [closes(first), "open", opens(second), "closed"])
        displays.send("desk", first)
        XCTAssertEqual(try displays.state(), closed)
        displays.send("desk-open", second)
        displays.send("desk-close", nil)
        XCTAssertEqual(try displays.state(), closed)
        let logs = displays.logs
        displays.send("desk", nil)
        displays.send("desk-open", nil)
        XCTAssertEqual(try displays.state(), closed)
        XCTAssertEqual(displays.logs, logs + 1)
        displays.send("desk-open", first)
        for name in ["reloaded", "displayChanged", "desk-close"] {
            displays.send(name, nil, source: "host")
        }
        displays.send("unrelated", first)
        XCTAssertEqual(try displays.state(), [closes(first), "open", opens(second), "closed"])
    }

    func testSameNamedDisplaysUseDistinctDeskTargets() throws {
        let widget = try ShellRenderedWidget(source: VitreusFixture.source(shell()))
        let monitors = [
            VitreusFixture.monitor("Studio Display", id: 95103),
            VitreusFixture.monitor("Studio Display", id: 95104)
        ]
        let (first, second) = (VitreusFixture.bar(monitors[0]).monitorId, VitreusFixture.bar(monitors[1]).monitorId)
        XCTAssertEqual(monitors[0].name, monitors[1].name)
        XCTAssertNotEqual(first, second)
        let displays = try VitreusDisplays(widget, monitors: monitors)
        let opens = { (id: String) in "shell trigger vitreus desk-open \(id)" }
        let closes = { (id: String) in "shell trigger vitreus desk-close \(id)" }
        XCTAssertEqual(try displays.state(), [opens(first), "closed", opens(second), "closed"])
        displays.send("desk-open", first)
        XCTAssertEqual(try displays.state(), [closes(first), "open", opens(second), "closed"])
        displays.send("desk-open", monitors[0].name)
        XCTAssertEqual(try displays.state(), [closes(first), "open", opens(second), "closed"])
        displays.send("desk-open", second)
        XCTAssertEqual(try displays.state(), [opens(first), "closed", closes(second), "open"])
        displays.send("desk-close", first)
        XCTAssertEqual(try displays.state(), [opens(first), "closed", closes(second), "open"])
        displays.send("desk-close", second)
        XCTAssertEqual(try displays.state(), [opens(first), "closed", opens(second), "closed"])
    }
}
