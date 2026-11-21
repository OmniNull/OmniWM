// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class ClickFocusWithoutScrollingTests: XCTestCase {
    @MainActor private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let nodes: [NiriWindow]

        var targetIndex: Int {
            nodes.count - 1
        }

        var target: NiriWindow {
            nodes[targetIndex]
        }

        var state: ViewportState {
            controller.workspaceManager.niriViewportState(for: workspaceId)
        }

        func viewOrigin(of state: ViewportState) throws -> CGFloat {
            let engine = try XCTUnwrap(controller.niriEngine)
            return state.viewPosPixels(columns: engine.columns(in: workspaceId), gap: controller.innerGap(for: monitor))
        }

        func columnIndex(of node: NiriWindow) throws -> Int {
            let engine = try XCTUnwrap(controller.niriEngine)
            let column = try XCTUnwrap(engine.column(of: node))
            return try XCTUnwrap(engine.columnIndex(of: column, in: workspaceId))
        }

        func isFullyVisible(_ node: NiriWindow, in state: ViewportState) throws -> Bool {
            let engine = try XCTUnwrap(controller.niriEngine)
            let columns = engine.columns(in: workspaceId)
            let index = try columnIndex(of: node)
            let start = state.containerPosition(
                at: index, containers: columns, gap: controller.innerGap(for: monitor), sizeKeyPath: \.cachedWidth
            )
            let origin = try viewOrigin(of: state)
            let visibleWidth = controller.niriWorkingFrame(for: monitor).width
            return start >= origin && start + columns[index].cachedWidth <= origin + visibleWidth
        }

        func activateTarget(afterClick: Bool) throws {
            if afterClick {
                controller.axEventHandler.noteMouseFocusIntent(token: target.token)
            }
            let entry = try XCTUnwrap(controller.workspaceManager.entry(for: target.token))
            controller.axEventHandler.handleManagedAppActivation(
                entry: entry,
                isWorkspaceActive: true,
                appFullscreen: false,
                source: .focusedWindowChanged,
                origin: .external
            )
        }

        func relayout() throws -> ViewportState {
            let plans = controller.workspaceManager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
            }
            let plan = try XCTUnwrap(plans.first { $0.workspaceId == workspaceId })
            _ = controller.workspaceManager.applySessionPatch(plan.sessionPatch)
            return state
        }

        func scrollToStart() {
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                state.activeColumnIndex = 0
                state.jumpOffset(to: 0)
            }
        }

        func scrollWheelOneColumnBack() {
            controller.mouseEventHandler.handleScrollWheelFromTap(MouseScrollIntake(
                location: monitor.frame.center, deltaX: -niriWheelScrollTickAmount, deltaY: 0, momentumPhase: 0,
                phase: 0,
                modifiersRawValue: controller.settings.gestures.scrollModifierKey.cgEventFlag.rawValue
            ))
        }
    }

    func testClickScrollsWindowIntoViewByDefault() throws {
        try withFixture(clickFocusWithoutScrolling: false) { fixture in
            try fixture.activateTarget(afterClick: true)
            XCTAssertEqual(fixture.state.selectedNodeId, fixture.target.id)
            XCTAssertTrue(try fixture.isFullyVisible(fixture.target, in: fixture.relayout()))
        }
    }

    func testClickKeepsViewportAndMovesAnchorToClickedColumn() throws {
        try withFixture(clickFocusWithoutScrolling: true) { fixture in
            let before = try fixture.viewOrigin(of: fixture.state)
            try fixture.activateTarget(afterClick: true)
            XCTAssertEqual(fixture.state.selectedNodeId, fixture.target.id)
            XCTAssertEqual(try fixture.viewOrigin(of: fixture.state), before)
            let relaidOut = try fixture.relayout()
            XCTAssertEqual(try fixture.viewOrigin(of: relaidOut), before)
            XCTAssertEqual(relaidOut.activeColumnIndex, try fixture.columnIndex(of: fixture.target))
            XCTAssertFalse(try fixture.isFullyVisible(fixture.target, in: relaidOut))
        }
    }

    func testClickKeepsViewportWhenCenteringOnOverflow() throws {
        try withFixture(clickFocusWithoutScrolling: true, centerFocusedColumn: .onOverflow) { fixture in
            let before = try fixture.viewOrigin(of: fixture.state)
            try fixture.activateTarget(afterClick: true)
            XCTAssertEqual(try fixture.viewOrigin(of: fixture.relayout()), before)
        }
    }

    func testSettingHasNoEffectWhenAlwaysCentering() throws {
        var origins: [Bool: CGFloat] = [:]
        for enabled in [false, true] {
            try withFixture(clickFocusWithoutScrolling: enabled, centerFocusedColumn: .always) { fixture in
                let before = try fixture.viewOrigin(of: fixture.state)
                try fixture.activateTarget(afterClick: true)
                let after = try fixture.viewOrigin(of: fixture.state)
                XCTAssertNotEqual(after, before)
                origins[enabled] = after
            }
        }
        XCTAssertEqual(origins[true], origins[false])
    }

    func testSwitchingToAlwaysCenteringRevealsOnNextRelayout() throws {
        try withFixture(clickFocusWithoutScrolling: true) { fixture in
            try fixture.activateTarget(afterClick: true)
            XCTAssertFalse(try fixture.isFullyVisible(fixture.target, in: fixture.relayout()))
            fixture.controller.settings.niri.centerFocusedColumn = .always
            fixture.controller.updateNiriConfig(centerFocusedColumn: .always)
            XCTAssertTrue(try fixture.isFullyVisible(fixture.target, in: fixture.relayout()))
        }
    }

    func testActivationWithoutClickStillScrolls() throws {
        try withFixture(clickFocusWithoutScrolling: true) { fixture in
            try fixture.activateTarget(afterClick: false)
            XCTAssertTrue(try fixture.isFullyVisible(fixture.target, in: fixture.relayout()))
        }
    }

    func testWheelStepsFromClickedColumn() throws {
        try withFixture(clickFocusWithoutScrolling: true) { fixture in
            fixture.controller.settings.gestures.scrollEnabled = true
            try fixture.activateTarget(afterClick: true)
            _ = try fixture.relayout()
            fixture.scrollWheelOneColumnBack()
            XCTAssertEqual(fixture.state.selectedNodeId, fixture.nodes[fixture.targetIndex - 1].id)
        }
    }

    func testKeyboardFocusAfterClickRevealsAgainOnRelayout() throws {
        try withFixture(clickFocusWithoutScrolling: true) { fixture in
            try fixture.activateTarget(afterClick: true)
            _ = try fixture.relayout()
            XCTAssertTrue(fixture.controller.niriLayoutHandler.focusNeighbor(direction: .left))
            XCTAssertTrue(fixture.controller.niriLayoutHandler.focusNeighbor(direction: .right))
            XCTAssertEqual(fixture.state.selectedNodeId, fixture.target.id)
            fixture.scrollToStart()
            XCTAssertFalse(try fixture.isFullyVisible(fixture.target, in: fixture.state))
            XCTAssertTrue(try fixture.isFullyVisible(fixture.target, in: fixture.relayout()))
        }
    }

    func testTurningSettingOffRevealsOnNextRelayout() throws {
        try withFixture(clickFocusWithoutScrolling: true) { fixture in
            try fixture.activateTarget(afterClick: true)
            _ = try fixture.relayout()
            fixture.controller.settings.focus.clickFocusWithoutScrolling = false
            XCTAssertTrue(try fixture.isFullyVisible(fixture.target, in: fixture.relayout()))
        }
    }

    private func withFixture(
        clickFocusWithoutScrolling: Bool,
        centerFocusedColumn: CenterFocusedColumn = .never,
        _ body: (Fixture) throws -> Void
    ) throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "ClickFocusWithoutScrollingTests")
        defer { controller.layoutRefreshController.resetState() }
        controller.settings.focus.clickFocusWithoutScrolling = clickFocusWithoutScrolling
        controller.settings.niri.centerFocusedColumn = centerFocusedColumn
        controller.motionPolicy.animationsEnabled = false
        let frame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let monitor = Monitor(
            id: .init(displayId: 987_001), displayId: 987_001,
            frame: frame, visibleFrame: frame, hasNotch: false, name: "Click Focus"
        )
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1", monitorAssignment: .specificDisplay(OutputId(from: monitor)), layoutType: .niri
            )
        ]
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        manager.applySettings()
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        _ = manager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        var nodes: [NiriWindow] = []
        for index in 0 ..< 3 {
            let token = WindowToken(pid: pid_t(987_101 + index), windowId: 987_201 + index)
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            nodes.append(engine.addWindow(token: token, to: workspaceId, afterSelection: nodes.last?.id))
        }
        manager.updateNiriViewportState(
            ViewportState(activeColumnIndex: 0, viewOffset: 0, selectedNodeId: nodes[0].id), for: workspaceId
        )
        XCTAssertTrue(manager.confirmManagedFocus(nodes[0].token, in: workspaceId, activateWorkspaceOnMonitor: false))
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.layoutState.activeRefreshTask = Task { @MainActor in }
        controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout, reason: .layoutCommand, affectedWorkspaceIds: [workspaceId]
        )
        let fixture = Fixture(controller: controller, workspaceId: workspaceId, monitor: monitor, nodes: nodes)
        XCTAssertFalse(try fixture.isFullyVisible(fixture.target, in: fixture.relayout()))
        try body(fixture)
    }
}
