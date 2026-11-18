// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
private final class CreatedWindowLookupGate {
    private enum State {
        case idle
        case waiting(CheckedContinuation<AXWindowRef?, Never>)
        case ready(AXWindowRef?)
    }

    private var state = State.idle

    func wait() async -> AXWindowRef? {
        switch state {
        case .idle:
            return await withCheckedContinuation { state = .waiting($0) }
        case let .ready(axRef):
            state = .idle
            return axRef
        case .waiting:
            XCTFail("Only one AX lookup can wait on this gate")
            return nil
        }
    }

    func resume(_ axRef: AXWindowRef? = nil) {
        if case let .waiting(continuation) = state {
            state = .idle
            continuation.resume(returning: axRef)
        } else {
            state = .ready(axRef)
        }
    }
}

@MainActor
final class WindowAdmissionIdentityLookupTests: XCTestCase {
    private let token = WindowToken(pid: 490_101, windowId: 490_102)

    private func windowInfo(for token: WindowToken) -> WindowServerInfo {
        WindowServerInfo(
            id: UInt32(token.windowId), pid: token.pid, level: 0,
            frame: CGRect(x: 10, y: 10, width: 800, height: 600)
        )
    }

    func testCreateReturnsBeforeAXReplyAndCoalescesDuplicateEvents() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer { handler.cleanup() }
        let windowId = UInt32(token.windowId)
        let info = windowInfo(for: token)
        handler.windowInfoProvider = { _ in info }
        let gate = CreatedWindowLookupGate()
        let started = expectation(description: "lookup started")
        var requests = 0
        handler.createdWindowAXRefProvider = { _ in
            requests += 1
            started.fulfill()
            return await gate.wait()
        }

        handler.processCreatedWindow(windowId: windowId)

        XCTAssertEqual(requests, 0)
        await handler.lifecycleQueries.task?.value
        let original = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        let task = try XCTUnwrap(original.task)
        XCTAssertEqual(original.attempt, 0)
        await fulfillment(of: [started], timeout: failureBound)
        handler.processCreatedWindow(windowId: windowId)
        await handler.lifecycleQueries.task?.value
        XCTAssertTrue(handler.retryAdmissionAfterFrameChange(windowId: windowId))
        await handler.lifecycleQueries.task?.value
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(handler.admissionRetryStateByWindowId[windowId]?.executionPhase, original.executionPhase)

        gate.resume()
        await task.value

        let retry = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(retry.attempt, 1)
        XCTAssertEqual(retry.reason, .axWindowMissing)
        XCTAssertEqual(retry.executionPhase, .waiting)
        XCTAssertNotNil(retry.task)
    }

    func testDestroyedWindowReplyCannotReplaceNewLookupForReusedID() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer { handler.cleanup() }
        let windowId = UInt32(token.windowId)
        let info = windowInfo(for: token)
        handler.windowInfoProvider = { _ in info }
        let gate = CreatedWindowLookupGate()
        let started = expectation(description: "lookup started")
        handler.createdWindowAXRefProvider = { _ in
            started.fulfill()
            return await gate.wait()
        }
        handler.processCreatedWindow(windowId: windowId)
        await handler.lifecycleQueries.task?.value
        let original = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        let task = try XCTUnwrap(original.task)
        await fulfillment(of: [started], timeout: failureBound)

        handler.handleCGSEvent(.closed(windowId: windowId))
        XCTAssertNil(handler.admissionRetryStateByWindowId[windowId])
        await handler.lifecycleQueries.task?.value
        let replacementGate = CreatedWindowLookupGate()
        let replacementStarted = expectation(description: "replacement lookup started")
        handler.createdWindowAXRefProvider = { _ in
            replacementStarted.fulfill()
            return await replacementGate.wait()
        }
        handler.processCreatedWindow(windowId: windowId)
        await handler.lifecycleQueries.task?.value
        await fulfillment(of: [replacementStarted], timeout: failureBound)
        let replacement = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        let replacementTask = try XCTUnwrap(replacement.task)
        XCTAssertNotEqual(replacement.generation, original.generation)

        gate.resume(WindowAdmissionTestSupport.axRef(for: token))
        await task.value
        replacementGate.resume()
        await replacementTask.value

        XCTAssertEqual(handler.admissionRetryStateByWindowId[windowId]?.attempt, 1)
        XCTAssertNil(controller.workspaceManager.entry(for: token))
    }

    func testFocusedAdmissionSupersedesOutstandingCreateLookup() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer { handler.cleanup() }
        let windowId = UInt32(token.windowId)
        let info = windowInfo(for: token)
        handler.windowInfoProvider = { _ in info }
        let gate = CreatedWindowLookupGate()
        let started = expectation(description: "lookup started")
        handler.createdWindowAXRefProvider = { _ in
            started.fulfill()
            return await gate.wait()
        }
        handler.processCreatedWindow(windowId: windowId)
        await handler.lifecycleQueries.task?.value
        let task = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        await fulfillment(of: [started], timeout: failureBound)
        XCTAssertTrue(handler.scheduleAdmissionRetry(
            windowId: windowId, expectedToken: token, reason: .factsDeferred,
            trigger: .focused(
                token: token, source: .focusedWindowChanged,
                observationGeneration: 1, callbackGeneration: nil
            )
        ))
        let focused = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])

        gate.resume(WindowAdmissionTestSupport.axRef(for: token))
        await task.value

        let remaining = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(remaining.generation, focused.generation)
        guard case .focused = remaining.trigger else { return XCTFail("Lost focused admission") }
        XCTAssertNil(controller.workspaceManager.entry(for: token))
    }

    func testChangedWindowServerIdentityRejectsLateLookup() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer { handler.cleanup() }
        let windowId = UInt32(token.windowId)
        var info = windowInfo(for: token)
        handler.windowInfoProvider = { _ in info }
        let gate = CreatedWindowLookupGate()
        let started = expectation(description: "lookup started")
        handler.createdWindowAXRefProvider = { _ in
            started.fulfill()
            return await gate.wait()
        }
        handler.processCreatedWindow(windowId: windowId)
        await handler.lifecycleQueries.task?.value
        let task = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        await fulfillment(of: [started], timeout: failureBound)

        info = windowInfo(for: WindowToken(pid: token.pid + 1, windowId: token.windowId))
        gate.resume(WindowAdmissionTestSupport.axRef(for: token))
        await task.value

        XCTAssertNil(controller.workspaceManager.entry(for: token))
        let retry = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(retry.reason, .windowInfoMissing)
        XCTAssertEqual(retry.attempt, 1)
        var requestedToken: WindowToken?
        handler.createdWindowAXRefProvider = { token in
            requestedToken = token
            return nil
        }
        XCTAssertTrue(handler.dispatchAdmissionRetry(windowId: windowId))
        await handler.lifecycleQueries.task?.value
        let retryTask = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        await retryTask.value
        XCTAssertEqual(requestedToken?.pid, info.pid)
    }

    func testDiscoveryDuringLookupCanResumeAfterDrain() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer {
            handler.cleanup()
            controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 0
        }
        let windowId = UInt32(token.windowId)
        let info = windowInfo(for: token)
        handler.windowInfoProvider = { _ in info }
        let gate = CreatedWindowLookupGate()
        let started = expectation(description: "lookup started")
        handler.createdWindowAXRefProvider = { _ in
            started.fulfill()
            return await gate.wait()
        }
        handler.processCreatedWindow(windowId: windowId)
        await handler.lifecycleQueries.task?.value
        let task = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        await fulfillment(of: [started], timeout: failureBound)

        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 1
        gate.resume()
        await task.value

        XCTAssertTrue(handler.isCreatedWindowDeferred(windowId))
        XCTAssertEqual(handler.admissionRetryStateByWindowId[windowId]?.executionPhase, .waiting)
        XCTAssertNil(handler.admissionRetryStateByWindowId[windowId]?.task)
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 0
        let resumed = expectation(description: "lookup resumed after drain")
        handler.createdWindowAXRefProvider = { _ in
            resumed.fulfill()
            return await gate.wait()
        }
        handler.drainDeferredCreatedWindows(spaceIdsForWindow: { _ in [] })
        await handler.lifecycleQueries.task?.value
        await fulfillment(of: [resumed], timeout: failureBound)
        let resumedTask = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        gate.resume()
        await resumedTask.value
        XCTAssertFalse(handler.isCreatedWindowDeferred(windowId))
        XCTAssertEqual(handler.admissionRetryStateByWindowId[windowId]?.attempt, 1)
    }

    func testExhaustedCreateIgnoresFrameChanges() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer { handler.cleanup() }
        let windowId = UInt32(token.windowId)
        let info = windowInfo(for: token)
        installExhaustedCreateRetry(handler, windowId: windowId)
        handler.frameObservations.query = { _ in info }
        var createQueries = 0
        handler.lifecycleQueries.query = { _ in
            createQueries += 1
            return nil
        }

        for _ in 0 ..< 3 {
            handler.handleFrameChanged(windowId: windowId)
            await handler.frameObservations.byWindowId[windowId]?.task.value
            await handler.lifecycleQueries.task?.value
        }

        XCTAssertEqual(createQueries, 0)
        let state = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertTrue(state.exhausted)
        XCTAssertEqual(state.executionPhase, .waiting)
        XCTAssertNil(state.task)
    }

    func testExhaustedRetryDoesNotSuppressFrameForReusedWindowID() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        let refresh = controller.layoutRefreshController
        defer {
            handler.cleanup()
            refresh.resetState()
        }
        let replacement = WindowToken(pid: token.pid + 1, windowId: token.windowId)
        let windowId = UInt32(token.windowId)
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = WindowAdmissionTestSupport.track(replacement, in: workspaceId, controller: controller)
        installExhaustedCreateRetry(handler, windowId: windowId)
        let info = windowInfo(for: replacement)
        handler.frameObservations.query = { _ in info }
        refresh.layoutState.isRefreshSuspendedForLockScreen = true

        handler.handleFrameChanged(windowId: windowId)
        await handler.frameObservations.byWindowId[windowId]?.task.value

        XCTAssertEqual(refresh.layoutState.pendingRefresh?.reason, .axWindowChanged)
        XCTAssertEqual(refresh.layoutState.pendingRefresh?.affectedWorkspaceIds, [workspaceId])
    }

    func testCompletedExhaustedCreateAttemptCannotStayRunning() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer { handler.cleanup() }
        let windowId = UInt32(token.windowId)
        let info = windowInfo(for: token)
        var windowServerInfo: WindowServerInfo?
        handler.windowInfoProvider = { _ in windowServerInfo }
        installExhaustedCreateRetry(handler, windowId: windowId)
        let gate = CreatedWindowLookupGate()
        defer { gate.resume() }
        let started = expectation(description: "AX lookup after metadata recovery")
        var requests = 0
        handler.createdWindowAXRefProvider = { _ in
            requests += 1
            started.fulfill()
            return await gate.wait()
        }

        handler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))
        await handler.lifecycleQueries.task?.value
        XCTAssertEqual(handler.admissionRetryStateByWindowId[windowId]?.executionPhase, .waiting)
        XCTAssertEqual(requests, 0)

        windowServerInfo = info
        handler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))
        await handler.lifecycleQueries.task?.value
        await fulfillment(of: [started], timeout: failureBound)
        let lookup = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        gate.resume()
        await lookup.value
        XCTAssertEqual(requests, 1)
        let state = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertTrue(state.exhausted)
        XCTAssertEqual(state.executionPhase, .waiting)
        XCTAssertNil(state.task)
    }

    func testNewCreateAdmitsWindowWithoutReplayingExhaustedFocus() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer {
            handler.cleanup()
            controller.layoutRefreshController.resetState()
        }
        let token = self.token
        let windowId = UInt32(token.windowId)
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        let info = windowInfo(for: token)
        let trigger = AdmissionRetryTrigger.focused(
            token: token, source: .focusedWindowChanged, observationGeneration: 0, callbackGeneration: nil
        )
        handler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: token, axRef: axRef, reason: .degenerateGeometry,
            attempt: AXEventHandler.createdWindowRetryLimit, generation: 1, trigger: trigger,
            focusedAdmissionContinuation: trigger.focusedAdmissionContinuation, exhausted: true, task: nil
        )
        var focusReads = 0
        controller.factResolver.factProvider = { _ in
            focusReads += 1
            return nil
        }
        controller.hasStartedServices = true
        handler.frontmostApplicationPIDProvider = { token.pid }
        handler.windowInfoProvider = { _ in info }
        let evaluation = controller.evaluateWindowDisposition(
            token: token,
            evidence: .init(
                facts: .init(
                    role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
                    title: "New window", hasCloseButton: true, hasFullscreenButton: true,
                    fullscreenButtonEnabled: true, hasZoomButton: true, hasMinimizeButton: true,
                    appPolicy: .regular, bundleId: "test.admission", attributeFetchSucceeded: true
                ),
                sizeConstraints: .unconstrained
            ),
            appFullscreen: false, windowInfo: info,
            admissionGeometry: .init(isSizeSettable: true, frame: ScreenCoordinateSpace.toAppKit(rect: info.frame))
        )
        controller.windowDispositionEvaluationForTests = { _ in evaluation }
        let gate = CreatedWindowLookupGate()
        defer { gate.resume() }
        let started = XCTestExpectation(description: "new create AX lookup")
        handler.createdWindowAXRefProvider = { _ in
            started.fulfill()
            return await gate.wait()
        }

        handler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))
        XCTAssertEqual(focusReads, 0)
        await handler.lifecycleQueries.task?.value
        let lookup = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        guard await XCTWaiter.fulfillment(of: [started], timeout: failureBound) == .completed else {
            return XCTFail("The new create AX lookup did not start")
        }
        XCTAssertFalse(handler.scheduleFocusedAdmissionReadmit(
            continuation: .init(
                token: token, source: .focusedWindowChanged, observationGeneration: 0, callbackGeneration: nil
            ),
            axRef: axRef,
            reason: .degenerateGeometry
        ))
        gate.resume(axRef)
        await lookup.value

        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(focusReads, 0)
    }

    func testDefaultLookupCreatesNoAXContextForPolicyExcludedApp() async throws {
        guard AXIsProcessTrusted() else {
            throw MissingTestPrerequisite("Observing AX context creation requires Accessibility trust")
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.controlcenter" || $0.bundleIdentifier == "com.apple.notificationcenterui"
        }) else {
            throw MissingTestPrerequisite("No policy-excluded system UI process is running")
        }
        let pid = app.processIdentifier
        XCTAssertFalse(AXManager.shouldTrack(app, pid: pid))
        XCTAssertNil(AppAXContextRegistry.contexts[pid])

        let axRef = try await AXEventHandler.lookupCreatedWindowIdentity(
            WindowToken(pid: pid, windowId: 3_999_999_001)
        )

        XCTAssertNil(axRef)
        XCTAssertNil(AppAXContextRegistry.contexts[pid])
    }

    private func installExhaustedCreateRetry(_ handler: AXEventHandler, windowId: UInt32) {
        let generation = handler.nextAdmissionRetryGeneration
        handler.nextAdmissionRetryGeneration &+= 1
        handler.admissionRetryStateByWindowId[windowId] = AdmissionRetryState(
            expectedToken: token, axRef: nil, reason: .axWindowMissing,
            attempt: AXEventHandler.createdWindowRetryLimit, generation: generation, trigger: .create,
            exhausted: true, task: nil
        )
    }

    func testRetryDispatchedDuringDiscoveryCanResumeAfterDrain() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer {
            handler.cleanup()
            controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 0
        }
        let windowId = UInt32(token.windowId)
        let info = windowInfo(for: token)
        handler.windowInfoProvider = { _ in info }
        let gate = CreatedWindowLookupGate()
        let started = expectation(description: "lookup resumed after drain")
        var requests = 0
        handler.createdWindowAXRefProvider = { _ in
            requests += 1
            started.fulfill()
            return await gate.wait()
        }
        XCTAssertTrue(handler.scheduleAdmissionRetry(
            windowId: windowId, expectedToken: token, reason: .axWindowMissing, trigger: .create
        ))
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 1

        XCTAssertTrue(handler.dispatchAdmissionRetry(windowId: windowId))
        await handler.lifecycleQueries.task?.value

        XCTAssertTrue(handler.isCreatedWindowDeferred(windowId))
        XCTAssertEqual(handler.admissionRetryStateByWindowId[windowId]?.executionPhase, .waiting)
        XCTAssertNil(handler.admissionRetryStateByWindowId[windowId]?.task)
        XCTAssertEqual(requests, 0)
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 0
        handler.drainDeferredCreatedWindows(spaceIdsForWindow: { _ in [] })
        await handler.lifecycleQueries.task?.value
        await fulfillment(of: [started], timeout: failureBound)
        let task = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        gate.resume()
        await task.value
        XCTAssertFalse(handler.isCreatedWindowDeferred(windowId))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(handler.admissionRetryStateByWindowId[windowId]?.attempt, 2)
    }
}
