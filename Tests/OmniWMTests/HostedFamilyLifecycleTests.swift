// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedFamilyLifecycleTests: XCTestCase {
    func testWorkspaceHidingRetainsNativeAttachmentsAndSharedStateInBothLayouts() async throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try HostedManagementFixture(layout: layout)
            defer { fixture.close() }
            let parent = try fixture.open()
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            let utility = try await openHostedUtility(parent, fixture: fixture)
            let heading = "Retain this family across workspace switches"
            try await editHostedHeading(heading, in: utility, parent: parent)
            let sheet = try await openHostedSheet(parent, fixture: fixture)
            let roots = Set(parent.session.slots.keys)
            fixture.clearOperations()

            XCTAssertTrue(fixture.world.setActiveWorkspace(fixture.sourceOther, on: fixture.sourceMonitor.id))
            fixture.controller.layoutRefreshController.commitWorkspaceTransition(
                affectedWorkspaces: [fixture.source, fixture.sourceOther], reason: .workspaceTransition
            )
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

            XCTAssertFalse(parent.window.isVisible)
            XCTAssertTrue(parent.window.attachedSheet === sheet.window)
            XCTAssertTrue(sheet.window.sheetParent === parent.window)
            XCTAssertTrue(utility.window.parent === parent.window)
            for token in [parent.token, utility.token, sheet.token] {
                XCTAssertEqual(fixture.world.hiddenState(for: token)?.reason, .workspaceInactive)
                XCTAssertFalse(try XCTUnwrap(fixture.manager.slot(for: token)).context.visible)
            }
            for window in [utility.window, sheet.window] {
                XCTAssertFalse(try XCTUnwrap(window as? HostedManagementWindow).operations.contains(.out))
            }
            XCTAssertEqual(Set(parent.session.slots.keys), roots)
            XCTAssertFalse(parent.session.closed)

            XCTAssertTrue(fixture.world.setActiveWorkspace(fixture.source, on: fixture.sourceMonitor.id))
            fixture.controller.layoutRefreshController.commitWorkspaceTransition(
                affectedWorkspaces: [fixture.source, fixture.sourceOther], reason: .workspaceTransition
            )
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

            XCTAssertTrue(parent.window.isVisible)
            XCTAssertTrue(parent.window.attachedSheet === sheet.window)
            XCTAssertTrue(utility.window.parent === parent.window)
            for token in [parent.token, utility.token, sheet.token] {
                XCTAssertNil(fixture.world.hiddenState(for: token))
                XCTAssertTrue(try XCTUnwrap(fixture.manager.slot(for: token)).context.visible)
            }
            XCTAssertEqual(fixture.controller.focusWindow(utility.token)?.token, sheet.token)
            XCTAssertTrue(hostedSheetLabels(parent.session.surface).contains(heading))
            XCTAssertEqual(utility.slot.surface.textInputs.values.first?.text, heading)
            try await closeHostedSheet(sheet, button: "Cancel", parent: parent, fixture: fixture)
            fixture.close()
            await ShellWidgetHost.flushRetiredWork()
        }
    }

    func testParentMinimizeRestoreAndShutdownPreserveThenRetireEachRoot() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let utility = try await openHostedUtility(parent, fixture: fixture)
        let heading = "Retained through family minimization"
        try await editHostedHeading(heading, in: utility, parent: parent)
        let sheet = try await openHostedSheet(parent, fixture: fixture)
        let tokens = Set([parent.token, utility.token, sheet.token])
        let package = parent.session.package
        let roots = Set(parent.session.slots.keys)

        parent.window.miniaturize(nil)

        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        for token in tokens {
            XCTAssertTrue(try XCTUnwrap(fixture.world.entry(for: token)).observedState.isMinimized)
            XCTAssertFalse(try XCTUnwrap(fixture.manager.slot(for: token)).context.visible)
        }
        XCTAssertTrue(parent.window.attachedSheet === sheet.window)
        XCTAssertTrue(utility.window.parent === parent.window)
        XCTAssertEqual(Set(parent.session.slots.keys), roots)
        XCTAssertTrue(fixture.controller.windowActionHandler.focusWindowFromBar(
            handle: try XCTUnwrap(fixture.world.handle(for: utility.token))
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        for token in tokens {
            XCTAssertFalse(try XCTUnwrap(fixture.world.entry(for: token)).observedState.isMinimized)
            XCTAssertTrue(try XCTUnwrap(fixture.manager.slot(for: token)).context.visible)
        }
        XCTAssertFalse(parent.window.isMiniaturized)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, sheet.token)
        XCTAssertTrue(parent.session.package === package)
        XCTAssertTrue(hostedSheetLabels(parent.session.surface).contains(heading))
        var removed: [WindowToken] = []
        fixture.world.onWindowRemoved = { removed.append($0.token) }

        fixture.manager.shutdown()
        fixture.manager.shutdown()

        XCTAssertEqual(Set(removed), tokens)
        XCTAssertEqual(removed.count, tokens.count)
        XCTAssertTrue(parent.session.closed)
        XCTAssertTrue(parent.session.slots.isEmpty)
        XCTAssertTrue(fixture.manager.windows.isEmpty)
        XCTAssertTrue(fixture.manager.runtimes.isEmpty)
        await ShellWidgetHost.flushRetiredWork()
        XCTAssertNil(ShellWidgetHost.retiringTasks[ObjectIdentifier(package)])
    }

    func testManagementStopPreservesAttachmentsAndResumeRebindsTheFloatingFamily() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        try fixture.float(parent)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let utility = try await openHostedUtility(parent, fixture: fixture)
        let heading = "Retained while management is disabled"
        try await editHostedHeading(heading, in: utility, parent: parent)
        let sheet = try await openHostedSheet(parent, fixture: fixture)
        let roots = Set(parent.session.slots.keys)
        let package = parent.session.package
        try fixture.hide(parent)
        fixture.clearOperations()

        fixture.controller.serviceLifecycleManager.stopServices(retainingAXWorkers: false)

        XCTAssertFalse(fixture.controller.hasStartedServices)
        XCTAssertTrue(parent.window.isVisible)
        XCTAssertTrue(parent.window.attachedSheet === sheet.window)
        XCTAssertTrue(utility.window.parent === parent.window)
        for token in [parent.token, utility.token, sheet.token] {
            XCTAssertNil(fixture.world.hiddenState(for: token))
            XCTAssertTrue(try XCTUnwrap(fixture.manager.slot(for: token)).context.visible)
        }
        let nativeFrame = fixture.centeredFrame(on: fixture.destinationMonitor)
        fixture.moveNative(parent, to: nativeFrame)
        XCTAssertEqual(fixture.world.workspace(for: parent.token), fixture.source)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertEqual(fixture.activationCount, 0)
        fixture.controller.hasStartedServices = true

        fixture.manager.reconcileManagementResume()

        for token in [parent.token, utility.token, sheet.token] {
            XCTAssertEqual(fixture.world.workspace(for: token), fixture.destination)
            XCTAssertEqual(
                fixture.world.entry(for: token)?.observedState.frame,
                fixture.manager.windows[token]?.frame
            )
        }
        XCTAssertEqual(Set(parent.session.slots.keys), roots)
        XCTAssertTrue(parent.session.package === package)
        XCTAssertFalse(parent.session.closed)
        XCTAssertTrue(parent.window.attachedSheet === sheet.window)
        XCTAssertTrue(utility.window.parent === parent.window)
        XCTAssertTrue(hostedSheetLabels(parent.session.surface).contains(heading))
        XCTAssertEqual(utility.slot.surface.textInputs.values.first?.text, heading)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testMainWorkspaceAndMonitorMovesCarryNativeChildrenAndClampUtilities() async throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try HostedManagementFixture(layout: layout)
            defer { fixture.close() }
            let parent = try fixture.open()
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            let utility = try await openHostedUtility(parent, fixture: fixture)
            let sheet = try await openHostedSheet(parent, fixture: fixture)
            let handle = try XCTUnwrap(fixture.world.handle(for: parent.token))
            let roots = Set(parent.session.slots.keys)
            guard case .changed = fixture.controller.workspaceNavigationHandler.commitWindowMove(
                handle: handle, toWorkspaceId: fixture.sourceOther
            ) else { return XCTFail("The main window must move to the requested workspace") }
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            for token in [parent.token, utility.token, sheet.token] {
                XCTAssertEqual(fixture.world.workspace(for: token), fixture.sourceOther)
            }
            XCTAssertTrue(parent.window.attachedSheet === sheet.window)
            XCTAssertTrue(utility.window.parent === parent.window)
            guard case let .changed(mutation) = fixture.controller.workspaceNavigationHandler.moveWindowToMonitor(
                handle: handle, direction: .left
            ) else { return XCTFail("The main window must carry its family to the adjacent monitor") }
            fixture.controller.workspaceNavigationHandler.finishWorkspaceMove(mutation, focusPolicy: .alwaysFollow)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            for token in [parent.token, utility.token, sheet.token] {
                XCTAssertEqual(fixture.world.workspace(for: token), fixture.destination)
                XCTAssertNotNil(fixture.manager.windows[token])
            }
            XCTAssertTrue(fixture.destinationMonitor.visibleFrame.contains(utility.window.frame))
            XCTAssertTrue(parent.window.attachedSheet === sheet.window)
            XCTAssertTrue(utility.window.parent === parent.window)
            XCTAssertEqual(Set(parent.session.slots.keys), roots)
            XCTAssertEqual(fixture.world.windowMode(for: utility.token), .floating)
            XCTAssertEqual(fixture.world.windowMode(for: sheet.token), .floating)
            fixture.close()
            await ShellWidgetHost.flushRetiredWork()
        }
    }
}
