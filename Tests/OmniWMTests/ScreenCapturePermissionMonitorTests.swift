// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import ScreenCaptureKit
import XCTest

@MainActor
final class ScreenCapturePermissionMonitorTests: XCTestCase {
    private final class Preflight {
        var calls = 0
        var granted = true
    }

    private func makeMonitor(_ preflight: Preflight) -> ScreenCapturePermissionMonitor {
        ScreenCapturePermissionMonitor(
            preflight: {
                preflight.calls += 1
                return preflight.granted
            },
            notificationCenter: NotificationCenter()
        )
    }

    func testReadsReuseOnePreflightUntilRefresh() {
        let preflight = Preflight()
        let monitor = makeMonitor(preflight)

        for _ in 0 ..< 100 {
            XCTAssertTrue(monitor.isGranted)
        }
        XCTAssertEqual(preflight.calls, 1)

        preflight.granted = false
        XCTAssertTrue(monitor.isGranted)
        XCTAssertFalse(monitor.refresh())
        XCTAssertFalse(monitor.isGranted)
        XCTAssertEqual(preflight.calls, 2)
    }

    func testOnlyLeavingSystemSettingsRefreshes() {
        let preflight = Preflight()
        let monitor = makeMonitor(preflight)
        XCTAssertTrue(monitor.isGranted)

        preflight.granted = false
        monitor.applicationDidDeactivate(bundleIdentifier: "com.apple.Safari")
        monitor.applicationDidDeactivate(bundleIdentifier: nil)
        XCTAssertTrue(monitor.isGranted)
        XCTAssertEqual(preflight.calls, 1)

        monitor.applicationDidDeactivate(bundleIdentifier: "com.apple.systempreferences")
        XCTAssertFalse(monitor.isGranted)
        XCTAssertEqual(preflight.calls, 2)
    }

    func testOnlyDeclinedCaptureErrorsRevokeCachedPermission() {
        let preflight = Preflight()
        let monitor = makeMonitor(preflight)
        XCTAssertTrue(monitor.isGranted)

        monitor.noteCaptureFailure(SCStreamError(.failedToStart))
        monitor.noteCaptureFailure(CancellationError())
        XCTAssertTrue(monitor.isGranted)

        monitor.noteCaptureFailure(SCStreamError(.userDeclined))
        XCTAssertFalse(monitor.isGranted)
        XCTAssertEqual(preflight.calls, 1)
    }

    func testInteractivePreviewReconcilesReuseCachedPermission() async {
        let preflight = Preflight()
        let monitor = makeMonitor(preflight)
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(hasCaptureAccess: { monitor.isGranted })
        let handle = WindowHandle(id: WindowToken(pid: 123, windowId: 456))
        let request = OverviewPreviewRequest(handle: handle, pixelWidth: 80, pixelHeight: 60)

        for _ in 0 ..< 60 {
            capture.reconcile(represented: [handle], visible: [request])
        }
        await driver.waitForStarts(1)

        XCTAssertEqual(driver.streams.count, 1)
        XCTAssertEqual(preflight.calls, 1)
        driver.completeAllStarts()
        capture.clear()
    }
}
