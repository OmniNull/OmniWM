// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedUtilityNativeMoveTests: XCTestCase {
    private func mouseUp(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
    }

    private func nativeUtility(
        of parent: HostedManagementInstance, fixture: HostedManagementFixture
    ) async throws -> ShellAppNativeWindow {
        fixture.manager.makeWindow = ShellAppWindowManager.makeWindow
        let utility = try await openHostedUtility(parent, fixture: fixture)
        return try XCTUnwrap(utility.window as? ShellAppNativeWindow)
    }

    private func beginNativeMove(of window: NSWindow, fixture: HostedManagementFixture) {
        fixture.manager.windowWillMove(fixture.notification(window, name: NSWindow.willMoveNotification))
    }

    func testUtilityLeavesItsParentOnlyWhileTheNativeMoveRuns() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let utility = try await nativeUtility(of: parent, fixture: fixture)
        XCTAssertTrue(utility.parent === parent.window)

        beginNativeMove(of: utility, fixture: fixture)

        XCTAssertNil(utility.parent)
        XCTAssertFalse(parent.window.childWindows?.contains(utility) == true)

        try utility.sendEvent(mouseUp(in: utility))

        XCTAssertTrue(utility.parent === parent.window)
        XCTAssertTrue(parent.window.childWindows?.contains(utility) == true)
        await ShellWidgetHost.flushRetiredWork()
    }

    func testHidingTheFamilyDuringANativeMoveAttachesTheUtilityFirst() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let utility = try await nativeUtility(of: parent, fixture: fixture)
        beginNativeMove(of: utility, fixture: fixture)
        XCTAssertNil(utility.parent)

        XCTAssertTrue(fixture.manager.setFamilyHidden(true, requestedBy: parent.token))

        XCTAssertTrue(utility.parent === parent.window)
        XCTAssertFalse(parent.window.isVisible)
        await ShellWidgetHost.flushRetiredWork()
    }

    func testAParentSheetStillBlocksADetachedUtilityAndItsMouseUpStillAttaches() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let parent = try fixture.open()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let utility = try await nativeUtility(of: parent, fixture: fixture)
        beginNativeMove(of: utility, fixture: fixture)
        let sheet = try await openHostedSheet(parent, fixture: fixture)
        XCTAssertNil(utility.parent)
        XCTAssertFalse(utility.canBecomeKey)

        try utility.sendEvent(mouseUp(in: utility))

        XCTAssertTrue(utility.parent === parent.window)
        try await closeHostedSheet(sheet, button: "Cancel", parent: parent, fixture: fixture)
        XCTAssertTrue(utility.canBecomeKey)
        await ShellWidgetHost.flushRetiredWork()
    }
}
