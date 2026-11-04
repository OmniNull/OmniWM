// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
struct HostedFamilyStateFixture {
    let base: NiriGatherFixture
    let main = WindowToken(pid: getpid(), windowId: 961_001)
    let sheet = WindowToken(pid: getpid(), windowId: 961_002)
    let utility = WindowToken(pid: getpid(), windowId: 961_003)
    let independent = WindowToken(pid: getpid(), windowId: 961_004)
    let minimumSize = CGSize(width: 180, height: 120)
    let frames: [WindowToken: CGRect]

    var manager: WorkspaceManager {
        base.manager
    }

    var family: [WindowToken] {
        [main, sheet, utility]
    }

    var source: WorkspaceDescriptor.ID {
        base.workspace("1")
    }

    var destination: WorkspaceDescriptor.ID {
        base.workspace("2")
    }

    var otherMonitorDestination: WorkspaceDescriptor.ID {
        base.workspace("3")
    }

    var external: WindowToken {
        base.token(1)
    }

    init() throws {
        let first = NiriGatherFixture.monitor(displayId: 96_101)
        let second = NiriGatherFixture.monitor(displayId: 96_102, x: -first.frame.width)
        base = try NiriGatherFixture(
            prefix: "HostedFamilyState", monitors: [first, second],
            workspaces: [
                .init(name: "1", monitor: first), .init(name: "2", monitor: first),
                .init(name: "3", monitor: second)
            ]
        )
        let frameSize = minimumSize
        frames = Dictionary(uniqueKeysWithValues: [main, sheet, utility, independent].enumerated().map { index, token in
            let origin = CGPoint(x: frameSize.width * CGFloat(index), y: frameSize.height)
            return (token, CGRect(origin: origin, size: frameSize))
        })
        let instanceID = UUID()
        try admit(main, role: .main, instanceID: instanceID)
        try admit(sheet, role: .sheet(parent: main, declarationID: "confirm"), instanceID: instanceID)
        try admit(utility, role: .utility(parent: main, declarationID: "inspector"), instanceID: instanceID)
        try admit(independent, role: .main, instanceID: UUID())
        base.add([1], to: source)
        manager.withEngineMutationScope {
            for token in [main, independent] {
                _ = base.engine.addWindow(token: token, to: source, afterSelection: nil)
            }
        }
    }

    func entry(_ token: WindowToken) throws -> WindowState {
        try XCTUnwrap(manager.entry(for: token))
    }

    func hidden(_ token: WindowToken, reason: HiddenReason) throws -> HiddenState {
        let frame = try XCTUnwrap(frames[token])
        let monitor = base.monitors[0]
        return HiddenState(
            proportionalPosition: HiddenState.proportionalPosition(topLeft: frame.topLeftCorner, in: monitor.frame),
            referenceMonitorId: monitor.id, reason: reason
        )
    }

    func gatherRequest() -> NiriGatherRequest {
        let monitor = base.monitors[1]
        return NiriGatherRequest(
            tokens: [main], sourceWorkspaceIds: [main: source], destinationWorkspaceId: otherMonitorDestination,
            geometry: NiriSizingGeometry(
                workingFrame: base.controller.niriWorkingFrame(for: monitor),
                gaps: base.controller.innerGap(for: monitor), orientation: .horizontal
            ), nativeFocusToken: nil
        )
    }

    func close() {
        base.controller.layoutRefreshController.resetState()
        base.controller.surfaceReconciler.cleanup()
        base.controller.axManager.cleanup()
        base.controller.deadlineWheel.stop()
    }

    private func admit(_ token: WindowToken, role: HostedWindowRole, instanceID: UUID) throws {
        let metadata = HostedWindowMetadata(
            appId: "family-state", title: "Family state", minimumSize: minimumSize,
            instanceID: instanceID, role: role
        )
        XCTAssertEqual(manager.addHostedWindow(
            token: token, metadata: metadata, to: source, initialFrame: try XCTUnwrap(frames[token])
        ), token)
    }
}
