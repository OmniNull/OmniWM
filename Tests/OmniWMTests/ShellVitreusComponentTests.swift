// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellVitreusComponentTests: XCTestCase {
    private let du = 1.242

    private func desk(now: Int = 1000, seed: [String: [UInt8]] = [:]) throws -> ShellRenderedWidget {
        let shell = try VitreusFixture.shell()
        let folder = shell.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return try VitreusFixture.clocked(shell, now: now, seed: seed)
    }

    private func focus(_ requests: [VitreusRequest], _ field: String) -> Double? {
        VitreusFixture.saved(requests, "focus", "focus")?.fields?[field]?.number
    }

    private func press(_ widget: ShellRenderedWidget, _ key: String, at now: Int? = nil) throws -> [VitreusRequest] {
        if let now { VitreusFixture.trigger(widget.instance, "clock", String(now)) }
        try VitreusFixture.click(widget, key: key)
        return VitreusFixture.drain(widget)
    }

    private func readsSeconds(_ widget: ShellRenderedWidget) -> Bool {
        let deps = widget.output().withUnsafeBytes { $0.loadUnaligned(as: omni_wire_header.self).deps }
        return deps & ShellDataKey.seconds.bit != 0
    }

    func testFocusChipsStartPauseResumeAndReset() throws {
        let widget = try desk()
        XCTAssertTrue(widget.strings().contains("30:00"))
        XCTAssertFalse(readsSeconds(widget))
        _ = VitreusFixture.drain(widget)
        var requests = try press(widget, "chip-45")
        XCTAssertEqual(focus(requests, "total"), 2700)
        XCTAssertEqual(focus(requests, "left"), 2700)
        XCTAssertTrue(widget.strings().contains("45:00"))
        requests = try press(widget, "start")
        XCTAssertEqual(requests.first { $0.kind == OMNI_SERVICE_TIMER }?.seconds, 2700)
        XCTAssertEqual(focus(requests, "ends"), 3700)
        XCTAssertEqual(focus(requests, "state"), 1)
        XCTAssertTrue(widget.strings().contains("FOCUSING"))
        XCTAssertTrue(widget.strings().contains("Pause"))
        XCTAssertTrue(readsSeconds(widget))
        XCTAssertNil(focus(try press(widget, "chip-15"), "total"))
        requests = try press(widget, "start", at: 1600)
        XCTAssertEqual(focus(requests, "left"), 2100)
        XCTAssertEqual(focus(requests, "state"), 2)
        XCTAssertTrue(widget.strings().contains("PAUSED"))
        XCTAssertTrue(widget.strings().contains("35:00"))
        XCTAssertFalse(readsSeconds(widget))
        requests = try press(widget, "start", at: 5000)
        XCTAssertEqual(focus(requests, "ends"), 7100)
        XCTAssertEqual(requests.last { $0.kind == OMNI_SERVICE_TIMER }?.seconds, 2100)
        requests = try press(widget, "reset")
        XCTAssertEqual(focus(requests, "state"), 0)
        XCTAssertEqual(focus(requests, "left"), 2700)
        XCTAssertTrue(widget.strings().contains("READY"))
        XCTAssertNil(focus(try press(widget, "reset"), "state"))
    }

    func testFocusFinishesOnItsDeadlineAndAgainRestartsAtTheChosenLength() throws {
        let widget = try desk()
        _ = try press(widget, "chip-15")
        let started = try XCTUnwrap(try press(widget, "start", at: 6000).first { $0.kind == OMNI_SERVICE_TIMER })
        XCTAssertEqual(started.seconds, 900)
        VitreusFixture.trigger(widget.instance, "clock", "6900")
        VitreusFixture.complete(widget, started)
        XCTAssertEqual(focus(VitreusFixture.drain(widget), "state"), 3)
        VitreusFixture.show(widget)
        for caption in ["DONE", "Again", "00:00"] {
            XCTAssertTrue(widget.strings().contains(caption), caption)
        }
        XCTAssertEqual(focus(try press(widget, "chip-60"), "total"), 3600)
        XCTAssertEqual(focus(try press(widget, "start", at: 7000), "ends"), 10600)
    }

    func testFocusRestoresItsAbsoluteDeadlineAndTheRingFollowsTheFraction() throws {
        let running = VitreusFixture.store("focus", .object([
            "length": .number(30), "state": .number(1), "total": .number(1800), "left": .number(1800),
            "ends": .number(2800)
        ]))
        let widget = try desk(now: 1900, seed: ["focus": running])
        XCTAssertEqual(VitreusFixture.drain(widget).first { $0.kind == OMNI_SERVICE_TIMER }?.seconds, 900)
        widget.set("seconds") { $0.number(1900) }
        widget.render(ShellBarData(monitor: VitreusFixture.primary))
        XCTAssertTrue(widget.strings().contains("15:00"))
        let ring = try XCTUnwrap(widget.tree().first { $0.key == VitreusFixture.key("ring") && $0.kind == .path })
        let tokens = widget.text.string(ring.content.text).split(separator: " ").map(String.init)
        let radius = String(format: "%.3f", 74 * du)
        XCTAssertEqual(Array(tokens[3 ... 8]), ["A", radius, radius, "0", "0", "1"])
        XCTAssertEqual(try XCTUnwrap(Double(tokens[9])), 170 * du, accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(Double(tokens[10])), 262 * du, accuracy: 0.002)

        let expired = try desk(now: 3000, seed: ["focus": running])
        let requests = VitreusFixture.drain(expired)
        XCTAssertFalse(requests.contains { $0.kind == OMNI_SERVICE_TIMER })
        XCTAssertEqual(focus(requests, "state"), 3)
        XCTAssertTrue(expired.strings().contains("DONE"))
    }

    func testStartGlowFollowsHoverBoundariesOnly() throws {
        let widget = try desk()
        let layout = widget.surface.layout
        func start() throws -> Content {
            try layout.core.content(of: VitreusFixture.element(widget, key: "start"))
        }
        func glow() throws -> Paint {
            try layout.core.paint(of: VitreusFixture.element(widget, key: "start-glass"))
        }
        XCTAssertEqual(Double(try glow().shadowRadius), 8 * du, accuracy: 0.01)
        XCTAssertEqual(try layout.core.paint(of: VitreusFixture.element(widget, key: "start")).shadow.role, 0)
        XCTAssertNotEqual(try start().hoverAction, 0)
        XCTAssertEqual(try start().gesture.axis, .none)
        for (phase, radius, alpha) in [(ShellEvent.Phase.began, 14.0, 0.64), (.ended, 8, 0.42)] {
            var event = ShellEvent()
            event.phase = phase
            widget.invoke(try start().hoverAction, event: event)
            VitreusFixture.show(widget)
            XCTAssertEqual(Double(try glow().shadowRadius), radius * du, accuracy: 0.01)
            XCTAssertEqual(try glow().shadow.role & 0xFF, UInt16(ShellRole.accent.rawValue + 1))
            XCTAssertEqual(Double(try glow().shadow.role >> 8) / 255, alpha, accuracy: 0.003)
        }
    }
}
