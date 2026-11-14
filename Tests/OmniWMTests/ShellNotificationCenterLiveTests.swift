// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    final class ShellNotificationCenterLiveTests: XCTestCase {
        func testBellKeepsNotificationCenterOpen() async throws {
            guard #available(macOS 27.2, *) else {
                throw MissingTestPrerequisite("This test exercises the macOS 27.2 clock click")
            }
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
                throw MissingTestPrerequisite("Opening Notification Center needs Accessibility and event posting")
            }
            let (notificationPID, menuPID) = try XCTUnwrap(ShellNotificationsController.nativeProcesses())
            let session = ShellNotificationAccessibility.Session(notificationPID: notificationPID, menuPID: menuPID)
            NSApplication.shared.setActivationPolicy(.accessory)
            guard try !session.snapshot(includeItems: false).history else {
                throw MissingTestPrerequisite("Start with Notification Center closed and the macOS menu bar visible")
            }
            let clockFrame = try XCTUnwrap(AXAttributeValue.rectValue(try session.copy(session.clock(), "AXFrame")))
            let bar = WorkspaceBarPanel.defaultPanel()
            bar.level = .popUpMenu
            bar.setFrame(ScreenCoordinateSpace.toAppKit(rect: clockFrame), display: false)
            bar.orderFrontRegardless()
            defer { bar.orderOut(nil) }

            try await Task.sleep(for: .milliseconds(150))
            let point = ScreenCoordinateSpace.toAppKit(point: clockFrame.center)
            guard NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == bar.windowNumber else {
                throw MissingTestPrerequisite("The test bar needs to cover the menu bar clock")
            }
            let accessibility = ShellNotificationAccessibility()
            let result = await accessibility.showCenter(notificationPID: notificationPID, menuPID: menuPID)
            defer { restoreClosedHistory(notificationPID: notificationPID, menuPID: menuPID) }
            XCTAssertEqual(result, .dispatched)
            XCTAssertFalse(bar.ignoresMouseEvents)
            try await Task.sleep(for: .milliseconds(650))
            let probe = ShellNotificationAccessibility.Session(notificationPID: notificationPID, menuPID: menuPID)
            XCTAssertTrue(try probe.snapshot(includeItems: false).history)
        }

        private func restoreClosedHistory(notificationPID: pid_t, menuPID: pid_t) {
            let session = ShellNotificationAccessibility.Session(notificationPID: notificationPID, menuPID: menuPID)
            defer { session.stopObserving() }
            try? session.observe()
            try? session.restoreHistory(nil)
        }
    }

#endif
