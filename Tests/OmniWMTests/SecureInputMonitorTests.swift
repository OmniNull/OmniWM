// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class SecureInputMonitorTests: XCTestCase {
    private final class Recorder {
        var calls: [String] = []
        var failingRegistrations: Set<CGSEventType> = []
        var sessions: [UInt32] = []
        var unregisteredSessions: [UInt32] = []
        var isSecure = false
        var changes: [Bool] = []
    }

    private var monitorsToStop: [SecureInputMonitor] = []
    private var controllersToStop: [WMController] = []

    override func tearDown() async throws {
        for monitor in monitorsToStop {
            monitor.stop()
        }
        for controller in controllersToStop {
            controller.hotkeys.stop()
        }
        monitorsToStop = []
        controllersToStop = []
        SecureInputIndicatorController.shared.hide()
        try await super.tearDown()
    }

    func testStartSubscribesBeforeReadingInitialState() {
        let recorder = Recorder()
        let monitor = makeMonitor(recorder)

        monitor.start { recorder.changes.append($0) }

        XCTAssertEqual(recorder.calls, ["register 752", "register 753", "read"])
        XCTAssertTrue(monitor.isSubscribed)
        XCTAssertEqual(recorder.changes, [])
        XCTAssertFalse(monitor.isSecureInputActive)
    }

    func testStartPublishesSecureInputThatIsAlreadyOn() {
        let recorder = Recorder()
        recorder.isSecure = true
        let monitor = makeMonitor(recorder)

        monitor.start { recorder.changes.append($0) }

        XCTAssertEqual(recorder.changes, [true])
        XCTAssertTrue(monitor.isSecureInputActive)
    }

    func testRefreshPublishesOnlyStateChanges() {
        let recorder = Recorder()
        let monitor = makeMonitor(recorder)
        monitor.start { recorder.changes.append($0) }

        recorder.isSecure = true
        monitor.refresh()
        monitor.refresh()
        recorder.isSecure = false
        monitor.refresh()
        monitor.refresh()

        XCTAssertEqual(recorder.changes, [true, false])
    }

    func testRestartDuringSecureInputPublishesItAgain() {
        let recorder = Recorder()
        recorder.isSecure = true
        let monitor = makeMonitor(recorder)
        monitor.start { recorder.changes.append($0) }

        monitor.stop()
        XCTAssertFalse(monitor.isSecureInputActive)
        monitor.start { recorder.changes.append($0) }

        XCTAssertEqual(recorder.changes, [true, true])
        XCTAssertTrue(monitor.isSecureInputActive)
    }

    func testStopUnregistersBothNotificationsAndRefreshNoLongerPublishes() {
        let recorder = Recorder()
        let monitor = makeMonitor(recorder)
        monitor.start { recorder.changes.append($0) }
        recorder.calls.removeAll()

        monitor.stop()
        recorder.isSecure = true
        monitor.refresh()

        XCTAssertEqual(recorder.calls, ["unregister 752", "unregister 753"])
        XCTAssertEqual(recorder.unregisteredSessions, recorder.sessions)
        XCTAssertFalse(monitor.isSubscribed)
        XCTAssertEqual(recorder.changes, [])
        XCTAssertFalse(monitor.isSecureInputActive)
    }

    func testPartialRegistrationFailureRollsBackAndStillReadsInitialState() {
        let recorder = Recorder()
        recorder.failingRegistrations = [.secureEventInputStopped]
        recorder.isSecure = true
        let monitor = makeMonitor(recorder)

        monitor.start { recorder.changes.append($0) }

        XCTAssertEqual(recorder.calls, ["register 752", "register 753", "unregister 752", "read"])
        XCTAssertFalse(monitor.isSubscribed)
        XCTAssertEqual(recorder.changes, [true])

        recorder.calls.removeAll()
        monitor.stop()
        XCTAssertEqual(recorder.calls, [])
    }

    func testNotificationsFromStoppedOrEarlierSessionsAreRejected() throws {
        let recorder = Recorder()
        let monitor = makeMonitor(recorder)
        monitor.start { recorder.changes.append($0) }
        let firstSession = try XCTUnwrap(recorder.sessions.last)

        XCTAssertTrue(monitor.recordNotification(session: firstSession))
        monitor.stop()
        XCTAssertFalse(monitor.recordNotification(session: firstSession))

        monitor.start { recorder.changes.append($0) }
        let secondSession = try XCTUnwrap(recorder.sessions.last)
        XCTAssertNotEqual(firstSession, secondSession)
        XCTAssertFalse(monitor.recordNotification(session: firstSession))
        XCTAssertTrue(monitor.recordNotification(session: secondSession))
        XCTAssertEqual(monitor.notificationCount, 2)
    }

    func testCurrentSessionNotificationResetsHeldHyperEvenWhenStateIsUnchanged() throws {
        let controller = makeController()
        let recorder = Recorder()
        let monitor = configure(controller.secureInputMonitor, recorder)
        monitor.start { recorder.changes.append($0) }
        let session = try XCTUnwrap(recorder.sessions.last)
        holdHyperTrigger(controller.hotkeys)

        deliverNotification(session: session, to: controller)

        XCTAssertFalse(controller.hotkeys.isHyperTriggerActive)
        XCTAssertEqual(recorder.changes, [])
        XCTAssertEqual(monitor.notificationCount, 1)
    }

    func testNotificationRefreshesStateAfterResettingHyper() throws {
        let controller = makeController()
        let recorder = Recorder()
        let monitor = configure(controller.secureInputMonitor, recorder)
        monitor.start { recorder.changes.append($0) }
        let session = try XCTUnwrap(recorder.sessions.last)
        holdHyperTrigger(controller.hotkeys)

        recorder.isSecure = true
        deliverNotification(session: session, to: controller)

        XCTAssertFalse(controller.hotkeys.isHyperTriggerActive)
        XCTAssertEqual(recorder.changes, [true])
    }

    func testStaleSessionNotificationLeavesHotkeysAndStateUntouched() throws {
        let controller = makeController()
        let recorder = Recorder()
        let monitor = configure(controller.secureInputMonitor, recorder)
        monitor.start { recorder.changes.append($0) }
        let staleSession = try XCTUnwrap(recorder.sessions.last)
        monitor.stop()
        monitor.start { recorder.changes.append($0) }
        holdHyperTrigger(controller.hotkeys)

        recorder.isSecure = true
        deliverNotification(session: staleSession, to: controller)

        XCTAssertTrue(controller.hotkeys.isHyperTriggerActive)
        XCTAssertEqual(recorder.changes, [])
        XCTAssertEqual(monitor.notificationCount, 0)
    }

    func testSecureInputKeepsRunningHotkeysRegistered() {
        let controller = makeController()
        controllersToStop.append(controller)
        controller.hotkeys.updateBindings([], force: true)
        controller.hasStartedServices = true
        controller.updateAccessibilityPermissionGranted(true)
        XCTAssertTrue(controller.hotkeys.hotkeyHealthFacts().isRunning)

        let recorder = Recorder()
        recorder.isSecure = true
        configure(controller.secureInputMonitor, recorder)
        controller.serviceLifecycleManager.startSecureInputMonitor()

        XCTAssertTrue(controller.secureInputMonitor.isSecureInputActive)
        XCTAssertTrue(controller.hotkeysEnabled)
        XCTAssertTrue(controller.hotkeys.hotkeyHealthFacts().isRunning)

        controller.setHotkeysEnabled(false)
        XCTAssertFalse(controller.hotkeys.hotkeyHealthFacts().isRunning)
    }

    private func makeMonitor(_ recorder: Recorder) -> SecureInputMonitor {
        configure(SecureInputMonitor(), recorder)
    }

    @discardableResult
    private func configure(_ monitor: SecureInputMonitor, _ recorder: Recorder) -> SecureInputMonitor {
        monitor.secureInputStateProviderForTests = {
            recorder.calls.append("read")
            return recorder.isSecure
        }
        monitor.registerNotification = { event, session in
            recorder.calls.append("register \(event.rawValue)")
            recorder.sessions.append(session)
            return !recorder.failingRegistrations.contains(event)
        }
        monitor.unregisterNotification = { event, session in
            recorder.calls.append("unregister \(event.rawValue)")
            recorder.unregisteredSessions.append(session)
            return true
        }
        monitorsToStop.append(monitor)
        return monitor
    }

    private func holdHyperTrigger(_ hotkeys: HotkeyCenter) {
        hotkeys.hyperTrigger = HyperTriggerStateMachine(trigger: .key(UInt32(kVK_F19)), capsLockRemapped: false)
        _ = hotkeys.hyperTrigger.handleKeyDown(UInt32(kVK_F19))
        XCTAssertTrue(hotkeys.isHyperTriggerActive)
    }

    private func deliverNotification(session: UInt32, to controller: WMController) {
        controller.eventInterpreter.handleIntakeEvent(
            StampedIntakeEvent(seq: 1, event: .secureInputStateMayHaveChanged(session: session))
        )
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSecureInputMonitorTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        return WMController(settings: settings)
    }
}
