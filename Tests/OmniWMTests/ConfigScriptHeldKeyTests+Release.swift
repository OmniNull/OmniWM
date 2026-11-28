// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics
@testable import OmniWM
import XCTest

extension ConfigScriptHeldKeyTests {
    private static let sidedReleaseSource = """
    omniwm.keymap.set("LeftShift+H", omniwm.cmd.focus("left"), { onRelease = true })
    """

    func testNamedReleaseUsesThePressedBindingAfterModeExit() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish("""
        omniwm.keymap.mode("pan")
        omniwm.keymap.set("Shift+H", omniwm.cmd.focus("left"), { mode = "pan", onRelease = true })
        omniwm.keymap.mode("other")
        omniwm.keymap.set("H", omniwm.cmd.focus("right"), { mode = "other", onRelease = true })
        """)
        let original = try XCTUnwrap(KeySymbolMapper.fromHumanReadable("Shift+H"))
        let replacement = try XCTUnwrap(KeySymbolMapper.fromHumanReadable("H"))
        try fixture.selectMode("pan")
        let press = Input.press(Self.key, flags: CGEventFlags.maskShift.rawValue)
        let repeatPress = Input.repeatPress(Self.key)
        let release = Input.release(Self.key)
        fixture.play([press, .press(Self.escape), .release(Self.escape), repeatPress])
        try fixture.selectMode("other")
        fixture.play([repeatPress])
        XCTAssertTrue(fixture.invocations.isEmpty)
        fixture.play([release])
        fixture.play([release], consumed: false)
        fixture.play([.press(Self.key), repeatPress])
        XCTAssertEqual(fixture.invocations, [.init(.focus(.left), in: .named)])
        fixture.play([release])

        XCTAssertEqual(fixture.modeChanges, [.named, .normal, .named])
        XCTAssertEqual(fixture.invocations, [.init(.focus(.left), in: .named), .init(.focus(.right), in: .named)])
        XCTAssertEqual(fixture.triggers, [original, replacement].map {
            PhysicalHotkeyTrigger(keyCode: $0.keyCode, modifiers: $0.modifiers, isRepeat: false)
        })
    }

    func testSidedReleaseUsesOriginalModifiersAndIgnoresRepeats() async throws {
        let (fixture, chord) = try await sidedReleaseFixture()
        let shift = try shiftFlags()
        let flags = shift.independent
        let release = Input.release(Self.key)
        fixture.play([.press(Self.key, flags: flags | shift.right), release], consumed: false)
        fixture.play([.press(Self.key, flags: flags | shift.left), .repeatPress(Self.key)])
        XCTAssertTrue(fixture.invocations.isEmpty)
        fixture.play([release])
        fixture.play([release], consumed: false)

        XCTAssertEqual(fixture.invocations, [.init(.focus(.left), in: .normal)])
        XCTAssertEqual(fixture.triggers, [PhysicalHotkeyTrigger(
            keyCode: chord.keyCode, modifiers: chord.modifiers, isRepeat: false
        )])
    }

    func testFailedReloadKeepsReleaseWhileIdenticalBuiltInReloadCancelsIt() async throws {
        let (fixture, _) = try await sidedReleaseFixture()
        let shift = try shiftFlags()
        let press = Input.press(Self.key, flags: shift.independent | shift.left)
        let release = Input.release(Self.key)
        let expected = Invocation(.focus(.left), in: .normal)
        let initialConfiguration = fixture.center.configuration
        XCTAssertNil(fixture.script.callbackQueue)
        fixture.play([press])
        try await fixture.publish("local =", succeeds: false)
        fixture.play([.repeatPress(Self.key)])
        XCTAssertTrue(fixture.invocations.isEmpty)
        fixture.play([release, press])
        XCTAssertEqual(fixture.invocations, [expected])

        try await fixture.publish(Self.sidedReleaseSource)
        XCTAssertNil(fixture.script.callbackQueue)
        XCTAssertEqual(fixture.center.configuration, initialConfiguration)
        fixture.play([.repeatPress(Self.key), release])
        fixture.play([release], consumed: false)
        XCTAssertEqual(fixture.invocations, [expected])
        fixture.play([press, release])
        XCTAssertEqual(fixture.invocations, [expected, expected])
    }

    func testPaletteYieldCancelsPendingReleaseAfterRegistrationReturns() async throws {
        let (fixture, chord) = try await sidedReleaseFixture()
        let shift = try shiftFlags()
        let press = Input.press(Self.key, flags: shift.independent | shift.left)
        let release = Input.release(Self.key)
        fixture.play([press])
        fixture.center.setPaletteShortcutChords([chord])
        fixture.play([.repeatPress(Self.key)])
        fixture.center.setPaletteShortcutChords([])
        _ = try fixture.installSidedRegistration()
        fixture.play([release])
        XCTAssertTrue(fixture.invocations.isEmpty)
        fixture.play([press, release])
        XCTAssertEqual(fixture.invocations, [.init(.focus(.left), in: .normal)])
    }

    func testRemovalAndSuspensionCancelReleaseAndRetainKeyUpSuppression() async throws {
        let (fixture, _) = try await sidedReleaseFixture()
        let shift = try shiftFlags()
        let press = Input.press(Self.key, flags: shift.independent | shift.left)
        let release = Input.release(Self.key)
        fixture.play([press])
        fixture.center.sideSpecificDispatch = []
        fixture.play([release])
        fixture.play([press, release], consumed: false)
        _ = try fixture.installSidedRegistration()
        fixture.play([press])
        fixture.center.setCommandHotkeysSuspended(true)
        fixture.play([.repeatPress(Self.key), release])
        XCTAssertTrue(fixture.invocations.isEmpty)
        fixture.center.setCommandHotkeysSuspended(false)
        fixture.play([press, release])
        XCTAssertEqual(fixture.invocations, [.init(.focus(.left), in: .normal)])
    }

    func testLegacyWindowModeReleaseSurvivesEscape() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish("""
        omniwm.keymap.set("Control+H", omniwm.cmd.focus("left"), { modeKey = "H", onRelease = true })
        """)
        XCTAssertTrue(fixture.center.setKeyboardMode(.window))
        fixture.play([.press(Self.key), .repeatPress(Self.key), .press(Self.escape), .release(Self.escape)])
        XCTAssertTrue(fixture.invocations.isEmpty)
        fixture.play([.release(Self.key)])
        XCTAssertEqual(fixture.invocations, [.init(.focus(.left), in: .normal)])
    }

    func testReleaseFunctionEnqueuesOnceThroughTheCallbackWorker() async throws {
        let fixture = Fixture(for: self)
        let releases: [Input] = [.release(Self.key)]
        try await fixture.publish("""
        local count = 0
        omniwm.keymap.mode("pan")
        omniwm.keymap.set("H", function() count += 1 end, { mode = "pan", onRelease = true })
        omniwm.command("Check", function() assert(count == \(releases.count)) end)
        """)
        let check = try XCTUnwrap(fixture.script.acceptedCommands.first { $0.name == "Check" })
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        var deliveries: [PhysicalHotkeyTrigger] = []
        fixture.center.onCommand = { [controller = fixture.controller] invocation in
            if let trigger = invocation.trigger { deliveries.append(trigger) }
            XCTAssertEqual(CommandHandler.handleHotkeyInvocation(invocation, controller: controller), .executed)
        }
        defer { fixture.center.onCommand = nil }
        try fixture.selectMode("pan")
        fixture.play([.press(Self.key), .repeatPress(Self.key), .press(Self.escape), .release(Self.escape)])
        XCTAssertTrue(deliveries.isEmpty)
        fixture.play(releases)
        fixture.play(releases, consumed: false)
        let chord = try XCTUnwrap(KeySymbolMapper.fromHumanReadable("H"))
        XCTAssertEqual(deliveries, releases.map { _ in
            PhysicalHotkeyTrigger(keyCode: chord.keyCode, modifiers: chord.modifiers, isRepeat: false)
        })
        XCTAssertEqual(fixture.controller.enqueueConfigFunction(check.function), .executed)
        await queue.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testReleaseClearsTheHoldBeforeReentrantDelivery() async throws {
        let fixture = Fixture(for: self)
        let bundleID = "test.omniwm.held-key.release-lifetime"
        try await fixture.publish("""
        omniwm.keymap.mode("pan")
        omniwm.keymap.set("H", omniwm.act.openApp("\(bundleID)"), { mode = "pan", onRelease = true })
        """)
        try fixture.selectMode("pan")
        var commands: [HotkeyCommand] = []
        fixture.center.onCommand = { [weak center = fixture.center] invocation in
            commands.append(invocation.command)
            if commands.count == 1 {
                XCTAssertEqual(center?.releaseSuppressedKey(Self.key), false)
                center?.retireHeldBindings()
            }
        }
        fixture.play([.press(Self.key), .repeatPress(Self.key)])
        XCTAssertTrue(commands.isEmpty)
        fixture.play([.release(Self.key)])
        XCTAssertEqual(commands, [.openApp(bundleID)])
    }

    func testCarbonDispatchDefersReleaseAndPreservesOrdinaryRepeat() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish("""
        omniwm.keymap.set("Control+H", omniwm.cmd.focus("left"), { onRelease = true })
        omniwm.keymap.set("Control+J", omniwm.cmd.focus("right"))
        """)
        let release = try recordCarbonBinding(.focus(.left), in: fixture)
        let ordinary = try recordCarbonBinding(.focus(.right), in: fixture)
        var delivered: [HotkeyInvocation] = []
        fixture.center.onCommand = { delivered.append($0) }
        let down = UInt32(kEventHotKeyPressed)
        let up = UInt32(kEventHotKeyReleased)
        let presses = [down, down]
        for kind in [up] + presses {
            fixture.center.handleCarbonHotkey(id: release.keyCode, kind: kind)
        }
        XCTAssertTrue(delivered.isEmpty)
        fixture.center.handleCarbonHotkey(id: release.keyCode, kind: up)
        fixture.center.handleCarbonHotkey(id: release.keyCode, kind: up)
        for kind in presses + [up] {
            fixture.center.handleCarbonHotkey(id: ordinary.keyCode, kind: kind)
        }
        let expectedRelease = HotkeyInvocation(command: .focus(.left), trigger: PhysicalHotkeyTrigger(
            keyCode: release.keyCode, modifiers: release.modifiers, isRepeat: false
        ))
        let expectedPresses = presses.indices.map {
            HotkeyInvocation(command: .focus(.right), trigger: PhysicalHotkeyTrigger(
                keyCode: ordinary.keyCode, modifiers: ordinary.modifiers, isRepeat: $0 != presses.startIndex
            ))
        }
        XCTAssertEqual(delivered, [expectedRelease] + expectedPresses)
    }

    func testCarbonReleaseRetiresOnIdenticalSuccessfulReloadOnly() async throws {
        let fixture = Fixture(for: self)
        let source = "omniwm.keymap.set('Control+H', omniwm.cmd.focus('left'), { onRelease = true })"
        try await fixture.publish(source)
        let chord = try recordCarbonBinding(.focus(.left), in: fixture)
        var delivered: [HotkeyInvocation] = []
        fixture.center.onCommand = { delivered.append($0) }
        let down = UInt32(kEventHotKeyPressed)
        let up = UInt32(kEventHotKeyReleased)
        let expected = HotkeyInvocation(command: .focus(.left), trigger: PhysicalHotkeyTrigger(
            keyCode: chord.keyCode, modifiers: chord.modifiers, isRepeat: false
        ))
        XCTAssertNil(fixture.script.callbackQueue)
        fixture.center.handleCarbonHotkey(id: chord.keyCode, kind: down)
        try await fixture.publish("local =", succeeds: false)
        fixture.center.handleCarbonHotkey(id: chord.keyCode, kind: up)
        XCTAssertEqual(delivered, [expected])

        fixture.center.handleCarbonHotkey(id: chord.keyCode, kind: down)
        try await fixture.publish(source)
        XCTAssertNil(fixture.script.callbackQueue)
        fixture.center.handleCarbonHotkey(id: chord.keyCode, kind: up)
        XCTAssertEqual(delivered, [expected])
        fixture.center.handleCarbonHotkey(id: chord.keyCode, kind: down)
        fixture.center.handleCarbonHotkey(id: chord.keyCode, kind: up)
        XCTAssertEqual(delivered, [expected, expected])
    }

    private func recordCarbonBinding(_ command: HotkeyCommand, in fixture: Fixture) throws -> KeyBinding {
        let plan = HotkeyCenter.registrationPlan(for: fixture.center.configuration.bindings)
        let registration = try XCTUnwrap(plan.registrations.first { $0.command == command })
        fixture.center.carbonRegistrations.recordRegistration(registration, id: registration.binding.keyCode)
        return registration.binding
    }

    private func sidedReleaseFixture() async throws -> (Fixture, KeyBinding) {
        let fixture = Fixture(for: self)
        try await fixture.publish(Self.sidedReleaseSource)
        return (fixture, try fixture.installSidedRegistration())
    }

    private func shiftFlags() throws -> ModifierFlagMask {
        try XCTUnwrap(ModifierFlagMask.all.first { $0.carbon == UInt32(shiftKey) })
    }
}
