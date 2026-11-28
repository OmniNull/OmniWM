// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ConfigScriptHeldKeyTests: XCTestCase {
    private static let key = UInt32(kVK_ANSI_H)
    private static let escape = UInt32(kVK_Escape)
    private static let namedSource = """
    omniwm.keymap.mode("pan")
    omniwm.keymap.set("Shift+H", omniwm.cmd.focus("left"), { mode = "pan", repeatWhileHeld = true })
    omniwm.keymap.mode("other")
    omniwm.keymap.set("H", omniwm.cmd.focus("right"), { mode = "other", repeatWhileHeld = true })
    """
    private static let sidedSource = """
    omniwm.keymap.set("LeftShift+H", omniwm.cmd.focus("left"), { repeatWhileHeld = true })
    """

    func testNamedModeRepeatFollowsThePressThroughModeExitAndAnotherMode() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish(Self.namedSource)
        try fixture.selectMode("pan")
        fixture.play([.press(Self.key, flags: CGEventFlags.maskShift.rawValue)])
        fixture.play([.press(Self.escape), .release(Self.escape), .repeatPress(Self.key)])
        try fixture.selectMode("other")
        fixture.play([.repeatPress(Self.key), .release(Self.key), .press(Self.key), .release(Self.key)])
        fixture.play([.repeatPress(Self.key)], consumed: false)

        XCTAssertEqual(fixture.modeChanges, [.named, .normal, .named])
        XCTAssertEqual(fixture.invocations, [
            .init(.focus(.left), in: .named),
            .init(.focus(.left), in: .normal, repeatPress: true),
            .init(.focus(.left), in: .named, repeatPress: true),
            .init(.focus(.right), in: .named)
        ])
    }

    func testHeldFunctionEnqueuesEachFiringAfterModeExit() async throws {
        let fixture = Fixture(for: self)
        let firings: [Input] = [.press(Self.key), .repeatPress(Self.key), .repeatPress(Self.key)]
        try await fixture.publish("""
        local count = 0
        omniwm.keymap.mode("pan")
        omniwm.keymap.set("H", function()
            count += 1
        end, { mode = "pan", repeatWhileHeld = true })
        omniwm.command("Check", function() assert(count == \(firings.count)) end)
        """)
        let check = try XCTUnwrap(fixture.script.acceptedCommands.first { $0.name == "Check" })
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        fixture.center.onCommand = { [controller = fixture.controller] invocation in
            XCTAssertEqual(CommandHandler.handleHotkeyInvocation(invocation, controller: controller), .executed)
        }
        defer { fixture.center.onCommand = nil }
        try fixture.selectMode("pan")
        fixture.play([try XCTUnwrap(firings.first)])
        _ = fixture.center.setKeyboardMode(.normal)
        fixture.play(Array(firings.dropFirst()) + [.release(Self.key)])
        XCTAssertEqual(fixture.controller.enqueueConfigFunction(check.function), .executed)
        await queue.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testHeldCommandSurvivesReentrantRetirementDuringDelivery() async throws {
        let fixture = Fixture(for: self)
        let bundleID = "test.omniwm.held-key.lifetime"
        try await fixture.publish("""
        omniwm.keymap.mode("pan")
        omniwm.keymap.set("H", omniwm.act.openApp("\(bundleID)"), { mode = "pan", repeatWhileHeld = true })
        """)
        try fixture.selectMode("pan")
        var invocations: [Invocation] = []
        fixture.center.onCommand = { [weak center = fixture.center] invocation in
            let isRepeat = invocation.trigger?.isRepeat == true
            if isRepeat { center?.retireHeldBindings() }
            invocations.append(.init(invocation.command, in: .named, repeatPress: isRepeat))
        }
        fixture.play([.press(Self.key), .repeatPress(Self.key), .repeatPress(Self.key), .release(Self.key)])
        XCTAssertEqual(invocations, [
            .init(.openApp(bundleID), in: .named),
            .init(.openApp(bundleID), in: .named, repeatPress: true)
        ])
    }

    func testQueuedHeldActionsCannotResolveAgainstAReplacementScript() async throws {
        let fixture = Fixture(for: self)
        let controller = fixture.controller
        let firings: [Input] = [.press(Self.key), .repeatPress(Self.key)]
        try await fixture.publish("""
        omniwm.keymap.mode("pan")
        omniwm.keymap.set("H", function() end, { mode = "pan", repeatWhileHeld = true })
        """)
        let previous = try XCTUnwrap(fixture.script.acceptedBindings.first?.command)
        let mask = controller.settings.hyperKeyModifiers.carbonMask
        let replacement = try await fixture.script.loader.evaluate(Data("""
        local count = 0
        omniwm.keymap.mode("pan")
        omniwm.keymap.set("H", function() count += 1 end, { mode = "pan", repeatWhileHeld = true })
        omniwm.command("Check", function() assert(count == \(firings.count)) end)
        """.utf8), hyperMask: mask)
        XCTAssertNotEqual(previous, replacement.bindings.first?.command)

        controller.configureInputRouting()
        fixture.center.onKeyboardModeChange = nil
        controller.eventIntake.open(sink: controller.eventInterpreter)
        defer { controller.eventIntake.close() }
        try fixture.selectMode("pan")
        fixture.play(firings + [.release(Self.key)])
        XCTAssertTrue(fixture.script.apply(
            ConfigScriptLoad(versions: [:], result: .success(replacement)),
            hyperMask: mask
        ))
        controller.eventIntake.drainNow()

        _ = fixture.center.setKeyboardMode(.normal)
        try fixture.selectMode("pan")
        fixture.play(firings + [.release(Self.key)])
        controller.eventIntake.drainNow()
        let check = try XCTUnwrap(fixture.script.acceptedCommands.first { $0.name == "Check" })
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        XCTAssertEqual(controller.enqueueConfigFunction(check.function), .executed)
        await queue.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testUnflaggedNamedBindingConsumesRepeatsWithoutInvoking() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish("""
        omniwm.keymap.mode("pan")
        omniwm.keymap.set("H", omniwm.cmd.focus("left"), { mode = "pan" })
        """)
        try fixture.selectMode("pan")
        fixture.play([.press(Self.key), .repeatPress(Self.key), .release(Self.key)])
        XCTAssertEqual(fixture.invocations, [.init(.focus(.left), in: .named)])
    }

    func testSidedRepeatUsesItsPressedModifiersEvenAfterModifierUp() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish(Self.sidedSource)
        let chord = try fixture.installSidedRegistration()
        let shift = try XCTUnwrap(ModifierFlagMask.all.first { $0.carbon == UInt32(shiftKey) })
        fixture.play([.press(Self.key, flags: shift.independent | shift.right)], consumed: false)
        fixture.play([.repeatPress(Self.key, flags: shift.independent | shift.left)], consumed: false)
        fixture.play([
            .press(Self.key, flags: shift.independent | shift.left),
            .repeatPress(Self.key),
            .release(Self.key)
        ])
        fixture.play([.repeatPress(Self.key)], consumed: false)

        let actions: [Input] = [
            .press(Self.key, flags: shift.independent | shift.left),
            .repeatPress(Self.key)
        ]
        XCTAssertEqual(fixture.invocations, actions.map {
            Invocation(.focus(.left), in: .normal, repeatPress: $0.isRepeat)
        })
        XCTAssertEqual(fixture.triggers, actions.map {
            PhysicalHotkeyTrigger(keyCode: chord.keyCode, modifiers: chord.modifiers, isRepeat: $0.isRepeat)
        })
    }

    func testFailedReloadKeepsTheHoldAndIdenticalBuiltInReloadRetiresIt() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish(Self.sidedSource)
        _ = try fixture.installSidedRegistration()
        XCTAssertNil(fixture.script.callbackQueue)
        let shift = try XCTUnwrap(ModifierFlagMask.all.first { $0.carbon == UInt32(shiftKey) })
        let press = Input.press(Self.key, flags: shift.independent | shift.left)
        let repeatPress = Input.repeatPress(Self.key)
        let initialConfiguration = fixture.center.configuration
        fixture.play([press])

        try await fixture.publish("local =", succeeds: false)
        fixture.play([repeatPress])
        try await fixture.publish(Self.sidedSource)
        XCTAssertEqual(fixture.center.configuration, initialConfiguration)
        XCTAssertNil(fixture.script.callbackQueue)
        fixture.play([repeatPress, .release(Self.key)])
        fixture.play([repeatPress], consumed: false)
        fixture.play([press, repeatPress, .release(Self.key)])

        XCTAssertEqual(fixture.invocations, [press, repeatPress, press, repeatPress].map {
            Invocation(.focus(.left), in: .normal, repeatPress: $0.isRepeat)
        })
    }

    func testSidedRegistrationYieldCancelsRepeatAndKeepsSuppressionUntilKeyUp() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish(Self.sidedSource)
        let chord = try fixture.installSidedRegistration()
        let shift = try XCTUnwrap(ModifierFlagMask.all.first { $0.carbon == UInt32(shiftKey) })
        let pressFlags = shift.independent | shift.left
        fixture.play([.press(Self.key, flags: pressFlags)])

        fixture.center.setPaletteShortcutChords([chord])
        fixture.play([.repeatPress(Self.key, flags: pressFlags), .release(Self.key)])
        XCTAssertEqual(fixture.invocations, [.init(.focus(.left), in: .normal)])
    }

    func testSuspendingDropsRepeatAndKeepsSuppressionUntilKeyUp() async throws {
        let fixture = Fixture(for: self)
        try await fixture.publish(Self.sidedSource)
        _ = try fixture.installSidedRegistration()
        let shift = try XCTUnwrap(ModifierFlagMask.all.first { $0.carbon == UInt32(shiftKey) })
        let flags = shift.independent | shift.left
        let press = Input.press(Self.key, flags: flags)
        let repeatPress = Input.repeatPress(Self.key, flags: flags)
        fixture.play([press])

        fixture.center.setCommandHotkeysSuspended(true)
        fixture.play([repeatPress, .release(Self.key)])
        fixture.center.setCommandHotkeysSuspended(false)
        fixture.play([repeatPress], consumed: false)
        fixture.play([press, repeatPress, .release(Self.key)])

        XCTAssertEqual(fixture.invocations, [press, press, repeatPress].map {
            Invocation(.focus(.left), in: .normal, repeatPress: $0.isRepeat)
        })
    }
}

extension ConfigScriptHeldKeyTests {
    private enum Input {
        case press(UInt32, flags: UInt64 = 0)
        case repeatPress(UInt32, flags: UInt64 = 0)
        case release(UInt32)

        var isRepeat: Bool {
            if case .repeatPress = self { return true }
            return false
        }
    }

    private struct Invocation: Equatable {
        let command: HotkeyCommand
        let mode: KeyboardModeKind
        let repeatPress: Bool

        init(_ command: HotkeyCommand, in mode: KeyboardModeKind, repeatPress: Bool = false) {
            self.command = command
            self.mode = mode
            self.repeatPress = repeatPress
        }
    }

    @MainActor
    private final class Fixture {
        let controller: WMController
        let script: ConfigScriptController
        var invocations: [Invocation] = []
        var triggers: [PhysicalHotkeyTrigger] = []
        var modeChanges: [KeyboardModeKind] = []

        var center: HotkeyCenter {
            controller.hotkeys
        }

        init(for testCase: XCTestCase) {
            let controller = InputControllerTestSupport.controller(for: testCase)
            controller.settings.hotkeyBindings = []
            self.controller = controller
            let script = ConfigScriptController(
                fileURL: controller.settings.settingsFileURL.deletingLastPathComponent()
                    .appendingPathComponent(ConfigScriptController.fileName),
                settings: controller.settings,
                wmController: controller
            ) { [weak controller] resolution in
                guard let controller else { return }
                controller.updateHotkeyBindings(controller.settings.hotkeyBindings, scriptResolution: resolution)
            }
            self.script = script
            controller.configScript = script
            center.onKeyboardModeChange = { [weak self] kind in self?.modeChanges.append(kind) }
            center.onCommand = { [weak self] invocation in
                guard let self else { return }
                invocations.append(Invocation(
                    invocation.command, in: center.keyboardModeKind, repeatPress: invocation.trigger?.isRepeat == true
                ))
                if let trigger = invocation.trigger {
                    triggers.append(trigger)
                }
            }
        }

        func publish(
            _ source: String, succeeds: Bool = true, file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            let hyperMask = controller.settings.hyperKeyModifiers.carbonMask
            let result: Result<ConfigScriptEvaluation?, ConfigScriptError>
            do {
                let evaluation = try await script.loader.evaluate(Data(source.utf8), hyperMask: hyperMask)
                result = .success(evaluation)
            } catch let error as ConfigScriptError {
                result = .failure(error)
            }
            XCTAssertTrue(
                script.apply(ConfigScriptLoad(versions: [:], result: result), hyperMask: hyperMask),
                file: file, line: line
            )
            if succeeds {
                XCTAssertNil(script.diagnostic, file: file, line: line)
            } else {
                XCTAssertNotNil(script.diagnostic, file: file, line: line)
            }
        }

        func selectMode(_ name: String) throws {
            let mode = try XCTUnwrap(center.namedKeyModes.modes.first { $0.name == name })
            let index = try XCTUnwrap(center.namedKeyModes.index(of: mode.id))
            XCTAssertTrue(center.setKeyboardMode(.named(index)))
        }

        func installSidedRegistration() throws -> KeyBinding {
            let plan = HotkeyCenter.registrationPlan(for: center.configuration.bindings)
            let registration = try XCTUnwrap(plan.sideSpecificRegistrations.first)
            center.sideSpecificDispatch = plan.sideSpecificRegistrations.map(\.tapEntry)
            return registration.binding
        }

        func play(
            _ inputs: [Input], consumed: Bool = true, file: StaticString = #filePath, line: UInt = #line
        ) {
            for input in inputs {
                let captured = switch input {
                case let .press(keyCode, flags),
                     let .repeatPress(keyCode, flags):
                    center.dispatchCommandKeyDown(keyCode: keyCode, rawFlags: flags, isRepeat: input.isRepeat)
                case let .release(keyCode):
                    center.releaseSuppressedKey(keyCode)
                }
                XCTAssertEqual(captured, consumed, "\(input)", file: file, line: line)
            }
        }
    }
}
