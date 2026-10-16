// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellMenuAppTests: XCTestCase {
    func testSelectedManagedAppRemainsTheMenuTargetWithExternalNativeFocus() throws {
        let app = NSRunningApplication.current
        let controller = try selectedController(pid: app.processIdentifier)
        let manager = controller.workspaceManager
        let selected = try XCTUnwrap(manager.selectedManagedToken)
        let info = controller.appInfoCache.info(for: app.processIdentifier)
        XCTAssertTrue(manager.recordExternalFocus(pid: 910_001))
        XCTAssertNil(manager.nativeManagedFocusToken)
        XCTAssertEqual(manager.selectedManagedToken, selected)
        var frontmostReads = 0
        func frontmost() -> NSRunningApplication? {
            frontmostReads += 1
            return nil
        }

        let expected = ShellMenuApp(
            pid: app.processIdentifier,
            name: info?.name ?? "",
            bundle: info?.bundleId ?? ""
        )
        XCTAssertEqual(controller.shellMenuApp(frontmost: frontmost()), expected)
        XCTAssertEqual(controller.shellWorld().menuApp, expected)
        XCTAssertEqual(frontmostReads, 0)
    }

    func testFrontmostFallbackSuppliesOneConsistentIdentityWithoutManagedSelection() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMShellMenuAppTests")
        let app = NSRunningApplication.current
        var frontmostReads = 0
        func frontmost() -> NSRunningApplication? {
            frontmostReads += 1
            return app
        }

        XCTAssertNil(controller.workspaceManager.selectedManagedToken)
        XCTAssertEqual(controller.shellMenuApp(frontmost: frontmost()), ShellMenuApp(
            pid: app.processIdentifier,
            name: app.localizedName ?? "",
            bundle: app.bundleIdentifier ?? ""
        ))
        XCTAssertEqual(frontmostReads, 1)
    }

    func testMissingManagedMetadataDoesNotBorrowFrontmostIdentity() throws {
        let pid = pid_t.max
        XCTAssertNil(NSRunningApplication(processIdentifier: pid))
        let controller = try selectedController(pid: pid)
        var frontmostReads = 0
        func frontmost() -> NSRunningApplication? {
            frontmostReads += 1
            return .current
        }

        XCTAssertEqual(controller.shellMenuApp(frontmost: frontmost()), ShellMenuApp(pid: pid, name: "", bundle: ""))
        XCTAssertFalse(controller.appInfoCache.hasCachedInfo(for: pid))
        XCTAssertEqual(frontmostReads, 0)
    }

    func testNoManagedSelectionAndNoFrontmostAppProducesNoMenuTarget() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMShellMenuAppTests")
        XCTAssertNil(controller.shellMenuApp(frontmost: nil))
    }

    func testMenuAppIdentityChangesInvalidateOnlyItsOwnDataKey() {
        var previous = ShellWidgetData()
        previous.world.app = "Native app"
        previous.world.bundle = "com.example.native"
        previous.world.title = "Native window"
        let identities: [ShellMenuApp?] = [
            ShellMenuApp(pid: 42, name: "Tracked app", bundle: "com.example.tracked"),
            ShellMenuApp(pid: 43, name: "Tracked app", bundle: "com.example.tracked"),
            ShellMenuApp(pid: 43, name: "Renamed app", bundle: "com.example.tracked"),
            ShellMenuApp(pid: 43, name: "Renamed app", bundle: "com.example.renamed"),
            nil
        ]
        for identity in identities {
            var next = previous
            next.world.menuApp = identity
            XCTAssertEqual(next.changedKeys(from: previous), ShellDataKey.menuApp.bit)
            XCTAssertEqual(next.changedKeys(from: next), 0)
            previous = next
        }
    }

    private func selectedController(pid: pid_t) throws -> WMController {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMShellMenuAppTests")
        let manager = controller.workspaceManager
        let workspace = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = WindowToken(pid: pid, windowId: 910_002)
        _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
        XCTAssertTrue(manager.confirmManagedFocus(token, in: workspace, activateWorkspaceOnMonitor: false))
        XCTAssertEqual(manager.selectedManagedToken, token)
        return controller
    }
}
