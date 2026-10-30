// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class LifecycleQueryGate {
    var continuation: CheckedContinuation<WindowServerInfo?, Never>?

    func wait() async -> WindowServerInfo? {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ info: WindowServerInfo? = nil) {
        continuation?.resume(returning: info)
        continuation = nil
    }
}

private final class LifecycleProbeTimeouts: @unchecked Sendable {
    private let lock = NSLock()
    private var timeout: Float = 0
    private var configurations = 0
    private var resets = 0
    private var reads: [Float] = []

    func set(_ timeout: Float) -> (configurations: Int, resets: Int) {
        lock.withLock {
            self.timeout = timeout
            if timeout == 0 { resets += 1 } else { configurations += 1 }
            return (configurations, resets)
        }
    }

    func read() -> Int {
        lock.withLock {
            reads.append(timeout)
            return reads.count
        }
    }

    var observed: [Float] {
        lock.withLock { reads }
    }
}

@MainActor
final class WindowLifecycleQueryTests: XCTestCase {
    private let token = WindowToken(pid: 490_501, windowId: 490_502)

    private func info(for token: WindowToken) -> WindowServerInfo {
        WindowServerInfo(
            id: UInt32(token.windowId), pid: token.pid, level: 0,
            frame: CGRect(x: 10, y: 10, width: 800, height: 600)
        )
    }

    private func cleanup(_ controller: WMController) {
        controller.axEventHandler.cleanup()
        controller.layoutRefreshController.resetState()
    }

    private func track(_ token: WindowToken, controller: WMController) throws -> WorkspaceDescriptor.ID {
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
        controller.layoutRefreshController.resetState()
        return workspace
    }

    private func nativeProbeWorker() -> Thread {
        let worker = Thread {
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            CFRunLoopRun()
        }
        worker.name = "OmniWM-LifecycleProbeTests"
        worker.start()
        return worker
    }

    func testSpaceDestructionRetiresRetryStartedByEarlierQueuedCreate() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        let handler = controller.axEventHandler
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "create query started")
        let windowId = UInt32(token.windowId)
        var queries = 0
        handler.windowInfoProvider = { _ in nil }
        handler.lifecycleQueries.query = { _ in
            queries += 1
            guard queries == 1 else { return nil }
            started.fulfill()
            return await gate.wait()
        }
        handler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [started], timeout: 2)
        handler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
        gate.resume()
        await task.value
        XCTAssertEqual(queries, 2)
        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertNil(handler.pendingCreatePlacementContext(for: Int(windowId)))
    }

    func testSpaceDestructionRetiresRetryWhenCreateReplyArrivesBeforeEvent() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        let handler = controller.axEventHandler
        let windowId = UInt32(token.windowId)
        handler.windowInfoProvider = { _ in nil }
        handler.lifecycleQueries.query = { _ in nil }
        handler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))
        await handler.lifecycleQueries.task?.value
        XCTAssertNotNil(handler.admissionRetryStateByWindowId[windowId])
        handler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
        await handler.lifecycleQueries.task?.value
        XCTAssertNil(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertNil(handler.pendingCreatePlacementContext(for: Int(windowId)))
    }

    func testSpaceDestructionRetiresSameLookupRetryWhilePendingOrActive() async throws {
        for (destructionIsActive, hasAXRef) in [(false, false), (true, false), (false, true), (true, true)] {
            let controller = WindowAdmissionTestSupport.controller()
            defer { cleanup(controller) }
            let handler = controller.axEventHandler
            let lookupGate = LifecycleQueryGate()
            let queryGate = LifecycleQueryGate()
            defer {
                lookupGate.resume()
                queryGate.resume()
            }
            let lookupStarted = expectation(description: "AX identity lookup started")
            let queryStarted = expectation(description: "Lifecycle query suspended")
            let windowId = UInt32(token.windowId)
            let windowInfo = info(for: token)
            var queries = 0
            handler.windowInfoProvider = { _ in nil }
            handler.createdWindowAXRefProvider = { _ in
                lookupStarted.fulfill()
                _ = await lookupGate.wait()
                return hasAXRef ? WindowAdmissionTestSupport.axRef(for: self.token) : nil
            }
            handler.lifecycleQueries.query = { _ in
                queries += 1
                if queries == 1 { return windowInfo }
                if queries == 2 {
                    queryStarted.fulfill()
                    return await queryGate.wait()
                }
                if hasAXRef, queries == 3 { return windowInfo }
                return nil
            }
            handler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))
            await handler.lifecycleQueries.task?.value
            await fulfillment(of: [lookupStarted], timeout: 2)
            let lookupTask = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
            let generation = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.generation)
            if destructionIsActive {
                handler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
            } else {
                handler.handleCGSEvent(.orderChanged(windowId: windowId + 1))
            }
            let lifecycleTask = try XCTUnwrap(handler.lifecycleQueries.task)
            await fulfillment(of: [queryStarted], timeout: 2)
            if !destructionIsActive {
                handler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
            }
            lookupGate.resume()
            await lookupTask.value
            let retry = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
            XCTAssertNotEqual(retry.generation, generation)
            retry.task?.cancel()
            queryGate.resume()
            await lifecycleTask.value
            XCTAssertNil(handler.admissionRetryStateByWindowId[windowId])
            XCTAssertNil(handler.pendingCreatePlacementContext(for: Int(windowId)))
        }
    }

    func testQueuedCreateDestructionPairsRetireEachPredecessorRetry() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        let handler = controller.axEventHandler
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "first create query started")
        let windowId = UInt32(token.windowId)
        var queries = 0
        handler.windowInfoProvider = { _ in nil }
        handler.lifecycleQueries.query = { _ in
            queries += 1
            guard queries == 1 else { return nil }
            started.fulfill()
            return await gate.wait()
        }
        handler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [started], timeout: 2)
        handler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
        handler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))
        handler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
        gate.resume()
        await task.value
        XCTAssertEqual(queries, 4)
        XCTAssertNil(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertNil(handler.pendingCreatePlacementContext(for: Int(windowId)))
    }

    func testSpaceDestructionPreservesRetryReplacedDuringItsQuery() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        let handler = controller.axEventHandler
        let createGate = LifecycleQueryGate()
        let destroyGate = LifecycleQueryGate()
        defer {
            createGate.resume()
            destroyGate.resume()
        }
        let createStarted = expectation(description: "create query started")
        let destroyStarted = expectation(description: "destroy query started")
        let windowId = UInt32(token.windowId)
        var queries = 0
        handler.windowInfoProvider = { _ in nil }
        handler.lifecycleQueries.query = { _ in
            queries += 1
            if queries == 1 {
                createStarted.fulfill()
                return await createGate.wait()
            }
            destroyStarted.fulfill()
            return await destroyGate.wait()
        }
        handler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [createStarted], timeout: 2)
        handler.handleCGSEvent(.destroyed(windowId: windowId, spaceId: 0))
        createGate.resume()
        await fulfillment(of: [destroyStarted], timeout: 2)
        let predecessor = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.generation)
        handler.cancelCreatedWindowRetry(windowId: windowId)
        XCTAssertTrue(handler.scheduleAdmissionRetry(
            windowId: windowId, expectedToken: nil, reason: .windowInfoMissing, trigger: .create
        ))
        var replacement = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId])
        replacement.task?.cancel()
        replacement.task = nil
        handler.admissionRetryStateByWindowId[windowId] = replacement
        XCTAssertNotEqual(predecessor, replacement.generation)
        destroyGate.resume()
        await task.value
        XCTAssertEqual(handler.admissionRetryStateByWindowId[windowId]?.generation, replacement.generation)
        XCTAssertNotNil(handler.pendingCreatePlacementContext(for: Int(windowId)))
    }

    func testCreateReturnsBeforeQueryAndCloseInvalidatesItsReply() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        let handler = controller.axEventHandler
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "native query started")
        var queries = 0
        var axLookups = 0
        handler.windowInfoProvider = { _ in XCTFail("Synchronous query")
            return nil
        }
        handler.createdWindowAXRefProvider = { _ in axLookups += 1
            return nil
        }
        handler.lifecycleQueries.query = { _ in
            queries += 1
            guard queries == 1 else { return nil }
            started.fulfill()
            return await gate.wait()
        }
        let windowId = UInt32(token.windowId)
        handler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        XCTAssertEqual(queries, 0)
        await fulfillment(of: [started], timeout: 2)
        for _ in 0 ..< 20 { handler.handleCGSEvent(.created(windowId: windowId, spaceId: 0)) }
        XCTAssertTrue(handler.lifecycleQueries.pending.isEmpty)
        handler.handleCGSEvent(.closed(windowId: windowId))
        gate.resume(info(for: token))
        await task.value
        XCTAssertEqual(queries, 2)
        XCTAssertEqual(axLookups, 0)
        XCTAssertNil(handler.admissionRetryStateByWindowId[windowId])
        XCTAssertNil(controller.workspaceManager.entry(for: token))
    }

    func testDestructionReusesOneResolvedResultIncludingMissingInfo() async throws {
        for closed in [false, true] {
            let controller = WindowAdmissionTestSupport.controller()
            defer { cleanup(controller) }
            _ = try track(token, controller: controller)
            let handler = controller.axEventHandler
            var queries = 0
            handler.windowInfoProvider = { _ in XCTFail("Repeated synchronous query")
                return nil
            }
            handler.lifecycleQueries.query = { _ in queries += 1
                return nil
            }
            let windowId = UInt32(token.windowId)
            handler.handleCGSEvent(closed ? .closed(windowId: windowId) : .destroyed(windowId: windowId, spaceId: 0))
            XCTAssertNotNil(controller.workspaceManager.entry(for: token))
            await handler.lifecycleQueries.task?.value
            XCTAssertEqual(queries, 1)
            XCTAssertNil(controller.workspaceManager.entry(for: token))
        }
    }

    func testQueuedCloseCannotRetireAnIncarnationAdmittedBeforeItsQueryStarts() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        let workspace = try track(token, controller: controller)
        let handler = controller.axEventHandler
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "unrelated query started")
        handler.lifecycleQueries.query = { windowId in
            guard windowId == 490_999 else { return nil }
            started.fulfill()
            return await gate.wait()
        }
        handler.handleCGSEvent(.orderChanged(windowId: 490_999))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [started], timeout: 2)
        handler.handleCGSEvent(.closed(windowId: UInt32(token.windowId)))
        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
        let replacement = try XCTUnwrap(controller.workspaceManager.handle(for: token))
        gate.resume()
        await task.value
        XCTAssertTrue(controller.workspaceManager.handle(for: token) === replacement)
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
    }

    func testCloseCannotRetireIdentityChangedWhileQueryWasRunning() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        let workspace = try track(token, controller: controller)
        let handler = controller.axEventHandler
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "close query started")
        handler.lifecycleQueries.query = { _ in started.fulfill()
            return await gate.wait()
        }
        handler.handleCGSEvent(.closed(windowId: UInt32(token.windowId)))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [started], timeout: 2)
        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        let replacement = WindowToken(pid: token.pid + 1, windowId: token.windowId)
        _ = WindowAdmissionTestSupport.track(replacement, in: workspace, controller: controller)
        gate.resume()
        await task.value
        XCTAssertNotNil(controller.workspaceManager.entry(for: replacement))
    }

    func testCloseThenCreatePreservesOrderAndCreationPlacement() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        _ = try track(token, controller: controller)
        let nextWorkspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        let handler = controller.axEventHandler
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "close query started")
        let lookup = expectation(description: "later creation reaches AX lookup")
        let lookupGate = LifecycleQueryGate()
        defer { lookupGate.resume() }
        var queries = 0
        let windowInfo = info(for: token)
        let windowId = UInt32(token.windowId)
        handler.lifecycleQueries.query = { _ in
            queries += 1
            guard queries == 1 else { return windowInfo }
            started.fulfill()
            return await gate.wait()
        }
        handler.createdWindowAXRefProvider = { [weak controller, weak handler] _ in
            XCTAssertNil(controller?.workspaceManager.entry(for: self.token))
            XCTAssertEqual(
                handler?.pendingCreatePlacementContext(for: Int(windowId))?.interactionWorkspaceId,
                nextWorkspace
            )
            lookup.fulfill()
            _ = await lookupGate.wait()
            return nil
        }
        handler.handleCGSEvent(.closed(windowId: windowId))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [started], timeout: 2)
        _ = controller.workspaceManager.focusWorkspace(named: "2")
        handler.handleCGSEvent(.created(windowId: windowId, spaceId: 0))
        let context = try XCTUnwrap(handler.pendingCreatePlacementContext(for: Int(windowId)))
        XCTAssertEqual(context.interactionWorkspaceId, nextWorkspace)
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        gate.resume()
        await task.value
        await fulfillment(of: [lookup], timeout: 2)
        let lookupTask = try XCTUnwrap(handler.admissionRetryStateByWindowId[windowId]?.task)
        lookupGate.resume()
        await lookupTask.value
        XCTAssertEqual(queries, 2)
    }

    func testCleanupInvalidatesOutstandingQueryAndQueuedEvents() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        _ = try track(token, controller: controller)
        let handler = controller.axEventHandler
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "query started")
        var queries = 0
        handler.lifecycleQueries.query = { _ in queries += 1
            started.fulfill()
            return await gate.wait()
        }
        handler.handleCGSEvent(.closed(windowId: UInt32(token.windowId)))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [started], timeout: 2)
        handler.handleCGSEvent(.created(windowId: 490_999, spaceId: 0))
        handler.cleanup()
        gate.resume()
        await task.value
        XCTAssertEqual(queries, 1)
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        XCTAssertTrue(handler.lifecycleQueries.pending.isEmpty)
        XCTAssertNil(handler.lifecycleQueries.task)
    }

    func testOrderBurstKeepsOnlyOneFollowupQuery() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        _ = try track(token, controller: controller)
        let handler = controller.axEventHandler
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "order query started")
        var queries = 0
        let windowInfo = info(for: token)
        handler.windowInfoProvider = { _ in XCTFail("Synchronous order query")
            return nil
        }
        handler.lifecycleQueries.query = { _ in
            queries += 1
            guard queries == 1 else { return windowInfo }
            started.fulfill()
            return await gate.wait()
        }
        handler.handleCGSEvent(.orderChanged(windowId: UInt32(token.windowId)))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [started], timeout: 2)
        for _ in 0 ..< 100 { handler.handleCGSEvent(.orderChanged(windowId: UInt32(token.windowId))) }
        XCTAssertEqual(handler.lifecycleQueries.pending.count, 1)
        gate.resume(windowInfo)
        await task.value
        XCTAssertEqual(queries, 2)
    }

    func testFailedCloseQueryDoesNotTurnFailureIntoWindowAbsence() async throws {
        enum QueryFailure: Error { case failed }
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        _ = try track(token, controller: controller)
        let handler = controller.axEventHandler
        handler.lifecycleQueries.query = { _ in throw QueryFailure.failed }
        handler.handleCGSEvent(.closed(windowId: UInt32(token.windowId)))
        await handler.lifecycleQueries.task?.value
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
    }

    func testSpaceDepartureCannotRetireWindowRevealedDuringQuery() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        _ = try track(token, controller: controller)
        controller.workspaceManager.setHiddenState(
            HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .layoutTransient(.left)),
            for: token
        )
        let handler = controller.axEventHandler
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "space departure query started")
        handler.lifecycleQueries.query = { _ in started.fulfill()
            return await gate.wait()
        }
        handler.handleCGSEvent(.destroyed(windowId: UInt32(token.windowId), spaceId: 0))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [started], timeout: 2)
        controller.workspaceManager.setHiddenState(nil, for: token)
        gate.resume()
        await task.value
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
    }

    func testSpaceDestructionRetiresOrderedOutWindowOnlyWhenAXElementIsGone() async throws {
        struct Case {
            let orderedIn: Bool?
            let axInvalid: Bool
            let retired: Bool
            let probed: Bool
        }
        let cases = [
            Case(orderedIn: false, axInvalid: true, retired: true, probed: true),
            Case(orderedIn: false, axInvalid: false, retired: false, probed: true),
            Case(orderedIn: true, axInvalid: true, retired: false, probed: false),
            Case(orderedIn: nil, axInvalid: true, retired: false, probed: false)
        ]
        for testCase in cases {
            let controller = WindowAdmissionTestSupport.controller()
            defer { cleanup(controller) }
            _ = try track(token, controller: controller)
            let handler = controller.axEventHandler
            let retained = WindowServerInfo(
                id: UInt32(token.windowId), pid: token.pid, level: 0,
                frame: CGRect(x: 10, y: 10, width: 800, height: 600), isOrderedIn: testCase.orderedIn
            )
            var probed = false
            handler.lifecycleQueries.query = { _ in retained }
            handler.lifecycleQueries.isAXElementInvalid = { _ in
                probed = true
                return testCase.axInvalid
            }
            handler.handleCGSEvent(.destroyed(windowId: UInt32(token.windowId), spaceId: 0))
            await handler.lifecycleQueries.task?.value
            XCTAssertEqual(probed, testCase.probed, "\(testCase)")
            XCTAssertEqual(controller.workspaceManager.entry(for: token) == nil, testCase.retired, "\(testCase)")
        }
    }

    func testCancelledNativeProbeCannotResetTheNextProbesTimeout() async throws {
        let worker = nativeProbeWorker()
        let releaseFirstRead = DispatchSemaphore(value: 0)
        let releaseSecondRead = DispatchSemaphore(value: 0)
        defer {
            releaseFirstRead.signal()
            releaseSecondRead.signal()
            worker.runInLoopAsync { _ in CFRunLoopStop(CFRunLoopGetCurrent()) }
        }
        let timeouts = LifecycleProbeTimeouts()
        let firstReading = expectation(description: "First native probe suspended")
        let firstReset = expectation(description: "First native probe reset its timeout")
        let secondConfigured = expectation(description: "Second native probe must wait for the worker")
        secondConfigured.isInverted = true
        let setTimeout: @Sendable (AXWindowRef, Float) -> AXError = { _, timeout in
            let counts = timeouts.set(timeout)
            if timeout == 0, counts.resets == 1 { firstReset.fulfill() }
            if timeout > 0, counts.configurations == 2 {
                secondConfigured.fulfill()
                _ = releaseSecondRead.wait(timeout: .now() + 5)
            }
            return .success
        }
        let readRole: @Sendable (AXWindowRef) -> AXError = { _ in
            if timeouts.read() == 1 {
                firstReading.fulfill()
                _ = releaseFirstRead.wait(timeout: .now() + 5)
                return .success
            }
            return .invalidUIElement
        }
        let axRef = WindowAdmissionTestSupport.axRef(for: token)
        let first = Task {
            await AXEventHandler.LifecycleQueries.probeAXElement(
                axRef, on: worker, setTimeout: setTimeout, readRole: readRole
            )
        }
        await fulfillment(of: [firstReading], timeout: 2)
        first.cancel()
        let second = Task {
            await AXEventHandler.LifecycleQueries.probeAXElement(
                axRef, on: worker, setTimeout: setTimeout, readRole: readRole
            )
        }
        await fulfillment(of: [secondConfigured], timeout: 0.1)
        releaseFirstRead.signal()
        await fulfillment(of: [firstReset], timeout: 2)
        releaseSecondRead.signal()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertFalse(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(timeouts.observed, Array(repeating: Float(AXManager.perAppTimeout), count: 2))
    }

    func testTimedOutNativeProbeDoesNotReadWhenItsWorkerBecomesAvailable() async {
        let worker = nativeProbeWorker()
        let releaseWorker = DispatchSemaphore(value: 0)
        defer {
            releaseWorker.signal()
            worker.runInLoopAsync { _ in CFRunLoopStop(CFRunLoopGetCurrent()) }
        }
        let started = expectation(description: "AX worker busy")
        worker.runInLoopAsync { _ in
            started.fulfill()
            _ = releaseWorker.wait(timeout: .now() + 5)
        }
        await fulfillment(of: [started], timeout: 2)
        let timeouts = LifecycleProbeTimeouts()
        let result = await AXEventHandler.LifecycleQueries.probeAXElement(
            WindowAdmissionTestSupport.axRef(for: token), on: worker,
            setTimeout: { _, timeout in
                _ = timeouts.set(timeout)
                return .success
            },
            readRole: { _ in
                _ = timeouts.read()
                return .invalidUIElement
            }
        )
        XCTAssertFalse(result)
        releaseWorker.signal()
        let drained = expectation(description: "AX worker drained")
        worker.runInLoopAsync { _ in drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertTrue(timeouts.observed.isEmpty)
    }

    func testStalledAXProbeDoesNotBlockAnotherApplicationsCloseOrApplyItsLateReply() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        _ = try track(token, controller: controller)
        let other = WindowToken(pid: token.pid + 1, windowId: token.windowId + 1)
        _ = try track(other, controller: controller)
        let handler = controller.axEventHandler
        let retained = WindowServerInfo(
            id: UInt32(token.windowId), pid: token.pid, level: 0,
            frame: CGRect(x: 10, y: 10, width: 800, height: 600), isOrderedIn: false
        )
        var probe: CheckedContinuation<Bool, Never>?
        let probeStarted = expectation(description: "AX probe suspended")
        let otherQueried = expectation(description: "Another application's close was queried")
        let probeReturned = expectation(description: "Late AX probe returned")
        handler.lifecycleQueries.query = { windowId in
            if windowId == UInt32(other.windowId) {
                otherQueried.fulfill()
                return nil
            }
            return retained
        }
        handler.lifecycleQueries.isAXElementInvalid = { _ in
            let invalid = await withCheckedContinuation { continuation in
                probe = continuation
                probeStarted.fulfill()
            }
            probeReturned.fulfill()
            return invalid
        }
        handler.handleCGSEvent(.destroyed(windowId: UInt32(token.windowId), spaceId: 0))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [probeStarted], timeout: 2)
        handler.handleCGSEvent(.closed(windowId: UInt32(other.windowId)))
        await fulfillment(of: [otherQueried], timeout: 2)
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        probe?.resume(returning: true)
        await fulfillment(of: [probeReturned], timeout: 2)
        await task.value
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(controller.workspaceManager.entry(for: other))
    }

    func testCleanupReleasesLifecycleTaskBeforeTheAXProbeReplies() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        _ = try track(token, controller: controller)
        let handler = controller.axEventHandler
        var probe: CheckedContinuation<Bool, Never>?
        let probeStarted = expectation(description: "AX probe suspended")
        let finished = expectation(description: "Cancelled lifecycle task finished")
        handler.lifecycleQueries.query = { _ in
            WindowServerInfo(
                id: UInt32(self.token.windowId), pid: self.token.pid, level: 0,
                frame: CGRect(x: 10, y: 10, width: 800, height: 600), isOrderedIn: false
            )
        }
        handler.lifecycleQueries.isAXElementInvalid = { _ in
            await withCheckedContinuation { continuation in
                probe = continuation
                probeStarted.fulfill()
            }
        }
        handler.handleCGSEvent(.destroyed(windowId: UInt32(token.windowId), spaceId: 0))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [probeStarted], timeout: 2)
        handler.cleanup()
        let completion = Task {
            await task.value
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        probe?.resume(returning: true)
        await completion.value
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
    }

    func testCleanupDuringAXProbeCannotRetireOrderedOutWindow() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        defer { cleanup(controller) }
        _ = try track(token, controller: controller)
        let handler = controller.axEventHandler
        let retained = WindowServerInfo(
            id: UInt32(token.windowId), pid: token.pid, level: 0,
            frame: CGRect(x: 10, y: 10, width: 800, height: 600), isOrderedIn: false
        )
        var probe: CheckedContinuation<Bool, Never>?
        let probeStarted = expectation(description: "AX probe suspended")
        handler.lifecycleQueries.query = { _ in retained }
        handler.lifecycleQueries.isAXElementInvalid = { _ in
            await withCheckedContinuation { continuation in
                probe = continuation
                probeStarted.fulfill()
            }
        }
        handler.handleCGSEvent(.destroyed(windowId: UInt32(token.windowId), spaceId: 0))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [probeStarted], timeout: 2)
        handler.cleanup()
        probe?.resume(returning: true)
        await task.value
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))
    }
}
