// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class OverviewMouseButtonTests: XCTestCase {
    func testPressTogglesOnceAndConsumesDragAndReleaseAcrossReassignment() throws {
        let controller = makeController()
        defer { controller.windowActionHandler.invalidateOverviewDeferredActionsForServiceStop() }
        let handler = controller.mouseEventHandler
        try controller.settings.setOverviewMouseButton(2)
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2))
        XCTAssertTrue(controller.windowActionHandler.isOverviewOpen())
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2))
        XCTAssertTrue(controller.windowActionHandler.isOverviewOpen())
        try controller.settings.setOverviewMouseButton(4)
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseDragged, button: 2))
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseUp, button: 4))
        XCTAssertEqual(handler.state.capturedOtherMouseButton, 2)
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseUp, button: 2))
        XCTAssertNil(handler.state.capturedOtherMouseButton)
        XCTAssertTrue(controller.windowActionHandler.isOverviewOpen())
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 4))
        XCTAssertFalse(controller.windowActionHandler.isOverviewOpen())
        try controller.settings.setOverviewMouseButton(nil)
        controller.isEnabled = false
        controller.isLockScreenActive = true
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseUp, button: 4))
        XCTAssertNil(handler.state.capturedOtherMouseButton)
    }

    func testUnassignedDisabledLockedAndOwnedInputDoNotActivateOverview() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2))
        try controller.settings.setOverviewMouseButton(2)
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 3))
        controller.isEnabled = false
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2))
        controller.isEnabled = true
        controller.isLockScreenActive = true
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2))
        controller.isLockScreenActive = false
        handler.state.capturedInteractionButton = .right
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2))
        handler.state.capturedInteractionButton = nil
        handler.state.gesturePhase = .armed
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2))
        handler.state.gesturePhase = .idle
        handler.state.isMoving = true
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2))
        handler.state.isMoving = false
        XCTAssertFalse(controller.windowActionHandler.isOverviewOpen())
        XCTAssertNil(handler.state.capturedOtherMouseButton)
    }

    func testDisablingOverviewPassesNewPressAndConsumesCapturedRelease() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        try controller.settings.setOverviewMouseButton(2)
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2))
        XCTAssertTrue(controller.isOverviewOpen())

        controller.setOverviewEnabled(false)

        XCTAssertFalse(controller.isOverviewOpen())
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseUp, button: 2))
        XCTAssertFalse(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2))
        XCTAssertNil(handler.state.capturedOtherMouseButton)
        controller.setOverviewEnabled(true)
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2))
        XCTAssertTrue(controller.isOverviewOpen())
        controller.windowActionHandler.invalidateOverviewDeferredActionsForServiceStop()
    }

    func testDisabledPresentationCommandsDoNotRegisterBindingsOrOpenOverview() {
        let controller = makeController()
        let savedBindings = controller.settings.hotkeyBindings
        controller.updateHotkeyBindings(savedBindings)
        let originalCount = controller.hotkeys.hotkeyHealthFacts().bindingCount

        controller.setOverviewEnabled(false)
        controller.settings.quakeTerminal.enabled = false
        controller.setQuakeTerminalEnabled(false)

        XCTAssertEqual(controller.hotkeys.hotkeyHealthFacts().bindingCount, originalCount - 2)
        XCTAssertEqual(controller.commandHandler.performCommand(.presentation(.overview)), .ignoredDisabled)
        XCTAssertEqual(controller.commandHandler.performCommand(.presentation(.quakeTerminal)), .ignoredDisabled)
        controller.windowActionHandler.toggleOverview()
        XCTAssertFalse(controller.isOverviewOpen())
        XCTAssertEqual(controller.settings.hotkeyBindings, savedBindings)

        controller.setOverviewEnabled(true)
        XCTAssertEqual(controller.hotkeys.hotkeyHealthFacts().bindingCount, originalCount - 1)
    }

    func testHyperRoutingYieldsCapturedOverviewSequenceAcrossReassignment() throws {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        try controller.settings.setOverviewMouseButton(4)
        handler.state.capturedOtherMouseButton = 4
        try controller.settings.setOverviewMouseButton(3)
        try controller.settings.setSystemHyperTrigger(.mouseButton(4))
        XCTAssertEqual(controller.hotkeys.isMouseButtonCaptured?(4), true)
        XCTAssertEqual(controller.hotkeys.isMouseButtonCaptured?(3), false)
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 4))
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseUp, button: 4))
        XCTAssertEqual(controller.hotkeys.isMouseButtonCaptured?(4), false)
        try controller.settings.setSystemHyperTrigger(.none)
        try controller.settings.setOverviewMouseButton(4)
        XCTAssertTrue(handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 4))
        XCTAssertTrue(controller.windowActionHandler.isOverviewOpen())
        controller.windowActionHandler.invalidateOverviewDeferredActionsForServiceStop()
    }

    func testRecoveryPreservesHeldCaptureAndReleasesStaleCaptureAndCleanup() {
        let controller = makeController()
        let handler = controller.mouseEventHandler
        for button: Int64 in 2 ... 5 {
            handler.state.capturedOtherMouseButton = button
            handler.pressedMouseButtonsProvider = { 1 << Int(button) }
            handler.recoverAfterTapDisable()
            XCTAssertEqual(handler.state.capturedOtherMouseButton, button)
            handler.pressedMouseButtonsProvider = { 0 }
            handler.recoverAfterTapDisable()
            XCTAssertNil(handler.state.capturedOtherMouseButton)
        }
        handler.state.capturedOtherMouseButton = 3
        handler.cleanup()
        XCTAssertNil(handler.state.capturedOtherMouseButton)
    }

    func testConflictsRejectEitherUIAssignmentAndRuntimeDefersToHyper() throws {
        let controller = makeController()
        let settings = controller.settings
        try settings.setSystemHyperTrigger(.mouseButton(3))
        XCTAssertThrowsError(try settings.setOverviewMouseButton(3))
        XCTAssertNil(settings.overview.mouseButton)
        try settings.setOverviewMouseButton(4)
        XCTAssertThrowsError(try settings.setSystemHyperTrigger(.mouseButton(4)))
        XCTAssertEqual(settings.systemHyperTrigger, .mouseButton(3))
        for unsupported: Int64 in [-1, 0, 1, 6] {
            XCTAssertThrowsError(try settings.setOverviewMouseButton(unsupported))
            XCTAssertEqual(settings.overview.mouseButton, 4)
        }
        settings.overview.mouseButton = 3
        XCTAssertFalse(controller.mouseEventHandler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 3))
        XCTAssertNil(controller.mouseEventHandler.state.capturedOtherMouseButton)
    }

    func testConflictingExternalReloadRetainsValidConfigurationAndReportsError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false)
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        try settings.setOverviewMouseButton(2)
        settings.flushNow()
        let valid = settings.toExport()
        var candidate = valid
        candidate.overview.mouseButton = 3
        candidate.systemHyperTrigger = .mouseButton(3)
        let rejected = try SettingsTOMLCodec.encode(candidate)
        try rejected.write(to: persistence.fileURL, options: .atomic)
        persistence.handlePossibleSettingsFileChange()
        XCTAssertEqual(settings.toExport(), valid)
        XCTAssertNotNil(settings.configNotice)
        XCTAssertEqual(try Data(contentsOf: persistence.fileURL), rejected)
        XCTAssertNil(persistence.loadOutcome().export)
        candidate.overview.mouseButton = 4
        candidate.overview.invertScrollDirection = true
        candidate.overview.mouseScrollSpeed = 1.75
        try SettingsTOMLCodec.encode(candidate).write(to: persistence.fileURL, options: .atomic)
        persistence.handlePossibleSettingsFileChange()
        XCTAssertNil(settings.configNotice)
        XCTAssertEqual(settings.overview.mouseButton, 4)
        XCTAssertTrue(settings.overview.invertScrollDirection)
        XCTAssertEqual(settings.overview.mouseScrollSpeed, 1.75)
        XCTAssertEqual(settings.systemHyperTrigger, .mouseButton(3))
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
