// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class FocusLossRescanTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let previous: WindowToken

        var handler: AXEventHandler {
            controller.axEventHandler
        }

        var layoutState: LayoutRefreshState {
            controller.layoutRefreshController.layoutState
        }

        var newWindowId: Int {
            previous.windowId + 1
        }

        func axRef(windowId: Int) -> AXWindowRef {
            AXWindowRef(element: AXUIElementCreateApplication(previous.pid), windowId: windowId)
        }

        func addWindow(windowId: Int) -> WindowToken {
            controller.workspaceManager.addWindow(
                axRef(windowId: windowId), pid: previous.pid, windowId: windowId, to: workspaceId
            )
        }

        func focus(_ token: WindowToken) {
            XCTAssertTrue(controller.workspaceManager.confirmManagedFocus(
                token, in: workspaceId, activateWorkspaceOnMonitor: false
            ))
        }

        func assertRescanRequested(file: StaticString = #filePath, line: UInt = #line) throws {
            let refresh = try XCTUnwrap(layoutState.activeRefresh, file: file, line: line)
            XCTAssertEqual(refresh.kind, .fullRescan, file: file, line: line)
            XCTAssertEqual(
                refresh.rescanScope, .targeted(appPIDs: [previous.pid], nativeSpaceIds: []), file: file, line: line
            )
        }

        func assertNoRefresh(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNil(layoutState.activeRefresh, file: file, line: line)
            XCTAssertNil(layoutState.pendingRefresh, file: file, line: line)
        }

        func retryState(windowId: Int, exhausted: Bool) -> AdmissionRetryState {
            let token = WindowToken(pid: previous.pid, windowId: windowId)
            let axRef = axRef(windowId: windowId)
            return AdmissionRetryState(
                expectedToken: token, axRef: axRef, reason: .degenerateGeometry,
                attempt: 1, generation: 1, trigger: .candidate(token: token, axRef: axRef),
                exhausted: exhausted, task: nil
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 913_101
        let windowId = 913_201
        let previous = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid, windowId: windowId, to: workspaceId
        )
        let fixture = Fixture(controller: controller, workspaceId: workspaceId, previous: previous)
        fixture.focus(previous)
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil
        fixture.handler.previouslyFocusedManagedToken = previous
        return fixture
    }

    func testFocusOnANewTiledWindowWaitsForItsFirstFrameAndRescansOnce() throws {
        let fixture = try makeFixture()
        let handler = fixture.handler
        let new = fixture.addWindow(windowId: fixture.newWindowId)
        fixture.focus(new)

        handler.rescanAppThatLostFocus(newFocusWindowId: new.windowId)

        fixture.assertNoRefresh()
        XCTAssertEqual(handler.focusLossRescans.heldByWindowId[new.windowId]?.appPIDs, [fixture.previous.pid])
        XCTAssertEqual(handler.previouslyFocusedManagedToken, new)

        handler.releaseFocusLossRescan(windowId: new.windowId)

        try fixture.assertRescanRequested()
        XCTAssertNil(handler.focusLossRescans.heldByWindowId[new.windowId])
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = nil
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask?.cancel()
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = nil

        handler.releaseFocusLossRescan(windowId: new.windowId)

        fixture.assertNoRefresh()
    }

    func testAPendingFocusTargetRescansWhenTheDeadlineRunsOut() async throws {
        let fixture = try makeFixture()
        let handler = fixture.handler
        let windowId = fixture.newWindowId
        var requested: Duration?
        let (expiry, expire) = AsyncStream<Void>.makeStream()
        handler.focusLossRescans.sleeper = { duration in
            requested = duration
            for await _ in expiry { return }
        }
        handler.admissionRetryStateByWindowId[UInt32(windowId)] = fixture.retryState(
            windowId: windowId, exhausted: false
        )
        XCTAssertTrue(fixture.controller.workspaceManager.recordExternalFocus(
            pid: fixture.previous.pid, windowId: windowId
        ))

        handler.rescanAppThatLostFocus(newFocusWindowId: windowId)

        fixture.assertNoRefresh()
        let held = try XCTUnwrap(handler.focusLossRescans.heldByWindowId[windowId])

        expire.yield()
        await held.deadline.value

        XCTAssertEqual(
            requested, AXEventHandler.stabilizationRetryDelay * (AXEventHandler.createdWindowRetryLimit + 1)
        )
        try fixture.assertRescanRequested()
        XCTAssertNil(handler.focusLossRescans.heldByWindowId[windowId])
        handler.cleanup()
    }

    func testAFocusTargetThatWillNotGetAFirstFrameRescansNow() throws {
        let fixture = try makeFixture()
        let handler = fixture.handler
        let windowId = fixture.newWindowId
        handler.admissionRetryStateByWindowId[UInt32(windowId)] = fixture.retryState(
            windowId: windowId, exhausted: true
        )
        XCTAssertTrue(fixture.controller.workspaceManager.recordExternalFocus(
            pid: fixture.previous.pid, windowId: windowId
        ))

        handler.rescanAppThatLostFocus(newFocusWindowId: windowId)

        try fixture.assertRescanRequested()
        XCTAssertTrue(handler.focusLossRescans.heldByWindowId.isEmpty)
    }

    func testAFloatingNewWindowRescansNow() throws {
        let fixture = try makeFixture()
        let handler = fixture.handler
        let new = fixture.addWindow(windowId: fixture.newWindowId)
        fixture.controller.workspaceManager.setWindowMode(.floating, for: new)
        fixture.focus(new)

        handler.rescanAppThatLostFocus(newFocusWindowId: new.windowId)

        try fixture.assertRescanRequested()
        XCTAssertTrue(handler.focusLossRescans.heldByWindowId.isEmpty)
    }

    func testAFirstFrameFromTheFrameApplyPathReleasesTheRescan() throws {
        let fixture = try makeFixture()
        let handler = fixture.handler
        let new = fixture.addWindow(windowId: fixture.newWindowId)
        fixture.focus(new)
        handler.rescanAppThatLostFocus(newFocusWindowId: new.windowId)
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)

        fixture.controller.serviceLifecycleManager.handleFrameApplySucceeded(AXFrameApplyResult(
            requestId: 1, pid: new.pid, windowId: new.windowId,
            expectedWindow: fixture.axRef(windowId: new.windowId), targetFrame: target, currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: nil, writeOrder: .sizeThenPosition, sizeError: .success, positionError: .success,
                failureReason: nil
            )
        ))

        try fixture.assertRescanRequested()
        XCTAssertNil(handler.focusLossRescans.heldByWindowId[new.windowId])
    }

    private func focusFacts(_ axRef: AXWindowRef, fixture: Fixture) -> ActivationFacts {
        let pid = fixture.previous.pid
        let controller = fixture.controller
        return ActivationFacts(
            pid: pid, source: .focusedWindowChanged, origin: .external,
            observationGeneration: fixture.handler.beginActivationObservation(
                pid: pid, source: .focusedWindowChanged, causalGeneration: nil, controller: controller
            ),
            requestedAtSeq: controller.workspaceManager.worldSeq,
            focusedWindow: FocusedWindowFact(axRef: axRef, isFullscreen: false, isSystemModalSurface: false),
            appVisibilityGeneration: controller.workspaceManager.appVisibilityGeneration(for: pid)
        )
    }

    func testFocusFactsForAWindowStillBeingAdmittedHoldTheRescan() throws {
        let fixture = try makeFixture()
        let handler = fixture.handler
        handler.windowInfoProvider = { _ in nil }

        handler.handleActivationFactsResolved(
            focusFacts(fixture.axRef(windowId: fixture.newWindowId), fixture: fixture)
        )

        XCTAssertEqual(handler.focusLossRescans.heldByWindowId[fixture.newWindowId]?.appPIDs, [fixture.previous.pid])
        XCTAssertNotEqual(fixture.layoutState.activeRefresh?.kind, .fullRescan)
        XCTAssertNotEqual(fixture.layoutState.pendingRefresh?.kind, .fullRescan)
        handler.cleanup()
        XCTAssertTrue(handler.focusLossRescans.heldByWindowId.isEmpty)
    }

    func testFocusFactsForAKnownWindowOfTheSameAppStillRescanNow() throws {
        let fixture = try makeFixture()
        let handler = fixture.handler
        let other = fixture.addWindow(windowId: fixture.newWindowId)

        handler.handleActivationFactsResolved(focusFacts(fixture.axRef(windowId: other.windowId), fixture: fixture))

        XCTAssertTrue(handler.focusLossRescans.heldByWindowId.isEmpty)
        let refresh = try XCTUnwrap(fixture.layoutState.activeRefresh ?? fixture.layoutState.pendingRefresh)
        XCTAssertEqual(refresh.kind, .fullRescan)
        XCTAssertEqual(refresh.rescanScope, .targeted(appPIDs: [fixture.previous.pid], nativeSpaceIds: []))
    }
}
