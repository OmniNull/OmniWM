// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class OrderedOutWindowRetirementTests: XCTestCase {
    func testExhaustedFocusActivationRescansTheOwningApp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_001), windowId: 913_101),
            pid: 913_001,
            windowId: 913_101,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let request = controller.intentLedger.beginManagedRequest(token: token, workspaceId: workspaceId)
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            requestId: request.requestId
        )
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil

        for _ in 0 ... AXEventHandler.activationRetryLimit {
            controller.axEventHandler.handleActivationFactsResolved(
                ActivationFacts(
                    pid: token.pid,
                    source: .focusedWindowChanged,
                    origin: .retry,
                    observationGeneration: 0,
                    requestedAtSeq: UInt64.max,
                    focusedWindow: nil
                )
            )
        }

        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        let refresh = try XCTUnwrap(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertEqual(refresh.kind, .fullRescan)
        XCTAssertEqual(refresh.rescanScope, .targeted(appPIDs: [token.pid], nativeSpaceIds: []))
    }

    func testFrontmostAppLosingItsFocusedWindowRescansThatApp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_002), windowId: 913_102),
            pid: 913_002,
            windowId: 913_102,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: token.pid,
                source: .focusedWindowChanged,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: UInt64.max,
                focusedWindow: nil
            )
        )

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, token)
        let refresh = try XCTUnwrap(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertEqual(refresh.kind, .fullRescan)
        XCTAssertEqual(refresh.rescanScope, .targeted(appPIDs: [token.pid], nativeSpaceIds: []))
    }

    func testWindowlessForeignAppTakingFrontDoesNotRescanTheFocusedApp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_003), windowId: 913_103),
            pid: 913_003,
            windowId: 913_103,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil
        controller.axEventHandler.previouslyFocusedManagedToken = token

        controller.axEventHandler.handleActivationFactsResolved(
            ActivationFacts(
                pid: 913_903,
                source: .cgsFrontAppChanged,
                origin: .external,
                observationGeneration: 0,
                requestedAtSeq: UInt64.max,
                focusedWindow: nil
            )
        )

        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, token)
        XCTAssertEqual(
            controller.workspaceManager.nativeFocusOwner,
            .external(pid: 913_903, windowId: nil)
        )
        XCTAssertNil(controller.workspaceManager.externalFocusToken)
        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(controller.axEventHandler.previouslyFocusedManagedToken, token)
    }

    func testConcreteExternalFocusRescansBeforeSameManagedWindowReturns() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let managedToken = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(913_004), windowId: 913_104),
            pid: 913_004,
            windowId: 913_104,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                managedToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.hasStartedServices = true
        controller.layoutRefreshController.layoutState.activeRefresh = nil
        controller.axEventHandler.previouslyFocusedManagedToken = managedToken

        let unmanagedToken = WindowToken(pid: 913_904, windowId: 913_194)
        XCTAssertTrue(
            controller.workspaceManager.recordExternalFocus(
                pid: unmanagedToken.pid,
                windowId: unmanagedToken.windowId
            )
        )
        XCTAssertEqual(controller.workspaceManager.selectedManagedToken, managedToken)
        XCTAssertEqual(controller.workspaceManager.externalFocusToken, unmanagedToken)
        XCTAssertTrue(controller.shouldSuppressManagedFocusRecovery)

        controller.axEventHandler.rescanAppThatLostFocus()

        let refresh = try XCTUnwrap(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertEqual(refresh.kind, .fullRescan)
        XCTAssertEqual(
            refresh.rescanScope,
            .targeted(appPIDs: [managedToken.pid], nativeSpaceIds: [])
        )
        XCTAssertNil(controller.axEventHandler.previouslyFocusedManagedToken)

        controller.layoutRefreshController.layoutState.activeRefresh = nil
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                managedToken,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        controller.axEventHandler.rescanAppThatLostFocus()

        XCTAssertNil(controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(controller.axEventHandler.previouslyFocusedManagedToken, managedToken)
    }

    func testWithdrawingHiddenWindowRescansItsAppOnlyWhenOmniWMHidIt() throws {
        let token = WindowToken(pid: 913_005, windowId: 913_105)
        let orderedOut = WindowServerInfo(
            id: UInt32(token.windowId), pid: token.pid, level: 0, frame: .zero, isOrderedIn: false
        )
        for hidden in [false, true] {
            let controller = WindowAdmissionTestSupport.controller()
            let workspaceId = try XCTUnwrap(
                controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
            )
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            controller.layoutRefreshController.resetState()
            if hidden {
                controller.workspaceManager.setHiddenState(
                    HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .workspaceInactive),
                    for: token
                )
            }

            controller.axEventHandler.applyObservedWindowOrdering(orderedOut, token: token)

            XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.isNativeWithdrawn, true)
            let layoutState = controller.layoutRefreshController.layoutState
            let requestedRescan = [layoutState.activeRefresh, layoutState.pendingRefresh].contains {
                $0?.kind == .fullRescan
                    && $0?.rescanScope == .targeted(appPIDs: [token.pid], nativeSpaceIds: [])
            }
            XCTAssertEqual(requestedRescan, hidden)
            controller.layoutRefreshController.resetState()
        }
    }
}
