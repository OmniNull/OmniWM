// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedWindowManagementMembershipTests: XCTestCase {
    func testNativeFloatingCrossingRebindsAndRetargetsMatchingFocusRequest() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let moving = try fixture.open()
        let sibling = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        try fixture.float(moving)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let request = try XCTUnwrap(fixture.controller.focusWindow(moving.token))
        fixture.clearOperations()
        let destinationFrame = fixture.centeredFrame(on: fixture.destinationMonitor)

        fixture.moveNative(moving, to: destinationFrame)

        XCTAssertEqual(fixture.world.workspace(for: moving.token), fixture.destination)
        XCTAssertEqual(fixture.world.floatingState(for: moving.token)?.lastFrame, destinationFrame)
        XCTAssertEqual(
            fixture.world.floatingState(for: moving.token)?.referenceMonitorId,
            fixture.destinationMonitor.id
        )
        XCTAssertEqual(fixture.world.entry(for: moving.token)?.observedState.frame, destinationFrame)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.requestId, request.requestId)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.workspaceId, fixture.destination)
        XCTAssertEqual(fixture.world.pendingFocusedToken, moving.token)
        XCTAssertEqual(fixture.world.workspace(for: sibling.token), fixture.source)
        XCTAssertEqual(fixture.world.workspace(for: fixture.external), fixture.source)
        XCTAssertFalse(moving.window.operations.contains(.focus))
        XCTAssertEqual(fixture.activationCount, 0)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertNil(fixture.controller.axManager.lastAppliedFrame(for: moving.token.windowId))
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testNativeCrossingPreservesNewerUnrelatedFocusRequest() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let moving = try fixture.open()
        let sibling = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        try fixture.float(moving)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let unrelated = try XCTUnwrap(fixture.controller.focusWindow(sibling.token))

        fixture.moveNative(moving, to: fixture.centeredFrame(on: fixture.destinationMonitor))

        XCTAssertEqual(fixture.world.workspace(for: moving.token), fixture.destination)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest, unrelated)
        XCTAssertEqual(fixture.world.pendingFocusedToken, sibling.token)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testNativeCrossingHonorsIssuedHiddenScratchpadSuppressedAndRegistrationGuards() async throws {
        for protection in NativeProtection.allCases {
            let fixture = try HostedManagementFixture()
            defer { fixture.close() }
            let moving = try fixture.open()
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            try fixture.float(moving)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            let before = try XCTUnwrap(fixture.world.floatingState(for: moving.token))
            switch protection {
            case .issued:
                fixture.manager.applyingFrames.insert(moving.token)
            case .hidden:
                try fixture.hide(moving)
            case .scratchpad:
                let scratchpad: ScratchpadIndex = 1
                XCTAssertTrue(fixture.world.setScratchpadMembership(moving.token, to: scratchpad))
            case .minimized:
                moving.window.miniaturize(nil)
            case .unregistered:
                fixture.manager.windows.removeValue(forKey: moving.token)
            }
            let sequence = fixture.world.worldSeq
            let destinationFrame = fixture.centeredFrame(on: fixture.destinationMonitor)

            fixture.moveNative(moving, to: destinationFrame)

            XCTAssertEqual(fixture.world.workspace(for: moving.token), fixture.source, "\(protection)")
            switch protection {
            case .issued,
                 .hidden,
                 .unregistered:
                XCTAssertEqual(fixture.world.worldSeq, sequence)
                XCTAssertEqual(fixture.world.floatingState(for: moving.token), before)
            case .scratchpad,
                 .minimized:
                XCTAssertEqual(fixture.world.floatingState(for: moving.token)?.lastFrame, destinationFrame)
                XCTAssertEqual(
                    fixture.world.floatingState(for: moving.token)?.referenceMonitorId, fixture.destinationMonitor.id
                )
            }
            fixture.manager.applyingFrames.remove(moving.token)
            fixture.manager.windows[moving.token] = moving.window
            fixture.close()
            await ShellWidgetHost.flushRetiredWork()
        }
    }

    func testSameDisplayNativeMoveUpdatesGeometryWithoutReassigningWorkspace() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let moving = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        try fixture.float(moving)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let frame = fixture.centeredFrame(on: fixture.sourceMonitor)

        fixture.moveNative(moving, to: frame)
        let sequence = fixture.world.worldSeq
        fixture.manager.windowDidMove(fixture.notification(moving.window, name: NSWindow.didMoveNotification))

        XCTAssertEqual(fixture.world.workspace(for: moving.token), fixture.source)
        XCTAssertEqual(fixture.world.floatingState(for: moving.token)?.lastFrame, frame)
        XCTAssertEqual(fixture.world.floatingState(for: moving.token)?.referenceMonitorId, fixture.sourceMonitor.id)
        XCTAssertEqual(fixture.world.worldSeq, sequence)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }
}

private enum NativeProtection: CaseIterable {
    case issued
    case hidden
    case scratchpad
    case minimized
    case unregistered
}
