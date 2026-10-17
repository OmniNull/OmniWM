// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriGatherHandlerTests: XCTestCase {
    private func scheduledRefresh(_ fixture: NiriGatherFixture) -> LayoutRefreshController.ScheduledRefresh? {
        let state = fixture.controller.layoutRefreshController.layoutState
        return state.activeRefresh ?? state.pendingRefresh
    }

    func testGatherParksIntoInactiveDestinationWithOneRelayoutAndNoNavigation() async throws {
        let monitor = NiriGatherFixture.monitor(displayId: 74_101)
        let fixture = try NiriGatherFixture(
            prefix: "OmniWMNiriGatherHandler",
            monitors: [monitor],
            workspaces: [.init(name: "1"), .init(name: "2"), .init(name: "3")]
        )
        let manager = fixture.manager
        let active = fixture.workspace("1")
        let destination = fixture.workspace("3")
        XCTAssertTrue(manager.setActiveWorkspace(active, on: monitor.id))
        fixture.add([1, 11], to: active)
        fixture.add([2], to: fixture.workspace("2"))
        fixture.add([3], to: destination)
        _ = manager.setManagedFocus(fixture.token(11), in: active, onMonitor: monitor.id)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let focusBefore = manager.focusSessionSnapshot

        let refreshController = fixture.controller.layoutRefreshController
        refreshController.beginPerformanceCapture()
        let outcome = fixture.controller.niriLayoutHandler.gatherWindows(
            [1, 2, 3].map(fixture.token),
            into: destination
        )
        let enqueued = refreshController.performanceSnapshot()?.refreshesEnqueued
        let refresh = scheduledRefresh(fixture)
        let repeated = fixture.controller.niriLayoutHandler.gatherWindows(
            [1, 2, 3].map(fixture.token),
            into: destination
        )
        let enqueuedAfterRepeat = refreshController.endPerformanceCapture()?.refreshesEnqueued

        guard case let .gathered(plan) = outcome else { return XCTFail("expected gathered, got \(outcome)") }
        XCTAssertEqual(plan.movedTokens, [1, 2, 3].map(fixture.token))
        XCTAssertEqual(enqueued, 1)
        XCTAssertEqual(refresh?.reason, .layoutCommand)
        XCTAssertEqual(refresh?.affectedWorkspaceIds, [destination, active, fixture.workspace("2")])
        XCTAssertEqual(repeated, .unchanged)
        XCTAssertEqual(enqueuedAfterRepeat, 1)
        XCTAssertEqual(fixture.layout(destination), [[1, 2, 3]])
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, active)
        XCTAssertEqual(manager.focusSessionSnapshot.nativeFocusOwner, focusBefore.nativeFocusOwner)
        XCTAssertEqual(manager.focusSessionSnapshot.selectedManagedToken, focusBefore.selectedManagedToken)
        XCTAssertEqual(manager.focusSessionSnapshot.pendingManagedFocus, focusBefore.pendingManagedFocus)
    }

    func testIneligibleWindowsRefuseTheWholeRequestWithPerWindowReasons() throws {
        let monitor = NiriGatherFixture.monitor(displayId: 74_102)
        let fixture = try NiriGatherFixture(
            prefix: "OmniWMNiriGatherHandler",
            monitors: [monitor],
            workspaces: [.init(name: "1"), .init(name: "2"), .init(name: "3", layoutType: .dwindle)]
        )
        let manager = fixture.manager
        let source = fixture.workspace("1")
        let destination = fixture.workspace("2")
        fixture.add([1, 2, 3, 4, 5, 6, 7, 10], to: source)
        fixture.add([8], to: fixture.workspace("3"))
        XCTAssertTrue(manager.updateScratchpadMembership(fixture.token(2), to: 1, notify: false))
        manager.setAppHidden(true, pid: fixture.token(3).pid, source: .workspaceManager)
        XCTAssertTrue(manager.setWindowMinimized(true, token: fixture.token(4)))
        XCTAssertTrue(manager.setWindowNativeWithdrawn(true, token: fixture.token(5)))
        XCTAssertTrue(manager.setWindowMode(.floating, for: fixture.token(6)))
        manager.setLayoutReason(.nativeFullscreen, for: fixture.token(7))
        manager.withEngineMutationScope {
            fixture.node(10, in: source)?.sizingMode = .fullscreen
        }
        let sequence = manager.worldSeq
        let trace = manager.reconcileTraceDump()
        let layout = fixture.layout(source)

        let refreshController = fixture.controller.layoutRefreshController
        refreshController.beginPerformanceCapture()
        let outcome = fixture.controller.niriLayoutHandler.gatherWindows(
            [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map(fixture.token),
            into: destination
        )
        XCTAssertEqual(refreshController.endPerformanceCapture()?.refreshesEnqueued, 0)

        XCTAssertEqual(outcome, .refused(.windows([
            fixture.token(2): .scratchpad,
            fixture.token(3): .appHidden,
            fixture.token(4): .minimized,
            fixture.token(5): .nativeWithdrawn,
            fixture.token(6): .floating,
            fixture.token(7): .nativeFullscreen,
            fixture.token(8): .unsupportedLayout,
            fixture.token(9): .notFound,
            fixture.token(10): .layoutFullscreen
        ])))
        XCTAssertEqual(manager.worldSeq, sequence)
        XCTAssertEqual(manager.reconcileTraceDump(), trace)
        XCTAssertEqual(fixture.layout(source), layout)
        XCTAssertEqual(manager.workspace(for: fixture.token(1)), source)
    }

    func testInactiveTabsOffViewportAndInactiveWorkspaceWindowsAreEligible() throws {
        let monitor = NiriGatherFixture.monitor(displayId: 74_105)
        let fixture = try NiriGatherFixture(
            prefix: "OmniWMNiriGatherHandler",
            monitors: [monitor],
            workspaces: [.init(name: "1"), .init(name: "2"), .init(name: "3")]
        )
        let manager = fixture.manager
        let active = fixture.workspace("1")
        let parked = fixture.workspace("2")
        XCTAssertTrue(manager.setActiveWorkspace(active, on: monitor.id))
        fixture.add([1, 2, 3], to: active)
        fixture.add([4], to: parked)
        manager.withEngineMutationScope {
            let first = fixture.node(1, in: active)!
            let firstColumn = fixture.engine.findColumn(containing: first, in: active)!
            let secondNode = fixture.node(2, in: active)!
            let secondColumn = fixture.engine.findColumn(containing: secondNode, in: active)!
            fixture.engine.moveWindowToColumn(secondNode, from: secondColumn, to: firstColumn, in: active)
            secondColumn.remove()
            firstColumn.displayMode = .tabbed
            fixture.engine.updateTabbedColumnVisibility(column: firstColumn)
        }
        XCTAssertTrue(manager.isInactiveTabMember(fixture.token(2), in: active))
        manager.setHiddenState(
            HiddenState(proportionalPosition: .zero, referenceMonitorId: monitor.id, reason: .layoutTransient(.right)),
            for: fixture.token(3)
        )
        manager.setHiddenState(
            HiddenState(proportionalPosition: .zero, referenceMonitorId: monitor.id, reason: .workspaceInactive),
            for: fixture.token(4)
        )

        let outcome = fixture.controller.niriLayoutHandler.gatherWindows(
            [2, 3, 4].map(fixture.token),
            into: fixture.workspace("3")
        )

        guard case .gathered = outcome else { return XCTFail("expected gathered, got \(outcome)") }
        XCTAssertEqual(fixture.layout(fixture.workspace("3")), [[2, 3, 4]])
        XCTAssertEqual(fixture.layout(active), [[1]])
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, active)
    }

    func testDestinationRequirementsAndDestinationGeometryDecideTheRequest() throws {
        let tall = NiriGatherFixture.monitor(displayId: 74_103, height: 1_600)
        let short = NiriGatherFixture.monitor(displayId: 74_104, x: 1_200, height: 800)
        let fixture = try NiriGatherFixture(
            prefix: "OmniWMNiriGatherHandler",
            monitors: [tall, short],
            workspaces: [
                .init(name: "1", monitor: tall),
                .init(name: "2", monitor: tall),
                .init(name: "3", monitor: short),
                .init(name: "4", layoutType: .dwindle, monitor: short)
            ]
        )
        let handler = fixture.controller.niriLayoutHandler
        fixture.add([1, 2], to: fixture.workspace("1"), minHeight: 400)
        let tokens = [1, 2].map(fixture.token)

        XCTAssertEqual(handler.gatherWindows(tokens, into: WorkspaceDescriptor.ID()), .refused(.destinationNotFound))
        XCTAssertEqual(handler.gatherWindows(tokens, into: fixture.workspace("4")), .refused(.unsupportedLayout))
        XCTAssertEqual(handler.gatherWindows(tokens, into: fixture.workspace("3")), .refused(.doesNotFit))
        XCTAssertEqual(fixture.layout(fixture.workspace("1")), [[1], [2]])
        guard case .gathered = handler.gatherWindows(tokens, into: fixture.workspace("2")) else {
            return XCTFail("the taller destination fits both windows")
        }
        XCTAssertEqual(fixture.layout(fixture.workspace("2")), [[1, 2]])
    }
}
