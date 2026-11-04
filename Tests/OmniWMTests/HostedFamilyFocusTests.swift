// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedFamilyFocusTests: XCTestCase {
    func testFamilyAssignmentAndGatherRetargetTheExactChildRequestBeforeNativeConfirmation() async throws {
        for gather in [false, true] {
            let fixture = try HostedManagementFixture(layout: .niri)
            defer { fixture.close() }
            let parent = try fixture.open()
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            let utility = try await openHostedUtility(parent, fixture: fixture)
            let request = try XCTUnwrap(fixture.controller.focusWindow(utility.token))
            let monitor = fixture.destinationMonitor
            if gather {
                let gatherRequest = NiriGatherRequest(
                    tokens: [parent.token], sourceWorkspaceIds: [parent.token: fixture.source],
                    destinationWorkspaceId: fixture.destination,
                    geometry: NiriSizingGeometry(
                        workingFrame: fixture.controller.niriWorkingFrame(for: monitor),
                        gaps: fixture.controller.innerGap(for: monitor), orientation: monitor.autoOrientation
                    ), nativeFocusToken: utility.token
                )
                guard case let .ready(plan) = fixture.world.planNiriGather(gatherRequest) else {
                    return XCTFail("The main window is eligible for gathering")
                }
                XCTAssertTrue(fixture.world.commitNiriGather(plan))
            } else {
                fixture.world.setWorkspace(for: parent.token, to: fixture.destination)
            }
            let retargeted = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
            XCTAssertEqual(retargeted.requestId, request.requestId)
            XCTAssertEqual(retargeted.token, utility.token)
            XCTAssertEqual(retargeted.workspaceId, fixture.destination)
            XCTAssertEqual(fixture.world.pendingFocusedToken, utility.token)
            XCTAssertEqual(fixture.world.pendingFocusedWorkspaceId, fixture.destination)

            fixture.manager.windowDidBecomeKey(fixture.notification(
                utility.window, name: NSWindow.didBecomeKeyNotification
            ))

            XCTAssertEqual(fixture.world.nativeManagedFocusToken, utility.token)
            fixture.close()
            await ShellWidgetHost.flushRetiredWork()
        }
    }

    func testFamilyMoveLeavesAnIndependentNewerFocusRequestUntouched() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        let independent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        _ = try await openHostedUtility(parent, fixture: fixture)
        let request = try XCTUnwrap(fixture.controller.focusWindow(independent.token))

        fixture.world.setWorkspace(for: parent.token, to: fixture.destination)

        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest, request)
        XCTAssertEqual(fixture.world.pendingFocusedToken, independent.token)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testNativeUtilityRejectsMiniaturizeFullscreenAndKeyEligibilityWhileParentHasSheet() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let window = ShellAppWindowManager.makeWindow(fixture.definition)
        defer { parent.window.removeChildWindow(window)
            window.close()
        }
        parent.window.addChildWindow(window, ordered: .above)
        XCTAssertTrue(window.parent === parent.window)
        XCTAssertTrue(window.canBecomeKey)

        window.miniaturize(nil)
        window.toggleFullScreen(nil)

        XCTAssertFalse(window.isMiniaturized)
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        let sheet = try await openHostedSheet(parent, fixture: fixture)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        try await closeHostedSheet(sheet, button: "Cancel", parent: parent, fixture: fixture)
        XCTAssertTrue(window.canBecomeKey)
        parent.window.removeChildWindow(window)
        window.close()
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }
}
