// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SummonRightViewportTests: XCTestCase {
    private struct Split {
        let controller: WMController
        let monitor: Monitor
        let targetWorkspaceId: WorkspaceDescriptor.ID
        let left: WindowToken
        let right: WindowToken
        let summoned: WindowToken
    }

    func testSummonFromAnotherWorkspaceBesideTheLeftHalfKeepsBothOnScreen() throws {
        let split = try makeHalfSplit()
        XCTAssertEqual(try onScreen(split), [split.left, split.right])

        try summon(split, beside: split.left)

        XCTAssertEqual(try visibleColumnOrder(split), [split.left, split.summoned, split.right])
        XCTAssertEqual(try onScreen(split), [split.left, split.summoned])
    }

    func testSummonFromAnotherWorkspaceBesideTheRightHalfKeepsBothOnScreen() throws {
        let split = try makeHalfSplit()

        try summon(split, beside: split.right)

        XCTAssertEqual(try visibleColumnOrder(split), [split.left, split.right, split.summoned])
        XCTAssertEqual(try onScreen(split), [split.right, split.summoned])
    }

    func testSummonFromADwindleWorkspaceBesideTheLeftHalfKeepsBothOnScreen() throws {
        let split = try makeHalfSplit(sourceLayout: .dwindle)

        try summon(split, beside: split.left)

        XCTAssertEqual(try visibleColumnOrder(split), [split.left, split.summoned, split.right])
        XCTAssertEqual(try onScreen(split), [split.left, split.summoned])
    }

    func testSummonBesideTheLeftHalfPastAMinimizedColumnKeepsBothOnScreen() throws {
        let split = try makeHalfSplit()
        try addMinimizedColumn(at: 1, to: split)

        try summon(split, beside: split.left)

        XCTAssertEqual(try visibleColumnOrder(split), [split.left, split.summoned, split.right])
        XCTAssertEqual(try onScreen(split), [split.left, split.summoned])
    }

    func testSummonBesideTheLeftHalfCountsOnlyVisibleColumnsBeforeIt() throws {
        let split = try makeHalfSplit()
        try addMinimizedColumn(at: 0, to: split)

        try summon(split, beside: split.left)

        XCTAssertEqual(try visibleColumnOrder(split), [split.left, split.summoned, split.right])
        XCTAssertEqual(try onScreen(split), [split.left, split.summoned])
    }

    private static let monitor = Monitor(
        id: .init(displayId: 79_401),
        displayId: 79_401,
        frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
        hasNotch: false,
        name: "Summon Right Viewport"
    )

    private func makeHalfSplit(sourceLayout: LayoutType = .niri) throws -> Split {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMSummonRightViewport")
        let monitor = Self.monitor
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        let source = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(named: "41", layoutType: sourceLayout, controller: controller)
        )
        let target = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(named: "2", layoutType: .niri, controller: controller)
        )
        controller.niriLayoutHandler.enableNiriLayout()
        controller.dwindleLayoutHandler.enableDwindleLayout()
        controller.motionPolicy.animationsEnabled = false
        let engine = try XCTUnwrap(controller.niriEngine)

        let summoned = WindowToken(pid: 79_402, windowId: 79_502)
        let left = WindowToken(pid: 79_403, windowId: 79_503)
        let right = WindowToken(pid: 79_404, windowId: 79_504)
        for (token, workspaceId) in [(summoned, source), (left, target), (right, target)] {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        manager.withEngineMutationScope {
            if sourceLayout == .dwindle {
                _ = controller.dwindleEngine?.addWindow(token: summoned, to: source, activeWindowFrame: nil)
            } else {
                _ = engine.addWindow(token: summoned, to: source, afterSelection: nil)
            }
            _ = engine.addWindow(token: left, to: target, afterSelection: nil)
            _ = engine.addWindow(token: right, to: target, afterSelection: nil)
        }
        let split = Split(
            controller: controller,
            monitor: monitor,
            targetWorkspaceId: target,
            left: left,
            right: right,
            summoned: summoned
        )
        for token in [right, left] {
            try focus(token, in: split)
            XCTAssertEqual(
                controller.commandHandler.performCommand(.sizing(.setContainerPrimarySpan(.setProportion(50)))),
                .executed
            )
        }
        return split
    }

    private func addMinimizedColumn(at position: Int, to split: Split) throws {
        let token = WindowToken(pid: 79_405, windowId: 79_505)
        let engine = try XCTUnwrap(split.controller.niriEngine)
        let manager = split.controller.workspaceManager
        _ = WindowAdmissionTestSupport.track(token, in: split.targetWorkspaceId, controller: split.controller)
        manager.withEngineMutationScope {
            _ = engine.addWindow(
                token: token,
                to: split.targetWorkspaceId,
                afterSelection: nil,
                placement: .position(position)
            )
        }
        XCTAssertTrue(manager.setWindowMinimized(true, token: token))
    }

    private func focus(_ token: WindowToken, in split: Split) throws {
        let manager = split.controller.workspaceManager
        let node = try XCTUnwrap(split.controller.niriEngine?.findNode(for: token, in: split.targetWorkspaceId))
        _ = manager.focusWorkspace(named: "2")
        var state = manager.niriViewportState(for: split.targetWorkspaceId)
        split.controller.niriLayoutHandler.activateNode(
            node,
            in: split.targetWorkspaceId,
            state: &state,
            options: NodeActivationOptions(layoutRefresh: false, axFocus: false, startAnimation: false)
        )
        manager.withNiriViewportState(for: split.targetWorkspaceId) { $0 = state }
        _ = manager.setManagedFocus(token, in: split.targetWorkspaceId, onMonitor: split.monitor.id)
        _ = manager.confirmManagedFocus(
            token,
            in: split.targetWorkspaceId,
            onMonitor: split.monitor.id,
            activateWorkspaceOnMonitor: true
        )
    }

    private func summon(_ split: Split, beside anchor: WindowToken) throws {
        try focus(anchor, in: split)
        _ = try onScreen(split)
        XCTAssertTrue(split.controller.windowActionHandler.summonWindowRight(
            handle: WindowHandle(id: split.summoned),
            anchorToken: anchor,
            anchorWorkspaceId: split.targetWorkspaceId
        ))
    }

    private func visibleColumnOrder(_ split: Split) throws -> [WindowToken] {
        let engine = try XCTUnwrap(split.controller.niriEngine)
        return engine.projectedColumns(in: split.targetWorkspaceId).flatMap { $0.windows.map(\.token) }
    }

    private func onScreen(_ split: Split) throws -> [WindowToken] {
        let controller = split.controller
        let engine = try XCTUnwrap(controller.niriEngine)
        _ = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [split.targetWorkspaceId])
        }
        let screen = split.monitor.visibleFrame
        return try engine.projectedColumns(in: split.targetWorkspaceId).flatMap(\.windows).filter { window in
            let frame = try XCTUnwrap(window.renderedFrame)
            return frame.minX >= screen.minX && frame.maxX <= screen.maxX
        }.map(\.token)
    }
}
