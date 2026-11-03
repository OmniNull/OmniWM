// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class OverlappingWorkspaceMoveFocusCancellationTests: XCTestCase {
    func testQueuedMoveCannotReplaceANewerManagedFocusRequest() async throws {
        let fixture = try HostedManagementFixture(layout: .niri, follows: false)
        defer { fixture.close() }
        let moving = try fixture.open()
        let sibling = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        try fixture.select(moving)
        fixture.controller.workspaceNavigationHandler.moveFocusedWindow(
            toRawWorkspaceID: try XCTUnwrap(fixture.world.descriptor(for: fixture.sourceOther)?.name)
        )
        XCTAssertNotNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        let newer = try XCTUnwrap(fixture.controller.focusWindow(sibling.token))
        let intent = fixture.controller.intentLedger.newestFocusIntentId()

        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.intentLedger.newestFocusIntentId(), intent)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.requestId, newer.requestId)
        XCTAssertEqual(fixture.world.pendingFocusedToken, sibling.token)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }

    func testQueuedMoveCannotReclaimNewerExternalFocus() async throws {
        let fixture = try HostedManagementFixture(layout: .niri, follows: false)
        defer { fixture.close() }
        let moving = try fixture.open()
        _ = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        try fixture.select(moving)
        fixture.controller.workspaceNavigationHandler.moveFocusedWindow(
            toRawWorkspaceID: try XCTUnwrap(fixture.world.descriptor(for: fixture.sourceOther)?.name)
        )
        XCTAssertNotNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        let intent = fixture.controller.intentLedger.newestFocusIntentId()
        XCTAssertTrue(fixture.world.recordExternalFocus())

        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.intentLedger.newestFocusIntentId(), intent)
        XCTAssertTrue(fixture.world.nativeFocusOwner.isExternal)
        XCTAssertNil(fixture.world.pendingFocusedToken)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }
}
