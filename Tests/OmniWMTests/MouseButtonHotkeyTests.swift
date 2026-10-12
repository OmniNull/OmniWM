// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class MouseButtonHotkeyTests: XCTestCase {
    func testMouseButtonTriggerRoundTripsHumanReadableAndCodable() throws {
        for string in ["MouseButton4", "Option+MouseButton4", "Control+Shift+MouseButton31"] {
            let trigger = try XCTUnwrap(HotkeyTrigger.fromHumanReadable(string))
            XCTAssertEqual(trigger.humanReadableString, string)
            let data = try JSONEncoder().encode(trigger)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(string)\"")
            XCTAssertEqual(try JSONDecoder().decode(HotkeyTrigger.self, from: data), trigger)
        }
        XCTAssertEqual(HotkeyTrigger.fromHumanReadable("Mouse Button 4"), try mouseTrigger(4))
        XCTAssertEqual(try mouseTrigger(3, optionKey).displayString, "⌥Mouse 3")
        XCTAssertEqual(HotkeySettingsDisplayModel.displayString(for: try mouseTrigger(3, optionKey)), "⌥Mouse 3")
        XCTAssertEqual(
            HotkeyTrigger.fromHumanReadable("Option+H"),
            .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(optionKey)))
        )
    }

    func testMouseButtonTriggerRejectsUnsupportedButtonsAndModifiers() {
        for string in [
            "MouseButton0", "MouseButton1", "MouseButton32", "MouseButton", "MouseButtonX",
            "Left Option+MouseButton4", "Foo+MouseButton4", "+MouseButton4"
        ] {
            XCTAssertNil(HotkeyTrigger.fromHumanReadable(string), string)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(HotkeyTrigger.self, from: Data(#""MouseButton1""#.utf8)))
    }

    func testMouseButtonConflictsRequireSameButtonAndModifiers() throws {
        let back = try mouseTrigger(3)

        XCTAssertTrue(back.conflicts(with: try mouseTrigger(3)))
        XCTAssertFalse(back.conflicts(with: try mouseTrigger(3, optionKey)))
        XCTAssertFalse(back.conflicts(with: try mouseTrigger(4)))
        XCTAssertFalse(back.conflicts(with: .chord(KeyBinding(keyCode: UInt32(kVK_ANSI_3), modifiers: 0))))
        XCTAssertFalse(back.conflicts(with: .unassigned))
    }

    func testRegistrationPlanRoutesMouseBindingsAndMarksDuplicates() throws {
        let bindings = [
            HotkeyBinding(id: "switchWorkspace.previous", command: .workspace(.previous), trigger: try mouseTrigger(3)),
            HotkeyBinding(id: "switchWorkspace.next", command: .workspace(.next), trigger: try mouseTrigger(4)),
            HotkeyBinding(id: "workspaceBackAndForth", command: .workspace(.backAndForth), trigger: try mouseTrigger(4))
        ]

        let plan = HotkeyCenter.registrationPlan(for: bindings)

        XCTAssertEqual(plan.mouseButtonRegistrations, [try mouseBinding(3): .workspace(.previous)])
        XCTAssertEqual(plan.failures[.workspace(.next)], .duplicateBinding)
        XCTAssertEqual(plan.failures[.workspace(.backAndForth)], .duplicateBinding)
        XCTAssertTrue(plan.registrations.isEmpty)
        XCTAssertTrue(plan.sideSpecificRegistrations.isEmpty)
        XCTAssertEqual(HotkeyCenter.bindingFacts(for: [bindings[0]]).map(\.route), ["mouse"])
    }

    func testHyperMouseBindingFollowsHyperComposition() throws {
        defer { KeySymbolMapper.setHyperKeyModifiers(.default) }
        let hyperBound = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(
            id: "switchWorkspace.next",
            trigger: try mouseTrigger(4, Int(KeySymbolMapper.hyperModifiers))
        ))
        XCTAssertEqual(hyperBound.binding.humanReadableString, "Hyper+MouseButton4")

        let threeModifiers = try XCTUnwrap(HyperKeyModifiers.fromHumanReadable("Control+Option+Command"))
        let retargeted = HotkeyBindingRegistry.retargetingHyperChords([hyperBound], to: threeModifiers)

        XCTAssertEqual(retargeted[0].binding, try mouseTrigger(4, controlKey | optionKey | cmdKey))
    }

    func testRecorderResolverAppliesHyperAndRejectsUnsupportedButtons() throws {
        XCTAssertEqual(
            KeyRecorderBindingResolver.mouseBinding(button: 3, modifiers: 0, hyperActive: false),
            try mouseBinding(3)
        )
        XCTAssertEqual(
            KeyRecorderBindingResolver.mouseBinding(button: 4, modifiers: UInt32(optionKey), hyperActive: true),
            try mouseBinding(4, Int(UInt32(optionKey) | KeySymbolMapper.hyperModifiers))
        )
        XCTAssertNil(KeyRecorderBindingResolver.mouseBinding(button: 1, modifiers: 0, hyperActive: false))
        XCTAssertNil(KeyRecorderBindingResolver.mouseBinding(button: 32, modifiers: 0, hyperActive: false))
    }

    func testRecorderCapturesOtherMouseButtonPress() throws {
        let recorder = KeyRecorderNSView()
        var captured: HotkeyTrigger?
        recorder.onCapture = { captured = $0 }
        let cgEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ))
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        cgEvent.flags = .maskAlternate

        recorder.otherMouseDown(with: try XCTUnwrap(NSEvent(cgEvent: cgEvent)))

        XCTAssertEqual(captured, try mouseTrigger(3, optionKey))
    }

    func testHotkeyCenterDispatchesExactMatchOnlyWhileRunningAndNotSuspended() throws {
        let center = HotkeyCenter()
        var received: [HotkeyInvocation] = []
        center.onCommand = { received.append($0) }
        center.updateBindings(
            [
                HotkeyBinding(
                    id: "switchWorkspace.previous",
                    command: .workspace(.previous),
                    trigger: try mouseTrigger(3)
                ),
                HotkeyBinding(
                    id: "switchWorkspace.next",
                    command: .workspace(.next),
                    trigger: try mouseTrigger(4, optionKey)
                )
            ],
            systemHyperTrigger: .none
        )
        XCTAssertFalse(center.dispatchMouseButton(3, flags: []))

        center.start()
        defer { center.stop() }
        XCTAssertTrue(center.dispatchMouseButton(3, flags: []))
        XCTAssertFalse(center.dispatchMouseButton(3, flags: .maskAlternate))
        XCTAssertFalse(center.dispatchMouseButton(4, flags: []))
        XCTAssertTrue(center.dispatchMouseButton(4, flags: [.maskAlternate, .maskAlphaShift]))
        XCTAssertEqual(received, [
            HotkeyInvocation(command: .workspace(.previous)),
            HotkeyInvocation(command: .workspace(.next))
        ])

        center.setCommandHotkeysSuspended(true)
        XCTAssertFalse(center.dispatchMouseButton(3, flags: []))
        center.setCommandHotkeysSuspended(false)
        XCTAssertTrue(center.dispatchMouseButton(3, flags: []))
        center.stop()
        XCTAssertFalse(center.dispatchMouseButton(3, flags: []))
        XCTAssertEqual(received.count, 3)
    }

    func testHyperMouseBindingMatchesHeldHyperAndKeepsCapsLockUntoggled() throws {
        let center = HotkeyCenter()
        center.onCommand = { _ in }
        center.updateBindings(
            [HotkeyBinding(
                id: "switchWorkspace.next",
                command: .workspace(.next),
                trigger: try mouseTrigger(4, Int(KeySymbolMapper.hyperModifiers))
            )],
            systemHyperTrigger: .none
        )
        center.start()
        defer { center.stop() }
        center.hyperTrigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_CapsLock)), capsLockRemapped: true)
        XCTAssertFalse(center.dispatchMouseButton(4, flags: []))

        XCTAssertEqual(center.hyperTrigger.handleKeyDown(CapsLockHyperMapping.f18KeyCode, timestamp: 1.0), .suppress)
        XCTAssertTrue(center.dispatchMouseButton(4, flags: []))
        XCTAssertEqual(center.hyperTrigger.handleKeyUp(CapsLockHyperMapping.f18KeyCode, timestamp: 1.1), .suppress)
    }

    func testTapRoutingDispatchesOnceAndConsumesDragAndRelease() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        var received: [HotkeyCommand] = []
        controller.hotkeys.onCommand = { received.append($0.command) }
        try startHotkeys(controller, [HotkeyBinding(
            id: "switchWorkspace.previous",
            command: .workspace(.previous),
            trigger: try mouseTrigger(3)
        )])
        defer { controller.hotkeys.stop() }

        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 3))
        XCTAssertEqual(handler.state.capturedOtherMouseButton, 3)
        XCTAssertEqual(controller.hotkeys.isMouseButtonCaptured?(3), true)
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseDragged, button: 3))
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseUp, button: 3))
        XCTAssertNil(handler.state.capturedOtherMouseButton)
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 4))
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 3, modifiers: .maskAlternate))
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseUp, button: 3))
        XCTAssertEqual(received, [.workspace(.previous)])

        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 3))
        handler.pressedMouseButtonsProvider = { 0 }
        handler.recoverAfterTapDisable()
        XCTAssertNil(handler.state.capturedOtherMouseButton)
    }

    func testIneligibleStatesPassBoundButtonThrough() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        var received: [HotkeyCommand] = []
        controller.hotkeys.onCommand = { received.append($0.command) }
        try startHotkeys(controller, [HotkeyBinding(
            id: "switchWorkspace.previous",
            command: .workspace(.previous),
            trigger: try mouseTrigger(3)
        )])
        defer { controller.hotkeys.stop() }

        controller.isLockScreenActive = true
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 3))
        controller.isLockScreenActive = false
        controller.isEnabled = false
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 3))
        controller.isEnabled = true
        handler.state.isMoving = true
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 3))
        handler.state.isMoving = false
        handler.state.capturedInteractionButton = .right
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 3))
        handler.state.capturedInteractionButton = nil
        controller.setHotkeyRecordingActive(true)
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 3))
        controller.setHotkeyRecordingActive(false)
        controller.hotkeys.stop()
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 3))
        XCTAssertNil(handler.state.capturedOtherMouseButton)
        XCTAssertTrue(received.isEmpty)
    }

    func testOverviewButtonKeepsRuntimePrecedence() throws {
        let controller = makeController()
        defer { controller.windowActionHandler.invalidateOverviewDeferredActionsForServiceStop() }
        let handler = controller.mouseEventHandler
        var received: [HotkeyCommand] = []
        controller.hotkeys.onCommand = { received.append($0.command) }
        try startHotkeys(controller, [HotkeyBinding(
            id: "switchWorkspace.previous",
            command: .workspace(.previous),
            trigger: try mouseTrigger(3)
        )])
        defer { controller.hotkeys.stop() }
        controller.settings.overview.mouseButton = 3

        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 3))
        XCTAssertTrue(controller.windowActionHandler.isOverviewOpen())
        XCTAssertTrue(received.isEmpty)
    }

    func testExclusivityRejectsSharedMouseButtonsAtSettersAndCapture() throws {
        let controller = makeController()
        let settings = controller.settings
        settings.updateTrigger(for: "switchWorkspace.previous", newTrigger: try mouseTrigger(3, optionKey))

        XCTAssertThrowsError(try settings.setOverviewMouseButton(3))
        XCTAssertThrowsError(try settings.setSystemHyperTrigger(.mouseButton(3)))
        try settings.setOverviewMouseButton(4)
        try settings.setSystemHyperTrigger(.mouseButton(5))
        XCTAssertThrowsError(try settings.validateHotkeyTrigger(try mouseTrigger(4, optionKey)))
        XCTAssertThrowsError(try settings.validateHotkeyTrigger(try mouseTrigger(5)))
        XCTAssertNoThrow(try settings.validateHotkeyTrigger(try mouseTrigger(6)))

        settings.updateTrigger(for: "switchWorkspace.next", newTrigger: try mouseTrigger(4))
        guard case .rejected = HotkeyBindingEditor.capture(
            try mouseTrigger(4),
            for: "workspaceBackAndForth",
            settings: settings
        ) else {
            return XCTFail("A button owned by Overview must be rejected before the Replace flow")
        }
        XCTAssertEqual(settings.hotkeyBindings.first { $0.id == "switchWorkspace.next" }?.binding, try mouseTrigger(4))
    }

    func testExternalReloadRejectsHotkeyMouseButtonSharedWithOverview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false)
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.flushNow()
        let valid = settings.toExport()
        var candidate = valid
        let index = try XCTUnwrap(candidate.hotkeyBindings.firstIndex { $0.id == "switchWorkspace.previous" })
        candidate.hotkeyBindings[index].binding = try mouseTrigger(3)
        candidate.overview.mouseButton = 3
        try SettingsTOMLCodec.encode(candidate).write(to: persistence.fileURL, options: .atomic)

        persistence.handlePossibleSettingsFileChange()

        XCTAssertEqual(settings.toExport(), valid)
        XCTAssertNotNil(settings.configNotice)

        candidate.overview.mouseButton = nil
        try SettingsTOMLCodec.encode(candidate).write(to: persistence.fileURL, options: .atomic)
        persistence.handlePossibleSettingsFileChange()

        XCTAssertNil(settings.configNotice)
        XCTAssertEqual(
            settings.hotkeyBindings.first { $0.id == "switchWorkspace.previous" }?.binding,
            try mouseTrigger(3)
        )
    }

    private func mouseBinding(_ button: Int64, _ modifiers: Int = 0) throws -> MouseButtonBinding {
        try XCTUnwrap(MouseButtonBinding(button: button, modifiers: UInt32(modifiers)))
    }

    private func mouseTrigger(_ button: Int64, _ modifiers: Int = 0) throws -> HotkeyTrigger {
        .mouseButton(try mouseBinding(button, modifiers))
    }

    private func startHotkeys(_ controller: WMController, _ bindings: [HotkeyBinding]) throws {
        controller.hotkeys.updateBindings(bindings, systemHyperTrigger: .none)
        controller.hotkeys.start()
    }

    private func makeController() -> WMController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        settings.animationsEnabled = false
        return WMController(settings: settings)
    }
}
