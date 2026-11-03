// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedWindowManagementLifecycleTests: XCTestCase {
    func testStopRestoresHiddenHostedWindowAndPreservesMinimizedSibling() async throws {
        for floating in [false, true] {
            let fixture = try HostedManagementFixture()
            defer { fixture.close() }
            let hidden = try fixture.open()
            let minimized = try fixture.open()
            let visible = try fixture.open()
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            let hiddenText = "Preserve this ordered-out session"
            let minimizedText = "Preserve this minimized session"
            try await applyHosted(hiddenText, to: hidden.session)
            try await applyHosted(minimizedText, to: minimized.session)
            if floating { try fixture.float(hidden) }
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            try fixture.hide(hidden)
            minimized.window.miniaturize(nil)
            let hiddenState = try XCTUnwrap(fixture.world.hiddenState(for: hidden.token))
            let savedFloating = fixture.world.floatingState(for: hidden.token)
            let offscreen = hidden.window.frame.offsetBy(
                dx: fixture.sourceMonitor.frame.width, dy: -fixture.sourceMonitor.frame.height
            )
            hidden.window.setFrame(offscreen, display: false)
            let placement = StopWindowGeometry.placement(
                floating: floating ? savedFloating : nil, hidden: hiddenState, monitor: fixture.sourceMonitor
            )
            let expected = try XCTUnwrap(StopWindowGeometry.destination(
                for: offscreen, in: fixture.sourceMonitor.visibleFrame, placement: placement
            ))
            let externalHidden = HiddenState(
                proportionalPosition: .zero, referenceMonitorId: fixture.sourceMonitor.id, reason: .workspaceInactive
            )
            fixture.world.setHiddenState(externalHidden, for: fixture.external)
            let externalTargets = fixture.controller.serviceLifecycleManager.stopWindowTargets()
            XCTAssertEqual(externalTargets.map(\.token), [fixture.external])
            let visibleFrame = visible.window.frame
            fixture.clearOperations()

            fixture.controller.serviceLifecycleManager.stopServices(retainingAXWorkers: true)

            XCTAssertFalse(fixture.controller.hasStartedServices)
            XCTAssertEqual(hidden.window.frame, expected)
            XCTAssertEqual(hidden.window.operations, [.frame(expected), .front])
            XCTAssertTrue(hidden.window.isVisible)
            XCTAssertNil(fixture.world.hiddenState(for: hidden.token))
            XCTAssertEqual(fixture.world.entry(for: hidden.token)?.observedState.frame, expected)
            XCTAssertTrue(minimized.window.isMiniaturized)
            XCTAssertTrue(try XCTUnwrap(fixture.world.entry(for: minimized.token)).observedState.isMinimized)
            XCTAssertFalse(minimized.window.operations.contains(.restore))
            XCTAssertFalse(minimized.window.operations.contains(.front))
            XCTAssertEqual(visible.window.frame, visibleFrame)
            XCTAssertFalse(visible.window.operations.contains(.focus))
            XCTAssertEqual(fixture.activationCount, 0)
            XCTAssertEqual(fixture.world.hiddenState(for: fixture.external), externalHidden)
            assertHostedContent(hiddenText, in: hidden.session)
            assertHostedContent(minimizedText, in: minimized.session)
            XCTAssertTrue(fixture.manager.runtime(for: hidden.token) === hidden.session)
            XCTAssertTrue(fixture.manager.runtime(for: minimized.token) === minimized.session)
            var restored: [WindowToken] = []
            let recoveryFailureBudget: TimeInterval = 10
            let failureDeadline = ProcessInfo.processInfo.systemUptime + recoveryFailureBudget
            await fixture.controller.serviceLifecycleManager.recoverStopWindows(
                externalTargets, deadline: failureDeadline,
                operations: StopRecoveryOperations(
                    hasContext: { _ in true }, reveal: { _, _ in true },
                    restore: { target, _ in
                        restored.append(target.token)
                        return StopWindowOutcome(
                            target: target,
                            confirmedMinimized: false,
                            frame: fixture.externalFrame
                        )
                    }
                )
            )
            XCTAssertEqual(restored, [fixture.external])
            XCTAssertNil(fixture.world.hiddenState(for: fixture.external))
            fixture.clearOperations()
            fixture.controller.serviceLifecycleManager.stopServices(retainingAXWorkers: false)
            XCTAssertTrue(hidden.window.operations.isEmpty)
            XCTAssertTrue(minimized.window.operations.isEmpty)
            fixture.close()
            await ShellWidgetHost.flushRetiredWork()
        }
    }

    func testStopUsesConnectedMonitorAndClearsInterruptedNativeResize() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let instance = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let start = instance.window.frame
        fixture.manager.windowWillStartLiveResize(
            fixture.notification(instance.window, name: NSWindow.willStartLiveResizeNotification)
        )
        XCTAssertEqual(fixture.manager.liveResizeStarts[instance.token], start)
        let hidden = HiddenState(
            proportionalPosition: CGPoint(x: 1, y: 1),
            referenceMonitorId: fixture.destinationMonitor.id, reason: .workspaceInactive
        )
        fixture.world.setHiddenState(hidden, for: instance.token)
        fixture.manager.setHidden(true, for: instance.token)
        fixture.world.applyMonitorConfigurationChange([fixture.sourceMonitor])
        let oversized = CGRect(
            x: fixture.sourceMonitor.frame.maxX, y: fixture.sourceMonitor.frame.minY,
            width: fixture.sourceMonitor.frame.width + fixture.definition.contentSize.width,
            height: fixture.sourceMonitor.frame.height + fixture.definition.contentSize.height
        )
        instance.window.setFrame(oversized, display: false)

        fixture.controller.serviceLifecycleManager.stopServices(retainingAXWorkers: false)

        XCTAssertNil(fixture.manager.liveResizeStarts[instance.token])
        XCTAssertEqual(instance.window.frame.size, oversized.size)
        XCTAssertEqual(instance.window.frame.minX, fixture.sourceMonitor.visibleFrame.minX)
        XCTAssertEqual(instance.window.frame.maxY, fixture.sourceMonitor.visibleFrame.maxY)
        XCTAssertNil(fixture.world.hiddenState(for: instance.token))
        XCTAssertTrue(instance.window.isVisible)
        fixture.manager.windowDidEndLiveResize(
            fixture.notification(instance.window, name: NSWindow.didEndLiveResizeNotification)
        )
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testStoppedCallbacksPreserveNativeUseAndResumeReconcilesLatestFrames() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let tiled = try fixture.open()
        let floating = try fixture.open()
        let closing = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        try fixture.float(floating)
        try fixture.select(tiled)
        _ = fixture.controller.workspaceNavigationHandler.commitWindowMove(
            handle: try XCTUnwrap(fixture.world.handle(for: tiled.token)), toWorkspaceId: fixture.sourceOther
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        fixture.controller.serviceLifecycleManager.stopServices(retainingAXWorkers: false)
        let stoppedTiledFrame = tiled.window.frame
        let nativeTiled = tiled.window.frameRect(forContentRect: fixture.centeredFrame(
            on: fixture.sourceMonitor, size: fixture.definition.minimumContentSize
        ))
        let nativeFloating = fixture.centeredFrame(on: fixture.destinationMonitor)
        fixture.clearOperations()

        fixture.moveNative(tiled, to: nativeTiled)
        fixture.moveNative(floating, to: nativeFloating)
        tiled.window.makeKey()
        fixture.manager.windowDidBecomeKey(fixture.notification(tiled.window, name: NSWindow.didBecomeKeyNotification))
        floating.window.miniaturize(nil)
        floating.window.deminiaturize(nil)
        closing.window.close()
        let stoppedText = "Still editable while management is disabled"
        try await applyHosted(stoppedText, to: tiled.session)

        XCTAssertEqual(fixture.world.entry(for: tiled.token)?.observedState.frame, stoppedTiledFrame)
        XCTAssertEqual(fixture.world.workspace(for: floating.token), fixture.source)
        XCTAssertEqual(fixture.world.windowMode(for: tiled.token), .tiling)
        XCTAssertEqual(tiled.session.surface.size, tiled.window.contentRect(forFrameRect: nativeTiled).size)
        XCTAssertNil(fixture.manager.runtime(for: closing.token))
        XCTAssertNil(fixture.world.entry(for: closing.token))
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(fixture.activationCount, 0)
        fixture.controller.hasStartedServices = true

        fixture.manager.reconcileManagementResume()

        XCTAssertEqual(fixture.world.entry(for: tiled.token)?.observedState.frame, nativeTiled)
        XCTAssertEqual(fixture.world.entry(for: floating.token)?.observedState.frame, nativeFloating)
        XCTAssertEqual(fixture.world.workspace(for: tiled.token), fixture.sourceOther)
        XCTAssertEqual(fixture.world.workspace(for: floating.token), fixture.destination)
        XCTAssertEqual(fixture.world.windowMode(for: tiled.token), .tiling)
        XCTAssertEqual(fixture.world.windowMode(for: floating.token), .floating)
        fixture.controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged, affectedWorkspaceIds: [fixture.source, fixture.sourceOther, fixture.destination]
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertFalse(tiled.window.isVisible)
        XCTAssertTrue(floating.window.isVisible)
        XCTAssertTrue(fixture.manager.runtime(for: tiled.token) === tiled.session)
        XCTAssertTrue(fixture.manager.runtime(for: floating.token) === floating.session)
        assertHostedContent(stoppedText, in: tiled.session)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testBackingCallbacksUpdateOnlyRegisteredSessionWhileManagementIsStopped() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let first = try fixture.open()
        let sibling = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        fixture.controller.serviceLifecycleManager.stopServices(retainingAXWorkers: false)
        let initialScale = first.session.surface.scale
        let destinationScale = initialScale + initialScale
        let siblingScale = sibling.session.surface.scale
        first.window.reportedBackingScale = destinationScale

        fixture.manager.windowDidChangeBackingProperties(
            fixture.notification(first.window, name: NSWindow.didChangeBackingPropertiesNotification)
        )

        XCTAssertEqual(first.session.surface.scale, destinationScale)
        XCTAssertEqual(sibling.session.surface.scale, siblingScale)
        first.window.reportedBackingScale = initialScale
        fixture.manager.windowDidChangeScreen(fixture.notification(
            first.window,
            name: NSWindow.didChangeScreenNotification
        ))
        XCTAssertEqual(first.session.surface.scale, initialScale)
        fixture.manager.windows.removeValue(forKey: first.token)
        first.window.reportedBackingScale = destinationScale
        fixture.manager.windowDidChangeBackingProperties(
            fixture.notification(first.window, name: NSWindow.didChangeBackingPropertiesNotification)
        )
        XCTAssertEqual(first.session.surface.scale, initialScale)
        XCTAssertEqual(sibling.session.surface.scale, siblingScale)
        fixture.manager.windows[first.token] = first.window
        first.window.close()
        fixture.manager.windowDidChangeScreen(fixture.notification(
            first.window,
            name: NSWindow.didChangeScreenNotification
        ))
        XCTAssertEqual(sibling.session.surface.scale, siblingScale)
        XCTAssertTrue(fixture.manager.runtime(for: sibling.token) === sibling.session)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }
}
