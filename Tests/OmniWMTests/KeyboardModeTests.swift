// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class KeyboardModeTests: XCTestCase {
    private let keyH = UInt32(kVK_ANSI_H)
    private let keyL = UInt32(kVK_ANSI_L)
    private let keyX = UInt32(kVK_ANSI_X)
    private let keyEscape = UInt32(kVK_Escape)
    private let shiftFlag = CGEventFlags.maskShift.rawValue

    private func modeTable() -> KeyboardModeTable {
        KeyboardModeTable(bindings: [
            HotkeyBinding(
                id: "focus.left",
                command: .focus(.left),
                trigger: .unassigned,
                modeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: 0)
            ),
            HotkeyBinding(
                id: "move.right",
                command: .move(.right),
                trigger: .unassigned,
                modeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(shiftKey))
            )
        ])
    }

    private let leftShiftP = KeyBinding(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(shiftKey),
        sidedModifiers: SidedModifiers(left: UInt32(shiftKey))
    )
    private let leftShiftFlags = CGEventFlags.maskShift.rawValue | UInt64(NX_DEVICELSHIFTKEYMASK)

    private func keyEvent(
        _ keyCode: UInt32,
        down: Bool,
        flags: UInt64 = 0,
        isRepeat: Bool = false
    ) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down))
        event.flags = CGEventFlags(rawValue: flags)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
        return event
    }

    private func passesThrough(_ center: HotkeyCenter, _ type: CGEventType, _ event: CGEvent) -> Bool {
        center.handleHyperTriggerEvent(type: type, event: event) != nil
    }

    private func modeKeyCenter(
        extraBindings: [HotkeyBinding] = [],
        onCommand: @escaping (HotkeyInvocation) -> Void = { _ in }
    ) throws -> HotkeyCenter {
        let center = HotkeyCenter()
        center.onCommand = onCommand
        center.updateBindings(
            extraBindings + [
                HotkeyBinding(
                    id: "focus.left",
                    command: .focus(.left),
                    trigger: .unassigned,
                    modeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: 0)
                )
            ],
            systemHyperTrigger: .none
        )
        center.start()
        if center.hyperTriggerTap == nil {
            center.stop()
            throw MissingTestPrerequisite("Needs a keyboard event tap (Input Monitoring)")
        }
        return center
    }

    private func mouseTrigger(_ button: Int64) throws -> HotkeyTrigger {
        .mouseButton(try XCTUnwrap(MouseButtonBinding(button: button, modifiers: 0)))
    }

    private func keyDown(
        _ input: inout KeyboardModeInput,
        _ keyCode: UInt32,
        flags: UInt64 = 0,
        at now: TimeInterval = 10,
        isRepeat: Bool = false
    ) -> KeyboardModeInput.Decision {
        input.handleKeyDown(keyCode: keyCode, rawFlags: flags, isRepeat: isRepeat, now: now, table: modeTable())
    }

    func testFreshPrefixRunsBoundKeyThenReturnsToNormal() {
        var input = KeyboardModeInput(state: .prefix(repeatDeadline: nil))

        let decision = keyDown(&input, keyH)

        XCTAssertEqual(decision, KeyboardModeInput.Decision(consumed: true, command: .focus(.left)))
        XCTAssertEqual(input.state, .normal)
    }

    func testFreshPrefixConsumesAnUnboundPlainKeyAndEnds() {
        var input = KeyboardModeInput(state: .prefix(repeatDeadline: nil))

        XCTAssertEqual(keyDown(&input, keyX), KeyboardModeInput.Decision(consumed: true, command: nil))
        XCTAssertEqual(input.state, .normal)
    }

    func testPrefixPassesCommandChordsThroughAndEnds() {
        var input = KeyboardModeInput(state: .prefix(repeatDeadline: nil))

        XCTAssertEqual(keyDown(&input, keyH, flags: CGEventFlags.maskCommand.rawValue), KeyboardModeInput.Decision())
        XCTAssertEqual(input.state, .normal)
    }

    func testRepeatableCommandRepeatsOnlyInsideTheWindow() {
        var input = KeyboardModeInput(state: .prefix(repeatDeadline: nil))

        XCTAssertEqual(keyDown(&input, keyL, flags: shiftFlag, at: 10).command, .move(.right))
        XCTAssertEqual(input.state, .prefix(repeatDeadline: 10.5))
        XCTAssertEqual(keyDown(&input, keyL, flags: shiftFlag, at: 10.3).command, .move(.right))
        XCTAssertEqual(input.state, .prefix(repeatDeadline: 10.8))

        XCTAssertEqual(keyDown(&input, keyL, flags: shiftFlag, at: 10.9), KeyboardModeInput.Decision())
        XCTAssertEqual(input.state, .normal)
    }

    func testRepeatWindowEndsOnANonRepeatableKeyWithoutConsumingIt() {
        var input = KeyboardModeInput(state: .prefix(repeatDeadline: 10.5))

        XCTAssertEqual(keyDown(&input, keyH, at: 10.1), KeyboardModeInput.Decision())
        XCTAssertEqual(input.state, .normal)
    }

    func testWindowModeStaysUntilEscape() {
        var input = KeyboardModeInput(state: .window)

        XCTAssertEqual(keyDown(&input, keyH), KeyboardModeInput.Decision(consumed: true, command: .focus(.left)))
        XCTAssertEqual(keyDown(&input, keyX), KeyboardModeInput.Decision(consumed: true, command: nil))
        XCTAssertEqual(keyDown(&input, keyX, flags: CGEventFlags.maskControl.rawValue), KeyboardModeInput.Decision())
        XCTAssertEqual(input.state, .window)

        XCTAssertEqual(keyDown(&input, keyEscape), KeyboardModeInput.Decision(consumed: true, command: nil))
        XCTAssertEqual(input.state, .normal)
    }

    func testAutorepeatAndIdleStatesAreNeverCaptured() {
        var window = KeyboardModeInput(state: .window)
        XCTAssertEqual(keyDown(&window, keyH, isRepeat: true), KeyboardModeInput.Decision())

        for state in [KeyboardModeInput.State.normal, .paused] {
            var input = KeyboardModeInput(state: state)
            XCTAssertEqual(keyDown(&input, keyH), KeyboardModeInput.Decision())
            XCTAssertEqual(input.state, state)
        }
    }

    func testTableKeepsOnlySupportedUniqueModeKeys() {
        let plainH = KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: 0)
        let table = KeyboardModeTable(bindings: [
            HotkeyBinding(id: "focus.left", command: .focus(.left), trigger: .unassigned, modeKey: plainH),
            HotkeyBinding(id: "focus.right", command: .focus(.right), trigger: .unassigned, modeKey: plainH),
            HotkeyBinding(
                id: "focus.up",
                command: .focus(.up),
                trigger: .unassigned,
                modeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey))
            ),
            HotkeyBinding(
                id: "focus.down",
                command: .focus(.down),
                trigger: .unassigned,
                modeKey: KeyBinding(keyCode: UInt32(kVK_Escape), modifiers: 0)
            ),
            HotkeyBinding(
                id: "toggleShortcutPause",
                command: .keyboardMode(.togglePause),
                trigger: .unassigned,
                modeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: 0)
            ),
            HotkeyBinding(
                id: "move.left",
                command: .move(.left),
                trigger: .unassigned,
                modeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(shiftKey))
            )
        ])

        XCTAssertEqual(table.entries.map(\.command), [.move(.left)])
        XCTAssertEqual(table.failures, [
            .focus(.left): .duplicateKey,
            .focus(.right): .duplicateKey,
            .focus(.up): .unsupportedKey,
            .focus(.down): .unsupportedKey,
            .keyboardMode(.togglePause): .unsupportedKey
        ])
    }

    func testPauseKeepsOnlyPauseControlsUntilResumed() throws {
        let center = HotkeyCenter()
        var received: [HotkeyInvocation] = []
        var kinds: [KeyboardModeKind] = []
        center.onCommand = { received.append($0) }
        center.onKeyboardModeChange = { kinds.append($0) }
        center.updateBindings(
            [
                HotkeyBinding(
                    id: "toggleShortcutPause",
                    command: .keyboardMode(.togglePause),
                    trigger: try mouseTrigger(3)
                ),
                HotkeyBinding(id: "switchWorkspace.next", command: .workspace(.next), trigger: try mouseTrigger(4))
            ],
            systemHyperTrigger: .none
        )
        center.start()
        defer { center.stop() }

        XCTAssertTrue(center.dispatchMouseButton(3, flags: []))
        XCTAssertEqual(center.keyboardModeKind, .paused)
        XCTAssertFalse(center.dispatchMouseButton(4, flags: []))

        center.setCommandHotkeysSuspended(true)
        center.setCommandHotkeysSuspended(false)
        center.updateBindings(center.configuration.bindings, systemHyperTrigger: .none, force: true)
        XCTAssertEqual(center.keyboardModeKind, .paused)
        XCTAssertFalse(center.dispatchMouseButton(4, flags: []))

        XCTAssertTrue(center.dispatchMouseButton(3, flags: []))
        XCTAssertEqual(center.keyboardModeKind, .normal)
        XCTAssertTrue(center.dispatchMouseButton(4, flags: []))
        XCTAssertEqual(received, [HotkeyInvocation(command: .workspace(.next))])
        XCTAssertEqual(kinds, [.paused, .normal])
    }

    func testPauseEndsWhenItsTimerFires() async throws {
        let sleeper = ManualSleeper()
        let center = HotkeyCenter(sleep: { try await sleeper.sleep(for: $0) })
        let resumed = expectation(description: "pause ended")
        center.onKeyboardModeChange = { kind in
            if kind == .normal { resumed.fulfill() }
        }
        center.configureKeyboardModes(SettingsExport.KeyboardModes(pauseTimeoutSeconds: 5))
        center.start()
        defer { center.stop() }

        XCTAssertTrue(center.performKeyboardModeCommand(.togglePause))
        await sleeper.waitForPendingSleeps(1)
        XCTAssertEqual(sleeper.requestedDurations, [.seconds(5)])
        sleeper.resumeNext()

        await fulfillment(of: [resumed], timeout: failureBound)
        XCTAssertEqual(center.keyboardModeKind, .normal)
    }

    func testStopEndsPauseAndPausingNeedsARunningCenter() {
        let center = HotkeyCenter()
        XCTAssertFalse(center.performKeyboardModeCommand(.togglePause))

        center.start()
        XCTAssertTrue(center.performKeyboardModeCommand(.togglePause))
        center.stop()

        XCTAssertEqual(center.keyboardModeKind, .normal)
    }

    func testArmingNeedsModeKeysCaptureAndNoBlockingCondition() {
        let center = HotkeyCenter()
        center.start()
        defer { center.stop() }
        XCTAssertFalse(center.performKeyboardModeCommand(.beginPrefix))

        center.updateBindings(
            [
                HotkeyBinding(
                    id: "focus.left",
                    command: .focus(.left),
                    trigger: .unassigned,
                    modeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: 0)
                )
            ],
            systemHyperTrigger: .none
        )
        center.isKeyboardModeArmingBlocked = { true }
        XCTAssertFalse(center.performKeyboardModeCommand(.beginPrefix))
        XCTAssertFalse(center.performKeyboardModeCommand(.toggleWindowMode))

        center.isKeyboardModeArmingBlocked = { false }
        let captureAvailable = center.hyperTriggerTap != nil
        XCTAssertEqual(center.performKeyboardModeCommand(.toggleWindowMode), captureAvailable)
        XCTAssertEqual(center.keyboardModeKind, captureAvailable ? .window : .normal)
        center.performKeyboardModeCommand(.exit)
        XCTAssertEqual(center.keyboardModeKind, .normal)
    }

    func testEnteringPauseCancelsAnActiveWindowSwitcher() throws {
        let center = HotkeyCenter()
        var switcherActions: [WindowSwitcherAction] = []
        center.onWindowSwitcherAction = { action, _ in switcherActions.append(action) }
        center.start()
        defer { center.stop() }
        _ = center.windowSwitcherInput.handle(
            type: .keyDown,
            keyCode: kVK_Tab,
            flags: .maskCommand,
            isRepeat: false,
            canBegin: true
        )
        XCTAssertTrue(center.windowSwitcherInput.isActive)
        switcherActions.removeAll()

        XCTAssertTrue(center.performKeyboardModeCommand(.togglePause))

        XCTAssertFalse(center.windowSwitcherInput.isActive)
        XCTAssertEqual(switcherActions, [.cancel])
    }

    func testModeKeyRoundTripsThroughPersistedRowsAndRebuilds() throws {
        let decoded = try JSONDecoder().decode(
            [PersistedHotkeyBinding].self,
            from: Data(#"[{"id":"focus.left","binding":"Unassigned","modeKey":"H"}]"#.utf8)
        )
        let resolved = try HotkeyBindingRegistry.resolve(decoded)
        let focusLeft = try XCTUnwrap(resolved.first { $0.id == "focus.left" })
        let modeKey = KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: 0)
        XCTAssertEqual(focusLeft.modeKey, modeKey)
        XCTAssertNil(resolved.first { $0.id == "focus.right" }?.modeKey)

        let encoded = try String(decoding: JSONEncoder().encode([focusLeft]), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""modeKey":"H""#), encoded)
        let plain = try XCTUnwrap(resolved.first { $0.id == "focus.right" })
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(plain), as: UTF8.self).contains("modeKey"))

        let retargeted = HotkeyBindingRegistry.retargetingHyperChords(
            [HotkeyBinding(id: "focus.left", command: .focus(.left), trigger: .unassigned, modeKey: modeKey)],
            to: HyperKeyModifiers.default
        )
        XCTAssertEqual(retargeted.first?.modeKey, modeKey)

        let shellRow = HotkeyBinding(
            id: "toggleShellWidget.clock",
            command: .shellToggle("clock"),
            trigger: .unassigned,
            modeKey: modeKey
        )
        XCTAssertEqual(
            HotkeyBindingRegistry.reconcilingShellToggleBindings([shellRow], names: []).map(\.id),
            ["toggleShellWidget.clock"]
        )
    }

    func testKeyboardModeCommandsAreNotBlockedByOverview() {
        XCTAssertFalse(CommandHandler.shouldIgnoreCommand(.keyboardMode(.togglePause), isOverviewOpen: true))
        XCTAssertTrue(CommandHandler.shouldIgnoreCommand(.workspace(.next), isOverviewOpen: true))
        XCTAssertFalse(CommandHandler.shouldIgnoreCommand(.workspace(.next), isOverviewOpen: false))
    }

    func testArmedModesLeaveShortcutsToNormalRouting() {
        let table = KeyboardModeTable(bindings: [
            HotkeyBinding(id: "toggleShortcutPause", command: .keyboardMode(.togglePause), trigger: .chord(leftShiftP)),
            HotkeyBinding(
                id: "focus.left",
                command: .focus(.left),
                trigger: .unassigned,
                modeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: 0)
            )
        ])
        let keyP = UInt32(kVK_ANSI_P)

        var window = KeyboardModeInput(state: .window)
        XCTAssertEqual(
            window.handleKeyDown(keyCode: keyP, rawFlags: leftShiftFlags, isRepeat: false, now: 10, table: table),
            KeyboardModeInput.Decision()
        )
        XCTAssertEqual(window.state, .window)

        var prefix = KeyboardModeInput(state: .prefix(repeatDeadline: nil))
        XCTAssertEqual(
            prefix.handleKeyDown(keyCode: keyP, rawFlags: leftShiftFlags, isRepeat: false, now: 10, table: table),
            KeyboardModeInput.Decision()
        )
        XCTAssertEqual(prefix.state, .normal)
    }

    func testModeKeysThatAreAlsoShortcutsAreRejected() {
        let shiftH = KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(shiftKey))
        let leftShiftJ = KeyBinding(
            keyCode: UInt32(kVK_ANSI_J),
            modifiers: UInt32(shiftKey),
            sidedModifiers: SidedModifiers(left: UInt32(shiftKey))
        )
        let table = KeyboardModeTable(bindings: [
            HotkeyBinding(
                id: "focus.right",
                command: .focus(.right),
                trigger: .chord(shiftH),
                modeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: 0)
            ),
            HotkeyBinding(id: "focus.up", command: .focus(.up), trigger: .chord(leftShiftJ)),
            HotkeyBinding(id: "focus.left", command: .focus(.left), trigger: .unassigned, modeKey: shiftH),
            HotkeyBinding(
                id: "focus.down",
                command: .focus(.down),
                trigger: .unassigned,
                modeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(shiftKey))
            )
        ])

        XCTAssertEqual(table.entries.map(\.command), [.focus(.right)])
        XCTAssertEqual(table.failures, [.focus(.left): .overlapsShortcut, .focus(.down): .overlapsShortcut])
    }

    func testRepeatWindowEndsAtItsExactDeadline() {
        var input = KeyboardModeInput(state: .prefix(repeatDeadline: 10.5))

        XCTAssertEqual(keyDown(&input, keyL, flags: shiftFlag, at: 10.5), KeyboardModeInput.Decision())
        XCTAssertEqual(input.state, .normal)
    }

    func testPauseTimeoutIgnoresValuesOutsideTheDurationRange() {
        XCTAssertEqual(SettingsExport.KeyboardModes(pauseTimeoutSeconds: 5).pauseTimeout, .seconds(5))
        for seconds in [nil, 0, -1, 1e20, .infinity, .nan] as [Double?] {
            XCTAssertNil(
                SettingsExport.KeyboardModes(pauseTimeoutSeconds: seconds).pauseTimeout,
                "\(String(describing: seconds))"
            )
        }
    }

    func testLeadersNeedModeCaptureAndPauseKeepsOnlyItsControls() {
        let leaders: [HotkeyCommand] = [.keyboardMode(.beginPrefix), .keyboardMode(.toggleWindowMode)]
        let controls: [HotkeyCommand] = [.keyboardMode(.togglePause), .keyboardMode(.exit)]
        for command in leaders + controls + [.focus(.left)] {
            XCTAssertTrue(HotkeyCenter.allowsRegistration(of: command, paused: false, captureUnavailable: false))
            XCTAssertEqual(
                HotkeyCenter.allowsRegistration(of: command, paused: false, captureUnavailable: true),
                !leaders.contains(command)
            )
            XCTAssertEqual(
                HotkeyCenter.allowsRegistration(of: command, paused: true, captureUnavailable: false),
                controls.contains(command)
            )
        }
    }

    func testRefreshKeepsConsumedPressesAndTheArmedMode() throws {
        var received: [HotkeyInvocation] = []
        let center = try modeKeyCenter { received.append($0) }
        defer { center.stop() }

        XCTAssertTrue(center.performKeyboardModeCommand(.beginPrefix))
        XCTAssertFalse(passesThrough(center, .keyDown, try keyEvent(keyH, down: true)))
        XCTAssertEqual(received, [HotkeyInvocation(command: .focus(.left))])
        XCTAssertEqual(center.keyboardModeKind, .normal)

        center.updateBindings(center.configuration.bindings, systemHyperTrigger: .none, force: true)
        let repeatEvent = try keyEvent(keyH, down: true, isRepeat: true)
        XCTAssertFalse(passesThrough(center, .keyDown, repeatEvent))
        XCTAssertFalse(passesThrough(center, .keyUp, try keyEvent(keyH, down: false)))
        XCTAssertTrue(passesThrough(center, .keyDown, try keyEvent(keyH, down: true)))
        XCTAssertEqual(received.count, 1)

        XCTAssertTrue(center.performKeyboardModeCommand(.toggleWindowMode))
        center.updateBindings(center.configuration.bindings, systemHyperTrigger: .none, force: true)
        XCTAssertEqual(center.keyboardModeKind, .window)
    }

    func testRemovingTheLastModeKeyKeepsAPressConsumedUntilItsRelease() throws {
        var received: [HotkeyInvocation] = []
        let center = try modeKeyCenter { received.append($0) }
        defer { center.stop() }

        XCTAssertTrue(center.performKeyboardModeCommand(.beginPrefix))
        XCTAssertFalse(passesThrough(center, .keyDown, try keyEvent(keyH, down: true)))
        center.updateBindings(
            [HotkeyBinding(id: "focus.left", command: .focus(.left), trigger: .unassigned)],
            systemHyperTrigger: .none
        )

        XCTAssertFalse(passesThrough(center, .keyDown, try keyEvent(keyH, down: true, isRepeat: true)))
        XCTAssertFalse(passesThrough(center, .keyUp, try keyEvent(keyH, down: false)))
        XCTAssertTrue(passesThrough(center, .keyDown, try keyEvent(keyH, down: true)))
        XCTAssertEqual(received, [HotkeyInvocation(command: .focus(.left))])
    }

    func testEscapeLeavesAModeEvenWhenItIsAlsoAShortcut() {
        let table = KeyboardModeTable(bindings: [
            HotkeyBinding(
                id: "raiseAllFloatingWindows",
                command: .raiseAllFloatingWindows,
                trigger: .chord(KeyBinding(keyCode: keyEscape, modifiers: 0))
            ),
            HotkeyBinding(
                id: "focus.left",
                command: .focus(.left),
                trigger: .unassigned,
                modeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: 0)
            )
        ])

        var window = KeyboardModeInput(state: .window)
        XCTAssertEqual(
            window.handleKeyDown(keyCode: keyEscape, rawFlags: 0, isRepeat: false, now: 10, table: table),
            KeyboardModeInput.Decision(consumed: true)
        )
        XCTAssertEqual(window.state, .normal)

        var modified = KeyboardModeInput(state: .window)
        XCTAssertEqual(
            modified.handleKeyDown(
                keyCode: keyEscape,
                rawFlags: CGEventFlags.maskCommand.rawValue,
                isRepeat: false,
                now: 10,
                table: table
            ),
            KeyboardModeInput.Decision()
        )
        XCTAssertEqual(modified.state, .window)
    }

    func testResetReleasesConsumedPressesAndDisablesAModesOnlyTap() throws {
        let center = try modeKeyCenter()
        defer { center.stop() }
        let tap = try XCTUnwrap(center.hyperTriggerTap)

        XCTAssertTrue(center.performKeyboardModeCommand(.beginPrefix))
        XCTAssertFalse(passesThrough(center, .keyDown, try keyEvent(keyH, down: true)))
        XCTAssertTrue(CGEvent.tapIsEnabled(tap: tap))

        center.resetTransientInputState()

        XCTAssertTrue(center.suppressedHotkeyKeyCodes.isEmpty)
        XCTAssertFalse(CGEvent.tapIsEnabled(tap: tap))
    }

    func testSidedPauseStillWorksWhileAModeIsArmed() throws {
        var kinds: [KeyboardModeKind] = []
        let center = try modeKeyCenter(extraBindings: [
            HotkeyBinding(id: "toggleShortcutPause", command: .keyboardMode(.togglePause), trigger: .chord(leftShiftP))
        ])
        defer { center.stop() }
        center.onKeyboardModeChange = { kinds.append($0) }
        let keyP = UInt32(kVK_ANSI_P)

        for arm in [IPCKeyboardModeCommand.toggleWindowMode, .beginPrefix] {
            XCTAssertTrue(center.performKeyboardModeCommand(arm))
            XCTAssertFalse(passesThrough(center, .keyDown, try keyEvent(keyP, down: true, flags: leftShiftFlags)))
            XCTAssertEqual(center.keyboardModeKind, .paused)
            XCTAssertFalse(passesThrough(center, .keyUp, try keyEvent(keyP, down: false)))
            XCTAssertTrue(center.performKeyboardModeCommand(.togglePause))
        }
        XCTAssertEqual(kinds, [.window, .paused, .normal, .prefix, .normal, .paused, .normal])
    }
}
