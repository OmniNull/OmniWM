// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceSwitchParkOrderingTests: XCTestCase {
    private let displayId: CGDirectDisplayID = 818
    private let outgoingPid: pid_t = 818_001
    private let outgoingWindowId = 818_101
    private let incomingPid: pid_t = 818_002
    private let incomingWindowId = 818_102

    func testOutgoingParkWaitsForIncomingFrameWrite() throws {
        let staged = try stageWorkspaceSwitch()

        staged.controller.axManager.handleFrameApplyResults([
            WindowAdmissionTestSupport.successfulFrameResult(request: staged.incomingWrite)
        ])

        XCTAssertNil(staged.controller.axManager.pendingParkFrameRequest(for: staged.outgoing.windowId))
    }

    func testOutgoingParkKeepsWaitingWhileIncomingWriteRetries() throws {
        let staged = try stageWorkspaceSwitch()

        staged.controller.axManager.handleFrameApplyResults([
            WindowAdmissionTestSupport.verificationMismatchFrameResult(
                request: staged.incomingWrite,
                observed: staged.incomingParkedFrame
            )
        ])

        XCTAssertNotNil(staged.controller.axManager.pendingParkFrameRequest(for: staged.outgoing.windowId))
    }

    func testTitleChangePreservesPendingIncomingFrameWrite() throws {
        let staged = try stageWorkspaceSwitch()
        let controller = staged.controller
        let write = staged.incomingWrite
        let incoming = WindowToken(pid: write.pid, windowId: write.windowId)
        let newTitle = staged.incomingTitle + " renamed"
        XCTAssertEqual(
            controller.workspaceManager.managedReplacementMetadata(for: incoming)?.title,
            staged.incomingTitle
        )
        controller.axEventHandler.windowTitleProvider = { _ in newTitle }

        controller.axEventHandler.handleWindowTitleChanged(windowId: UInt32(write.windowId), pid: write.pid)

        XCTAssertEqual(controller.workspaceManager.managedReplacementMetadata(for: incoming)?.title, newTitle)
        XCTAssertEqual(controller.axManager.pendingFrameWrite(for: write.windowId), staged.incomingFrame)
        XCTAssertNotNil(controller.axManager.pendingParkFrameRequest(for: staged.outgoing.windowId))

        controller.axManager.handleFrameApplyResults([WindowAdmissionTestSupport.successfulFrameResult(request: write)])

        XCTAssertEqual(controller.axManager.lastAppliedFrame(for: write.windowId), staged.incomingFrame)
        XCTAssertNil(controller.axManager.pendingParkFrameRequest(for: staged.outgoing.windowId))
    }

    private struct StagedSwitch {
        let controller: WMController
        let outgoing: WindowToken
        let incomingWrite: AXFrameApplicationRequest
        let incomingFrame: CGRect
        let incomingTitle: String
        let incomingParkedFrame: CGRect
    }

    private func stageWorkspaceSwitch() throws -> StagedSwitch {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMWorkspaceSwitchParkOrderingTests")
        let monitor = Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410),
            hasNotch: false,
            name: "ParkOrdering"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let outgoingWorkspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let incomingWorkspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")

        let outgoingRef = AXWindowRef(element: AXUIElementCreateApplication(outgoingPid), windowId: outgoingWindowId)
        let outgoing = controller.workspaceManager.addWindow(
            outgoingRef, pid: outgoingPid, windowId: outgoingWindowId, to: outgoingWorkspace
        )
        let incomingTitle = "Original title"
        let incomingRef = AXWindowRef(element: AXUIElementCreateApplication(incomingPid), windowId: incomingWindowId)
        _ = controller.workspaceManager.addWindow(
            incomingRef, pid: incomingPid, windowId: incomingWindowId, to: incomingWorkspace,
            managedReplacementMetadata: .init(workspaceId: incomingWorkspace, mode: .tiling, title: incomingTitle)
        )
        let onscreenFrame = CGRect(x: 100, y: 16, width: 1200, height: 900)
        controller.layoutRefreshController.fastFrameProvider = { _, _ in onscreenFrame }

        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(incomingWorkspace, on: monitor.id))
        let incomingWrite = try XCTUnwrap(controller.axManager.stageFrameWrite(
            for: AXFrameApplicationTarget(pid: incomingPid, window: incomingRef, frame: onscreenFrame)
        ))
        controller.layoutRefreshController.hideInactiveWorkspacesSync()
        let parkedOrigin = try XCTUnwrap(controller.layoutRefreshController.liveFrameHideOrigin(
            for: onscreenFrame,
            monitor: monitor,
            side: controller.layoutRefreshController.preferredHideSide(for: monitor),
            reason: .workspaceInactive
        ))

        XCTAssertEqual(controller.workspaceManager.hiddenState(for: outgoing)?.workspaceInactive, true)
        XCTAssertNotNil(controller.axManager.pendingParkFrameRequest(for: outgoing.windowId))
        return StagedSwitch(
            controller: controller,
            outgoing: outgoing,
            incomingWrite: incomingWrite,
            incomingFrame: onscreenFrame,
            incomingTitle: incomingTitle,
            incomingParkedFrame: CGRect(origin: parkedOrigin, size: onscreenFrame.size)
        )
    }
}
