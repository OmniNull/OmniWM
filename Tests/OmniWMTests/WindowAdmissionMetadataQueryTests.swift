// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowAdmissionMetadataQueryTests: XCTestCase {
    private let token = WindowToken(pid: 490_701, windowId: 490_702)

    private var windowInfo: WindowServerInfo {
        WindowServerInfo(
            id: UInt32(token.windowId), pid: token.pid, level: 0,
            frame: CGRect(x: 10, y: 10, width: 800, height: 600)
        )
    }

    func testRetryQueriesCoalesceFrameBurstsAndCloseInvalidatesReply() async throws {
        for candidate in [false, true] {
            let controller = WindowAdmissionTestSupport.controller()
            let handler = controller.axEventHandler
            defer { handler.cleanup() }
            let gate = LifecycleQueryGate()
            defer { gate.resume() }
            let started = expectation(description: "retry metadata query started")
            let windowId = UInt32(token.windowId)
            let axRef = WindowAdmissionTestSupport.axRef(for: token)
            var queries = 0
            handler.windowInfoProvider = { _ in XCTFail("Main-thread metadata query")
                return nil
            }
            handler.lifecycleQueries.query = { _ in
                queries += 1
                guard queries == 1 else { return nil }
                started.fulfill()
                return await gate.wait()
            }
            XCTAssertTrue(handler.scheduleAdmissionRetry(
                windowId: windowId, expectedToken: candidate ? token : nil,
                axRef: candidate ? axRef : nil, reason: .windowInfoMissing,
                trigger: candidate ? .candidate(token: token, axRef: axRef) : .create
            ))
            XCTAssertTrue(handler.dispatchAdmissionRetry(windowId: windowId))
            let task = try XCTUnwrap(handler.lifecycleQueries.task)
            XCTAssertEqual(queries, 0)
            await fulfillment(of: [started], timeout: failureBound)
            let phase = handler.admissionRetryStateByWindowId[windowId]?.executionPhase
            for _ in 0 ..< 20 { XCTAssertTrue(handler.retryAdmissionAfterFrameChange(windowId: windowId)) }
            XCTAssertEqual(queries, 1)
            XCTAssertTrue(handler.lifecycleQueries.pending.isEmpty)
            XCTAssertEqual(handler.admissionRetryStateByWindowId[windowId]?.executionPhase, phase)

            handler.handleCGSEvent(.closed(windowId: windowId))
            XCTAssertNil(handler.admissionRetryStateByWindowId[windowId])
            gate.resume(windowInfo)
            await task.value
            XCTAssertEqual(queries, 2)
            XCTAssertNil(handler.admissionRetryStateByWindowId[windowId])
            XCTAssertNil(controller.workspaceManager.entry(for: token))
        }
    }

    func testHigherPriorityRetrySupersedesSuspendedMetadataReply() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer { handler.cleanup() }
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "metadata query started")
        let windowId = UInt32(token.windowId)
        handler.windowInfoProvider = { _ in XCTFail("Main-thread metadata query")
            return nil
        }
        handler.createdWindowAXRefProvider = { _ in XCTFail("Stale query started AX lookup")
            return nil
        }
        handler.lifecycleQueries.query = { _ in
            started.fulfill()
            return await gate.wait()
        }
        XCTAssertTrue(handler.scheduleAdmissionRetry(
            windowId: windowId, expectedToken: nil, reason: .windowInfoMissing, trigger: .create
        ))
        XCTAssertTrue(handler.dispatchAdmissionRetry(windowId: windowId))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [started], timeout: failureBound)
        XCTAssertTrue(handler.scheduleAdmissionRetry(
            windowId: windowId, expectedToken: token, reason: .factsDeferred,
            trigger: .focused(
                token: token, source: .focusedWindowChanged, observationGeneration: 1, callbackGeneration: nil
            )
        ))
        var replacement = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        replacement.task?.cancel()
        replacement.task = nil
        handler.admissionRetryStateByWindowId[windowId] = replacement
        gate.resume(windowInfo)
        await task.value
        XCTAssertEqual(handler.admissionRetryStateByWindowId[windowId]?.generation, replacement.generation)
        XCTAssertNil(controller.workspaceManager.entry(for: token))
    }

    func testDeferredDrainRetainsProtectionAndUsesSpaceStateAfterMetadataReply() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer { handler.cleanup() }
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "deferred metadata query started")
        let windowId = UInt32(token.windowId)
        var topology = SpaceTopology()
        topology.displays = [.init(displayIdentifier: "primary", spaceIds: [1, 2], currentSpaceId: 1)]
        topology.activeSpaceId = 1
        controller.workspaceManager.commitSpaceTopology(topology)
        var queries = 0
        var spaceQueries = 0
        handler.windowInfoProvider = { _ in XCTFail("Main-thread metadata query")
            return nil
        }
        handler.lifecycleQueries.query = { _ in
            queries += 1
            started.fulfill()
            return await gate.wait()
        }
        handler.deferCreatedWindow(windowId)
        handler.drainDeferredCreatedWindows { _ in
            spaceQueries += 1
            return [2]
        }
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        XCTAssertEqual(queries, 0)
        XCTAssertTrue(handler.isCreatedWindowDeferred(windowId))
        await fulfillment(of: [started], timeout: failureBound)
        for _ in 0 ..< 20 { handler.drainDeferredCreatedWindows { _ in [2] } }
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(spaceQueries, 0)
        XCTAssertTrue(handler.lifecycleQueries.pending.isEmpty)
        XCTAssertTrue(handler.isCreatedWindowDeferred(windowId))
        gate.resume(windowInfo)
        await task.value
        XCTAssertEqual(spaceQueries, 1)
        XCTAssertTrue(handler.isCreatedWindowDeferred(windowId))
        XCTAssertNil(controller.workspaceManager.entry(for: token))
    }

    func testMetadataFailureKeepsRetryPendingWithoutAdmittingWindow() async throws {
        enum Failure: Error { case unavailable }
        let controller = WindowAdmissionTestSupport.controller()
        let handler = controller.axEventHandler
        defer { handler.cleanup() }
        let windowId = UInt32(token.windowId)
        handler.windowInfoProvider = { _ in XCTFail("Main-thread metadata query")
            return nil
        }
        handler.lifecycleQueries.query = { _ in throw Failure.unavailable }
        XCTAssertTrue(handler.scheduleAdmissionRetry(
            windowId: windowId, expectedToken: nil, reason: .windowInfoMissing, trigger: .create
        ))
        let previous = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertTrue(handler.dispatchAdmissionRetry(windowId: windowId))
        await handler.lifecycleQueries.task?.value
        let retry = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertEqual(retry.attempt, previous.attempt + 1)
        XCTAssertEqual(retry.reason, .windowInfoMissing)
        XCTAssertEqual(retry.executionPhase, .waiting)
        XCTAssertNil(controller.workspaceManager.entry(for: token))
    }
}
