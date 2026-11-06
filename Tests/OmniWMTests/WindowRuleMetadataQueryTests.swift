// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowRuleMetadataQueryTests: XCTestCase {
    private let tokens = [
        WindowToken(pid: 491_010, windowId: 491_011),
        WindowToken(pid: 491_010, windowId: 491_012)
    ]

    private func controller() throws -> WMController {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        for token in tokens {
            controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token), pid: token.pid, windowId: token.windowId,
                to: workspaceId, mode: .floating, ruleEffects: .init(minWidth: 640)
            )
        }
        controller.axEventHandler.windowInfoProvider = { _ in
            XCTFail("Batch evidence fell back to a synchronous query")
            return nil
        }
        return controller
    }

    private func cleanup(_ controller: WMController) {
        controller.axEventHandler.cleanup()
        controller.layoutRefreshController.resetState()
        controller.axManager.cleanup()
    }

    func testSuspendedBatchLeavesMainAvailableAndCancellationRejectsReply() async throws {
        let controller = try controller()
        defer { cleanup(controller) }
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "batch query started")
        var queries = 0
        controller.axEventHandler.windowInfoBatchProvider = { ids in
            queries += 1
            XCTAssertEqual(ids, Set(self.tokens.map { UInt32($0.windowId) }))
            started.fulfill()
            _ = await gate.wait()
            return [:]
        }
        let task = Task { await controller.reevaluateWindowRules(for: Set(tokens.map { .window($0) })) }
        await fulfillment(of: [started], timeout: failureBound)
        XCTAssertEqual(queries, 1)
        XCTAssertNotNil(controller.workspaceManager.entry(for: tokens[0]))
        task.cancel()
        gate.resume()
        let outcome = await task.value
        XCTAssertTrue(outcome.stale)
        XCTAssertFalse(outcome.evaluatedAnyWindow)
        XCTAssertFalse(outcome.relayoutNeeded)
    }

    func testSingleWindowSuspendedQueryLeavesMainAvailableAndCancellationRejectsReply() async throws {
        let controller = try controller()
        defer { cleanup(controller) }
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "single-window query started")
        var queries = 0
        controller.axEventHandler.windowInfoBatchProvider = { ids in
            queries += 1
            XCTAssertEqual(ids, [UInt32(self.tokens[0].windowId)])
            started.fulfill()
            _ = await gate.wait()
            return [:]
        }
        let task = Task { await controller.reevaluateWindowRules(for: [.window(tokens[0])]) }
        await fulfillment(of: [started], timeout: failureBound)
        XCTAssertEqual(queries, 1)
        XCTAssertNotNil(controller.workspaceManager.entry(for: tokens[0]))
        task.cancel()
        gate.resume()
        let outcome = await task.value
        XCTAssertTrue(outcome.stale)
        XCTAssertFalse(outcome.evaluatedAnyWindow)
        XCTAssertFalse(outcome.relayoutNeeded)
    }

    func testSingleWindowFailedQueryPreservesMetadataWithoutSynchronousFallback() async throws {
        for throwsError in [false, true] {
            let controller = try controller()
            defer { cleanup(controller) }
            var queries = 0
            controller.axEventHandler.windowInfoBatchProvider = { ids in
                queries += 1
                XCTAssertEqual(ids, [UInt32(self.tokens[0].windowId)])
                if throwsError { throw AXEventHandler.LifecycleQueryError.unavailable }
                return nil
            }
            let outcome = await controller.reevaluateWindowRules(for: [.window(tokens[0])])
            XCTAssertEqual(queries, 1)
            XCTAssertFalse(outcome.stale)
            XCTAssertTrue(outcome.evaluatedAnyWindow)
            XCTAssertEqual(controller.workspaceManager.entry(for: tokens[0])?.mode, .floating)
            XCTAssertEqual(controller.workspaceManager.entry(for: tokens[0])?.ruleEffects.minWidth, 640)
        }
    }

    func testWindowReplacementInvalidatesSuspendedBatchBeforeEvaluation() async throws {
        let controller = try controller()
        defer { cleanup(controller) }
        let manager = controller.workspaceManager
        let originalHandle = try XCTUnwrap(manager.handle(for: tokens[0]))
        let workspaceId = try XCTUnwrap(manager.workspace(for: tokens[0]))
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "batch query started")
        controller.axEventHandler.windowInfoBatchProvider = { _ in
            started.fulfill()
            _ = await gate.wait()
            return [:]
        }
        let task = Task { await controller.reevaluateWindowRules(for: Set(tokens.map { .window($0) })) }
        await fulfillment(of: [started], timeout: failureBound)
        manager.removeWindow(pid: tokens[0].pid, windowId: tokens[0].windowId)
        manager.addWindow(
            WindowAdmissionTestSupport.axRef(for: tokens[0]), pid: tokens[0].pid, windowId: tokens[0].windowId,
            to: workspaceId, mode: .floating, ruleEffects: .init(minWidth: 920)
        )
        XCTAssertFalse(manager.handle(for: tokens[0]) === originalHandle)
        gate.resume()
        let outcome = await task.value
        XCTAssertTrue(outcome.stale)
        XCTAssertFalse(outcome.evaluatedAnyWindow)
        XCTAssertEqual(manager.entry(for: tokens[0])?.ruleEffects.minWidth, 920)
    }

    func testFailedBatchPreservesManagedMetadataWithoutSynchronousFallback() async throws {
        for throwsError in [false, true] {
            let controller = try controller()
            defer { cleanup(controller) }
            controller.axEventHandler.windowInfoBatchProvider = { _ in
                if throwsError { throw AXEventHandler.LifecycleQueryError.unavailable }
                return nil
            }
            let outcome = await controller.reevaluateWindowRules(for: Set(tokens.map { .window($0) }))
            XCTAssertFalse(outcome.stale)
            XCTAssertTrue(outcome.evaluatedAnyWindow)
            for token in tokens {
                let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
                XCTAssertEqual(entry.mode, .floating)
                XCTAssertEqual(entry.ruleEffects.minWidth, 640)
            }
        }
    }
}
