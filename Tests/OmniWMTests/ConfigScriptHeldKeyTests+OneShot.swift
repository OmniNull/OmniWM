// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics
@testable import OmniWM
import XCTest

extension ConfigScriptHeldKeyTests {
    func testOneShotMissKeepsTheModeAndEscapeOrHitExits() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish("""
        omniwm.keymap.mode("pan", { oneShot = true })
        omniwm.keymap.set("H", omniwm.cmd.focus("left"), { mode = "pan" })
        """)
        try fixture.selectMode("pan")
        let unboundKey = UInt32(kVK_ANSI_J)
        fixture.play([.press(unboundKey), .release(unboundKey)], consumed: false)
        XCTAssertEqual(fixture.center.activeNamedKeyMode?.name, "pan")
        XCTAssertTrue(fixture.invocations.isEmpty)
        fixture.play([.press(Self.escape), .release(Self.escape)])
        XCTAssertEqual(fixture.center.keyboardModeKind, .normal)
        XCTAssertTrue(fixture.invocations.isEmpty)

        try fixture.selectMode("pan")
        fixture.play([.press(Self.key), .repeatPress(Self.key), .release(Self.key)])
        XCTAssertEqual(fixture.center.keyboardModeKind, .normal)
        XCTAssertEqual(fixture.invocations, [.init(.focus(.left), in: .normal)])
        XCTAssertEqual(fixture.modeChanges, [.named, .normal, .named, .normal])
    }

    func testOneShotRepeatsThePressedBindingUntilKeyUp() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish("""
        omniwm.keymap.mode("pan", { oneShot = true })
        omniwm.keymap.set("Shift+H", omniwm.cmd.focus("left"), { mode = "pan", repeatWhileHeld = true })
        """)
        try fixture.selectMode("pan")
        let press = Input.press(Self.key, flags: CGEventFlags.maskShift.rawValue)
        let repeats: [Input] = [.repeatPress(Self.key), .repeatPress(Self.key)]
        fixture.play([press])
        XCTAssertEqual(fixture.center.keyboardModeKind, .normal)
        fixture.play(repeats + [.release(Self.key)])
        fixture.play([.repeatPress(Self.key)], consumed: false)

        XCTAssertEqual(fixture.invocations, ([press] + repeats).map {
            Invocation(.focus(.left), in: .normal, repeatPress: $0.isRepeat)
        })
        XCTAssertEqual(fixture.modeChanges, [.named, .normal])
    }

    func testOneShotReleaseExitsBeforeItsActionFires() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish("""
        omniwm.keymap.mode("pan", { oneShot = true })
        omniwm.keymap.set("Shift+H", omniwm.cmd.focus("left"), { mode = "pan", onRelease = true })
        """)
        try fixture.selectMode("pan")
        fixture.play([.press(Self.key, flags: CGEventFlags.maskShift.rawValue), .repeatPress(Self.key)])
        XCTAssertEqual(fixture.center.activeNamedKeyMode?.name, "pan")
        XCTAssertTrue(fixture.invocations.isEmpty)
        XCTAssertEqual(fixture.modeChanges, [.named])
        fixture.play([.release(Self.key)])
        fixture.play([.release(Self.key)], consumed: false)

        XCTAssertEqual(fixture.center.keyboardModeKind, .normal)
        XCTAssertEqual(fixture.invocations, [.init(.focus(.left), in: .normal)])
        XCTAssertEqual(fixture.modeChanges, [.named, .normal])
    }

    func testOneShotReleaseKeepsAnotherOneShotModeActive() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish("""
        omniwm.keymap.mode("pan", { oneShot = true })
        omniwm.keymap.set("H", omniwm.cmd.focus("left"), { mode = "pan", onRelease = true })
        omniwm.keymap.mode("other", { oneShot = true })
        omniwm.keymap.set("H", omniwm.cmd.focus("right"), { mode = "other" })
        """)
        try fixture.selectMode("pan")
        fixture.play([.press(Self.key)])
        try fixture.selectMode("other")
        fixture.play([.release(Self.key)])
        XCTAssertEqual(fixture.center.activeNamedKeyMode?.name, "other")
        XCTAssertEqual(fixture.invocations, [.init(.focus(.left), in: .named)])

        fixture.play([.press(Self.key), .release(Self.key)])
        XCTAssertEqual(fixture.center.keyboardModeKind, .normal)
        XCTAssertEqual(fixture.invocations, [.init(.focus(.left), in: .named), .init(.focus(.right), in: .normal)])
        XCTAssertEqual(fixture.modeChanges, [.named, .named, .normal])
    }

    func testOneShotPublishesTheSubmapExitBeforeTheKeyCallback() async throws {
        let fixture = Fixture(for: self)
        let controller = fixture.controller
        let eventName = ConfigScriptEventKind.keybindsSubmap.rawValue
        let normal = KeyboardModeKind.normal.rawValue
        let action = "action"
        let expectedOrder = [normal, action].joined(separator: ",")
        try await fixture.publish("""
        local wm = omniwm
        local events = {}
        wm.keymap.mode("pan", { oneShot = true })
        wm.on('\(eventName)', function(event) table.insert(events, event.name) end)
        wm.keymap.set("H", function() table.insert(events, '\(action)') end, { mode = "pan" })
        wm.command("Check", function() assert(table.concat(events, ',') == '\(expectedOrder)') end)
        """)
        let check = try XCTUnwrap(fixture.script.acceptedCommands.first { $0.name == "Check" })
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        try fixture.selectMode("pan")
        controller.configureInputRouting()
        fixture.center.onKeyboardModeChange = { [weak controller] kind in
            guard let controller else { return }
            ConfigScriptEventObservers.modeChanged(kind, controller: controller)
        }
        controller.eventIntake.open(sink: controller.eventInterpreter)
        defer { controller.eventIntake.close() }

        fixture.play([.press(Self.key), .release(Self.key)])
        XCTAssertEqual(fixture.center.keyboardModeKind, .normal)
        XCTAssertTrue(queue.hasPendingWork)
        controller.eventIntake.drainNow()
        XCTAssertEqual(controller.enqueueConfigFunction(check.function), .executed)
        await queue.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
    }
}
