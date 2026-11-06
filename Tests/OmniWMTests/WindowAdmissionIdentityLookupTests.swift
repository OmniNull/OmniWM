// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
private final class CreatedWindowLookupGate {
    var continuation: CheckedContinuation<AXWindowRef?, Never>?

    func wait() async -> AXWindowRef? {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ axRef: AXWindowRef? = nil) {
        continuation?.resume(returning: axRef)
        continuation = nil
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

    func testExhaustedCreateIsRetriedByLaterFrameAndCreateEvents() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer { handler.cleanup() }
        let windowId = UInt32(token.windowId)
        let info = windowInfo(for: token)
        handler.windowInfoProvider = { _ in info }
        installExhaustedCreateRetry(handler, windowId: windowId)
        let gate = CreatedWindowLookupGate()
        defer { gate.resume() }
        let frameStarted = expectation(description: "frame recovery AX lookup")
        let createStarted = expectation(description: "create recovery AX lookup")
        var requests = 0
        handler.createdWindowAXRefProvider = { _ in
            requests += 1
            if requests == 1 { frameStarted.fulfill() } else { createStarted.fulfill() }
            return await gate.wait()
        }

        XCTAssertTrue(handler.retryAdmissionAfterFrameChange(windowId: windowId))
        await handler.lifecycleQueries.task?.value
        await fulfillment(of: [frameStarted], timeout: failureBound)
        let frameLookup = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        gate.resume()
        await frameLookup.value
        let afterFrame = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertTrue(afterFrame.exhausted)
        XCTAssertEqual(afterFrame.executionPhase, .waiting)
        XCTAssertNil(afterFrame.task)

        handler.processCreatedWindow(windowId: windowId)
        await handler.lifecycleQueries.task?.value
        await fulfillment(of: [createStarted], timeout: failureBound)
        let createLookup = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        gate.resume()
        await createLookup.value

        XCTAssertEqual(requests, 2)
        XCTAssertEqual(handler.admissionRetryStateByWindowId[windowId]?.executionPhase, .waiting)
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

        XCTAssertTrue(handler.dispatchAdmissionRetry(windowId: windowId))
        await handler.lifecycleQueries.task?.value
        XCTAssertEqual(handler.admissionRetryStateByWindowId[windowId]?.executionPhase, .waiting)
        XCTAssertEqual(requests, 0)

        windowServerInfo = info
        XCTAssertTrue(handler.dispatchAdmissionRetry(windowId: windowId))
        await handler.lifecycleQueries.task?.value
        await fulfillment(of: [started], timeout: failureBound)
        let lookup = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        gate.resume()
        await lookup.value
        XCTAssertEqual(requests, 1)
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
