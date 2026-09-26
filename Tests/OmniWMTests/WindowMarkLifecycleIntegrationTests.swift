// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowMarkLifecycleIntegrationTests: XCTestCase {
    func testHiddenLiveWindowKeepsItsMarkAndRetirementClearsIt() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMWindowMarkLifecycle")
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(named: "76", layoutType: .niri, controller: controller)
        )
        let token = WindowToken(pid: 76_001, windowId: 76_101)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        XCTAssertEqual(controller.windowMarkRegistry.set("terminal", for: token), .inserted)

        _ = controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .ax)
        XCTAssertEqual(controller.windowMarkRegistry.lookup("terminal"), .found(token))
        XCTAssertEqual(controller.windowMarkRegistry.marks.map(\.name), ["terminal"])

        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        controller.axEventHandler.retireManagedWindowFromAuthoritativeRescan(entry)

        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertEqual(controller.windowMarkRegistry.lookup("terminal"), .unknown)
        XCTAssertTrue(controller.windowMarkRegistry.marks.isEmpty)
    }

    func testManagedReplacementRekeysMarkToReplacementToken() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMWindowMarkRebind")
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(named: "77", layoutType: .niri, controller: controller)
        )
        let oldToken = WindowToken(pid: 76_011, windowId: 76_111)
        let newToken = WindowToken(pid: 76_011, windowId: 76_112)
        _ = WindowAdmissionTestSupport.track(oldToken, in: workspaceId, controller: controller)
        XCTAssertEqual(controller.windowMarkRegistry.set("editor", for: oldToken), .inserted)
        let metadata = ManagedReplacementMetadata(
            bundleId: "com.example.editor",
            workspaceId: workspaceId,
            mode: .tiling,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: nil
        )

        let replacement = controller.axEventHandler.commitManagedWindowIdentityRebind(
            from: oldToken,
            to: newToken,
            axRef: WindowAdmissionTestSupport.axRef(for: newToken),
            managedReplacementMetadata: metadata
        )

        XCTAssertEqual(replacement?.token, newToken)
        XCTAssertEqual(controller.windowMarkRegistry.lookup("editor"), .found(newToken))
        XCTAssertTrue(controller.windowMarkRegistry.names(for: oldToken).isEmpty)
        XCTAssertEqual(controller.windowMarkRegistry.names(for: newToken), ["editor"])
    }
}
