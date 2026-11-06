// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import Synchronization
import XCTest

private final class InvalidPIDApplication: NSRunningApplication, @unchecked Sendable {
    override var processIdentifier: pid_t {
        -1
    }

    override var activationPolicy: NSApplication.ActivationPolicy {
        .regular
    }

    override var isTerminated: Bool {
        false
    }

    override var bundleIdentifier: String? {
        "test.invalid-pid"
    }

    override var localizedName: String? {
        "Invalid PID"
    }
}

@MainActor
final class AppAXContextIdentityTests: XCTestCase {
    func testManagedContextPreservesWindowPIDDespiteInvalidApplicationPID() async throws {
        let manager = AXManager()
        defer { manager.cleanup() }
        let app = InvalidPIDApplication()
        let pid: pid_t = 999_700
        let ensured = await manager.ensureContext(for: app, pid: pid)
        XCTAssertTrue(ensured)
        let context = try XCTUnwrap(AppAXContextRegistry.contexts[pid])
        defer { context.destroy() }
        XCTAssertEqual(context.pid, pid)
        XCTAssertEqual(context.writeMetricsToken.pid, pid)
        XCTAssertEqual(context.nsApp.processIdentifier, -1)
        XCTAssertNil(AppAXContextRegistry.contexts[-1])

        let reused = try await AppAXContextRegistry.getOrCreate(app, pid: pid)
        XCTAssertTrue(reused === context)
        let thread = try XCTUnwrap(context.axThread)
        let enumeration = context.makeWindowEnumerationOperation(
            inspectionContext: .unidentified,
            includedWindowIds: nil,
            deadline: ProcessInfo.processInfo.systemUptime
        )
        let workerPID = Mutex<pid_t?>(nil)
        let workerObserved = expectation(description: "Worker identity observed")
        thread.runInLoopAsync { _ in
            workerPID.withLock { $0 = appThreadToken?.pid }
            var applicationPID: pid_t = 0
            XCTAssertEqual(AXUIElementGetPid(enumeration.axApp.value, &applicationPID), .success)
            XCTAssertEqual(applicationPID, pid)
            workerObserved.fulfill()
        }
        await fulfillment(of: [workerObserved], timeout: failureBound)
        XCTAssertEqual(workerPID.withLock { $0 }, pid)

        let window = AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 999_701)
        let completed = expectation(description: "Frame reaches the window owner")
        manager.onFrameApplyTerminated = { result in
            XCTAssertEqual(result.pid, pid)
            XCTAssertEqual(result.windowId, window.windowId)
            XCTAssertEqual(result.writeResult.failureReason, .staleElement)
            completed.fulfill()
        }
        manager.applyFramesParallel([
            AXFrameApplicationTarget(
                pid: pid,
                window: window,
                frame: CGRect(x: 10, y: 20, width: 640, height: 480)
            )
        ])
        await fulfillment(of: [completed], timeout: failureBound)
    }

    func testInvalidDiscoveryPIDCannotCreateContext() async throws {
        let manager = AXManager()
        defer { manager.cleanup() }
        let app = InvalidPIDApplication()
        for pid: pid_t in [-1, 0] {
            let context = try await AppAXContextRegistry.getOrCreate(app, pid: pid)
            XCTAssertNil(context)
            let ensured = await manager.ensureContext(for: app, pid: pid)
            XCTAssertFalse(ensured)
            XCTAssertNil(AppAXContextRegistry.contexts[pid])
        }
        let windows = await manager.windowsForApp(app)
        XCTAssertTrue(windows.isEmpty)
    }

    func testRescanTargetsAndWorkersPreserveKnownPID() async throws {
        let manager = AXManager()
        defer { manager.cleanup() }
        let app = InvalidPIDApplication()
        let pid: pid_t = 999_702
        let windowId = 999_703
        let targets = manager.fullRescanAppTargets(
            [(pid: pid, app: app)],
            selection: .init(
                discoveryEvidence: .init(
                    pidsWithWindows: [pid],
                    windowServerInfoByWindowId: [:],
                    ownerPIDByWindowId: [windowId: pid]
                ),
                preservingPIDsByWindowId: [windowId: pid],
                persistentEvidencePIDs: [pid],
                includedPIDs: [pid],
                includedWindowIdsByPID: [pid: [windowId]],
                allowsEvidenceFreeOneShot: true
            ),
            requiresTitleForApp: { _, _ in false }
        )
        let target = try XCTUnwrap(targets.first)
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(target.pid, pid)
        XCTAssertEqual(target.route, .persistent)
        XCTAssertEqual(target.includedWindowIds, [windowId])

        for route in [FullRescanEnumerationRoute.persistent, .oneShot] {
            let result = try await AXManager.enumerateFullRescanApp(
                target.app,
                pid: target.pid,
                route: route,
                inspectionContext: target.inspectionContext,
                includedWindowIds: target.includedWindowIds,
                isAppUnresponsive: { queriedPID in
                    XCTAssertEqual(queriedPID, pid)
                    return true
                }
            )
            XCTAssertEqual(result.pid, pid)
            XCTAssertTrue(result.failed)
        }
    }
}
