// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class RuntimeInvalidationClassificationTests: XCTestCase {
    func testLifecycleAndEnvironmentEventsKeepTheirUnconditionalInvalidation() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "RuntimeInvalidationClassification")
        defer { controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let token = WindowToken(pid: getpid(), windowId: window.windowNumber)
        let workspace = WorkspaceDescriptor.ID()
        let events: [WMEvent] = [
            .activeSpaceChanged(source: .service),
            .appVisibilityInvalidated(pid: token.pid, affectedWorkspaceIds: [workspace], source: .service),
            .floatingStateChanged(token: token, workspaceId: workspace, state: nil, source: .service),
            .hiddenApplicationsChanged(pids: [token.pid], affectedWorkspaceIds: [workspace], source: .service),
            .windowMinimizedChanged(token: token, workspaceId: workspace, minimized: true, source: .service),
            .windowNativeWithdrawalChanged(token: token, workspaceId: workspace, withdrawn: true, source: .service),
            .manualLayoutOverrideChanged(token: token, workspaceId: workspace, layoutOverride: nil, source: .service),
            .systemSleep(source: .service),
            .systemWake(source: .service),
            .topologyChanged(displays: [], source: .service)
        ]

        for event in events {
            XCTAssertTrue(event.requiresRuntimeInvalidation, event.summary)
            XCTAssertTrue(controller.workspaceManager.eventRequiresRuntimeInvalidation(event), event.summary)
        }
    }

    func testGeometryAndPlanDrivenEventsDoNotForceAnAdditionalInvalidation() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "RuntimeInvalidationGeometryClassification")
        defer { controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let token = WindowToken(pid: getpid(), windowId: window.windowNumber)
        let workspace = WorkspaceDescriptor.ID()
        let events: [WMEvent] = [
            .hostedWindowGeometryObserved(
                token: token, workspaceId: workspace, monitorId: nil, frame: window.frame, source: .service
            ),
            .floatingGeometryUpdated(
                token: token, workspaceId: workspace, referenceMonitorId: nil, frame: window.frame,
                normalizedOrigin: nil, restoreToFloating: false, source: .service
            ),
            .topLevelInventoryObserved(tokens: [token], source: .service),
            .windowRemoved(token: token, workspaceId: workspace, source: .service),
            .viewportForgotten(workspaceIds: [workspace], source: .service)
        ]

        for event in events {
            XCTAssertFalse(event.requiresRuntimeInvalidation, event.summary)
            XCTAssertFalse(controller.workspaceManager.eventRequiresRuntimeInvalidation(event), event.summary)
        }
    }
}
