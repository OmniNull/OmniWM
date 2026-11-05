// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class HostedChildNavigationTests: XCTestCase {
    func testUtilitySelectionRevealsTheParentLayoutAndFocusesTheExactUtility() async throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try HostedChildPresentationFixture(layout: layout, includesSheet: false)
            defer { fixture.close() }
            let other = try await prepareLayout(fixture)
            let controller = fixture.base.controller
            let manager = fixture.base.world
            let utility = try XCTUnwrap(manager.handle(for: fixture.utility.token))
            try await selectOtherLayout(other, fixture: fixture)

            controller.windowActionHandler.prepareOverviewSelection(
                handle: utility,
                workspaceId: fixture.base.workspace
            )
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

            try assertParentSelected(fixture)
            try await selectOtherLayout(other, fixture: fixture)
            fixture.base.management.clearOperations()

            XCTAssertTrue(controller.windowActionHandler.focusWindowFromBar(handle: utility))
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

            try assertParentSelected(fixture)
            XCTAssertEqual(manager.pendingFocusedToken, fixture.utility.token)
            let window = try XCTUnwrap(fixture.base.management.manager
                .windows[fixture.utility.token] as? HostedManagementWindow)
            XCTAssertTrue(window.operations.contains(.focus))
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(try XCTUnwrap(fixture.base.management.manager.windows[fixture.parent.token]).isVisible)
            XCTAssertEqual(manager.workspace(for: fixture.utility.token), manager.workspace(for: fixture.parent.token))
        }
    }

    func testHostedWindowOrderChangeOrdersTheBorderAgain() throws {
        let fixture = try HostedChildPresentationFixture(includesSheet: false)
        defer { fixture.close() }
        let controller = fixture.base.controller
        controller.surfaceReconciler.reconcileNow()
        XCTAssertFalse(controller.surfaceReconciler.forceOrderingOnNextReconcile)

        controller.axEventHandler.handleCGSEvent(
            .orderChanged(windowId: try XCTUnwrap(UInt32(exactly: fixture.utility.token.windowId)))
        )

        XCTAssertTrue(controller.surfaceReconciler.forceOrderingOnNextReconcile)
    }

    func testUtilitySelectionRestoresTheParentAndAnActiveSheetWinsFinalFocus() async throws {
        let fixture = try HostedChildPresentationFixture(includesSheet: false)
        defer { fixture.close() }
        _ = try await prepareLayout(fixture)
        let controller = fixture.base.controller
        let manager = fixture.base.world
        let parent = try XCTUnwrap(fixture.base.management.manager
            .windows[fixture.parent.token] as? HostedManagementWindow)
        let utility = try XCTUnwrap(fixture.base.management.manager
            .windows[fixture.utility.token] as? HostedManagementWindow)
        let utilityHandle = try XCTUnwrap(manager.handle(for: fixture.utility.token))
        parent.miniaturize(nil)
        XCTAssertTrue(parent.isMiniaturized)
        XCTAssertTrue(try XCTUnwrap(manager.entry(for: fixture.parent.token)).observedState.isMinimized)
        XCTAssertTrue(try XCTUnwrap(manager.entry(for: fixture.utility.token)).observedState.isMinimized)
        fixture.base.management.clearOperations()

        XCTAssertTrue(controller.windowActionHandler.focusWindowFromBar(handle: utilityHandle))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertFalse(parent.isMiniaturized)
        XCTAssertFalse(try XCTUnwrap(manager.entry(for: fixture.parent.token)).observedState.isMinimized)
        XCTAssertFalse(try XCTUnwrap(manager.entry(for: fixture.utility.token)).observedState.isMinimized)
        XCTAssertTrue(parent.operations.contains(.restore))
        XCTAssertFalse(utility.operations.contains(.restore))
        XCTAssertEqual(manager.pendingFocusedToken, fixture.utility.token)
        let metadata = try XCTUnwrap(fixture.parent.target.hostedMetadata)
        let sheet = try fixture.base.add(HostedWindowMetadata(
            appId: metadata.appId, title: "Review family changes", minimumSize: metadata.minimumSize,
            icon: metadata.icon, instanceID: metadata.instanceID,
            role: .sheet(parent: fixture.parent.token, declarationID: "review")
        ))
        fixture.base.management.clearOperations()

        XCTAssertTrue(controller.windowActionHandler.focusWindowFromBar(handle: utilityHandle))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertEqual(manager.pendingFocusedToken, sheet.token)
        XCTAssertFalse(utility.operations.contains(.focus))
        let sheetWindow = try XCTUnwrap(fixture.base.management.manager.windows[sheet.token] as? HostedManagementWindow)
        XCTAssertTrue(sheetWindow.operations.contains(.focus))
        sheetWindow.close()
        utility.close()
        fixture.base.management.clearOperations()
        XCTAssertFalse(controller.windowActionHandler.focusWindowFromBar(handle: utilityHandle))
        XCTAssertFalse(parent.operations.contains(.focus))
    }

    private func prepareLayout(_ fixture: HostedChildPresentationFixture) async throws -> WindowState {
        let manager = fixture.base.world
        manager.removeWindow(pid: fixture.external.pid, windowId: fixture.external.windowId)
        let other = try fixture.base.add(fixture.base.timer)
        fixture.base.controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged, affectedWorkspaceIds: [fixture.base.workspace]
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.base.controller)
        switch manager.activeLayoutKind(for: fixture.base.workspace) {
        case .niri:
            break
        case .dwindle:
            let engine = try XCTUnwrap(fixture.base.controller.dwindleEngine)
            manager.withEngineMutationScope(in: fixture.base.workspace) {
                XCTAssertTrue(engine.groupWindow(fixture.parent.token, into: other.token, in: fixture.base.workspace))
            }
        }
        return other
    }

    private func selectOtherLayout(_ other: WindowState, fixture: HostedChildPresentationFixture) async throws {
        let controller = fixture.base.controller
        let manager = fixture.base.world
        let handle = try XCTUnwrap(manager.handle(for: other.token))
        controller.windowActionHandler.prepareOverviewSelection(handle: handle, workspaceId: fixture.base.workspace)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        try fixture.confirmFocus(other)
        switch manager.activeLayoutKind(for: fixture.base.workspace) {
        case .niri:
            let engine = try XCTUnwrap(controller.niriEngine)
            let node = try XCTUnwrap(engine.findNode(for: other.token, in: fixture.base.workspace))
            XCTAssertEqual(manager.niriViewportState(for: fixture.base.workspace).selectedNodeId, node.id)
        case .dwindle:
            let engine = try XCTUnwrap(controller.dwindleEngine)
            XCTAssertEqual(
                engine.tileSnapshot(for: fixture.parent.token, in: fixture.base.workspace)?.activeToken,
                other.token
            )
        }
    }

    private func assertParentSelected(_ fixture: HostedChildPresentationFixture) throws {
        let manager = fixture.base.world
        switch manager.activeLayoutKind(for: fixture.base.workspace) {
        case .niri:
            let engine = try XCTUnwrap(fixture.base.controller.niriEngine)
            let node = try XCTUnwrap(engine.findNode(for: fixture.parent.token, in: fixture.base.workspace))
            XCTAssertEqual(manager.niriViewportState(for: fixture.base.workspace).selectedNodeId, node.id)
        case .dwindle:
            let engine = try XCTUnwrap(fixture.base.controller.dwindleEngine)
            XCTAssertEqual(
                engine.tileSnapshot(for: fixture.parent.token, in: fixture.base.workspace)?.activeToken,
                fixture.parent.token
            )
        }
    }
}
