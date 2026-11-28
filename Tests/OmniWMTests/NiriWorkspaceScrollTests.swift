// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriWorkspaceScrollTests: XCTestCase {
    func testUnanimatedOffsetSurvivesCenteredReconcileUntilTheNextColumnTransition() throws {
        let fixture = try NiriWorkspaceScrollFixture(center: .always, overscroll: true)
        defer { fixture.stop() }
        let before = fixture.state
        let focus = fixture.manager.focusSessionSnapshot
        let target = fixture.noncenteredOffset
        let columns = fixture.engine.columns(in: fixture.workspace)
        XCTAssertGreaterThan(before.activeColumnIndex, columns.startIndex)
        XCTAssertLessThan(before.activeColumnIndex, columns.endIndex - 1)
        XCTAssertNotEqual(target, before.viewOffset)
        XCTAssertTrue(try fixture.scroll(to: target))
        let plan = try fixture.reconcile()
        XCTAssertEqual(plan.sessionPatch.rememberedFocusToken, fixture.selectedToken)
        XCTAssertFalse(plan.animationDirectives.contains { directive in
            if case .activateWindow = directive { return true }
            return false
        })
        XCTAssertEqual(fixture.state.viewOffset, target)
        XCTAssertEqual(fixture.state.activeColumnIndex, before.activeColumnIndex)
        XCTAssertEqual(fixture.state.selectedNodeId, before.selectedNodeId)
        XCTAssertEqual(fixture.manager.focusSessionSnapshot, focus)
        XCTAssertTrue(fixture.state.preservesGestureOffset)
        XCTAssertFalse(fixture.manager.animationDriver.hasMotion(in: fixture.workspace))

        fixture.controller.niriLayoutHandler.focusColumnLastInNiri()
        XCTAssertEqual(fixture.state.activeColumnIndex, columns.endIndex - 1)
        XCTAssertFalse(fixture.state.preservesGestureOffset)
    }

    func testClampedOffsetSurvivesImmediateReconcileAndUsesNativeSpring() throws {
        let fixture = try NiriWorkspaceScrollFixture(center: .always, overscroll: true)
        defer { fixture.stop() }
        let before = fixture.state
        let focus = fixture.manager.focusSessionSnapshot
        let expected = try fixture.clampedOffset()
        fixture.controller.motionPolicy.animationsEnabled = true
        XCTAssertTrue(try fixture.scroll(to: fixture.outOfBoundsOffset, animate: true))
        XCTAssertTrue(fixture.manager.animationDriver.hasMotion(in: fixture.workspace))
        _ = try fixture.reconcile()
        XCTAssertEqual(fixture.state.viewOffset, expected)
        XCTAssertEqual(fixture.state.activeColumnIndex, before.activeColumnIndex)
        XCTAssertEqual(fixture.state.selectedNodeId, before.selectedNodeId)
        XCTAssertEqual(fixture.manager.focusSessionSnapshot, focus)
    }

    func testPoliciesThatWouldMoveTheTargetRefuseBeforeAnyMutation() throws {
        for policy: CenterFocusedColumn in [.always, .never] {
            let fixture = try NiriWorkspaceScrollFixture(center: policy)
            defer { fixture.stop() }
            let target = policy == .always ? fixture.noncenteredOffset : fixture.outOfBoundsOffset
            assertRefusalLeavesStateIntact(fixture, reasonContaining: "layout policy") {
                try fixture.scroll(to: target)
            }
        }
    }

    func testSingleWindowReturnsUnchangedBeforeStoringOffsetOrFlag() throws {
        let fixture = try NiriWorkspaceScrollFixture(center: .always, overscroll: true, windowCount: 1)
        defer { fixture.stop() }
        let before = fixture.state
        let sequence = fixture.manager.worldSeq
        XCTAssertFalse(before.preservesGestureOffset)
        XCTAssertNotEqual(fixture.noncenteredOffset, before.viewOffset)
        XCTAssertFalse(try fixture.scroll(to: fixture.noncenteredOffset))
        XCTAssertEqual(fixture.state, before)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
    }

    func testNonfiniteInactiveAndUnknownTargetsRefuse() throws {
        let fixture = try NiriWorkspaceScrollFixture()
        defer { fixture.stop() }
        for offset: CGFloat in [.nan, .infinity, -.infinity] {
            assertRefusalLeavesStateIntact(fixture) { try fixture.scroll(to: offset) }
        }
        let inactive = try XCTUnwrap(fixture.manager.workspaceId(for: "2", createIfMissing: true))
        let inactiveState = fixture.manager.niriViewportState(for: inactive)
        assertRefusalLeavesStateIntact(fixture) {
            try fixture.scroll(in: inactive, to: fixture.noncenteredOffset)
        }
        XCTAssertEqual(fixture.manager.niriViewportState(for: inactive), inactiveState)
        assertRefusalLeavesStateIntact(fixture) {
            try fixture.scroll(in: WorkspaceDescriptor.ID(), to: fixture.noncenteredOffset)
        }
    }

    func testDwindleAndActiveGestureRefuse() throws {
        let dwindle = try NiriWorkspaceScrollFixture(layout: .dwindle)
        defer { dwindle.stop() }
        assertRefusalLeavesStateIntact(dwindle) { try dwindle.scroll(to: dwindle.noncenteredOffset) }

        let fixture = try NiriWorkspaceScrollFixture(overscroll: true)
        defer { fixture.stop() }
        _ = fixture.manager.animationDriver.beginGesture(in: fixture.workspace, isTrackpad: true)
        XCTAssertTrue(fixture.manager.animationDriver.hasMotion(in: fixture.workspace))
        assertRefusalLeavesStateIntact(fixture) { try fixture.scroll(to: fixture.noncenteredOffset) }
        XCTAssertTrue(fixture.manager.animationDriver.hasMotion(in: fixture.workspace))
    }

    func testDragResizeAndArmedSwipeRefuseBeforeAnyMutation() throws {
        let fixture = try NiriWorkspaceScrollFixture(overscroll: true)
        defer { fixture.stop() }
        let mouse = fixture.controller.mouseEventHandler
        mouse.state.isMoving = true
        assertRefusalLeavesStateIntact(fixture) { try fixture.scroll(to: fixture.noncenteredOffset) }
        mouse.state.isMoving = false

        mouse.state.isResizing = true
        assertRefusalLeavesStateIntact(fixture) { try fixture.scroll(to: fixture.noncenteredOffset) }
        mouse.state.isResizing = false

        mouse.tapInputs.gesturePhase = .armed
        assertRefusalLeavesStateIntact(fixture) { try fixture.scroll(to: fixture.noncenteredOffset) }
        mouse.tapInputs.gesturePhase = .idle
    }

    func testUnresolvedGeometryRefusesWithoutResolvingPrimarySpans() throws {
        let fixture = try NiriWorkspaceScrollFixture(overscroll: true)
        defer { fixture.stop() }
        let columns = fixture.engine.columns(in: fixture.workspace)
        fixture.manager.invalidateNiriCachedPrimarySpans()
        let spans = columns.map { $0.cachedPrimarySpan(orientation: fixture.monitor.autoOrientation) }
        XCTAssertTrue(spans.allSatisfy { $0 == 0 })
        assertRefusalLeavesStateIntact(fixture) { try fixture.scroll(to: fixture.noncenteredOffset) }
        XCTAssertEqual(columns.map { $0.cachedPrimarySpan(orientation: fixture.monitor.autoOrientation) }, spans)
    }

    func testPendingFitRefusesWithoutConsumingTheFitRequest() throws {
        let fixture = try NiriWorkspaceScrollFixture(overscroll: true)
        defer { fixture.stop() }
        fixture.manager.withEngineMutationScope(in: fixture.workspace) {
            fixture.engine.shrinkToFit = true
            fixture.engine.requestAutoFit(in: fixture.workspace)
        }
        let engineState = try XCTUnwrap(fixture.engine.states[fixture.workspace])
        XCTAssertTrue(engineState.autoFitRequested)
        assertRefusalLeavesStateIntact(fixture, reasonContaining: "geometry isn't available") {
            try fixture.scroll(to: fixture.noncenteredOffset)
        }
        XCTAssertTrue(engineState.autoFitRequested)
    }

    private func assertRefusalLeavesStateIntact(
        _ fixture: NiriWorkspaceScrollFixture,
        reasonContaining expectedReason: String? = nil,
        scroll: () throws -> Bool
    ) {
        let before = fixture.state
        let focus = fixture.manager.focusSessionSnapshot
        let sequence = fixture.manager.worldSeq
        XCTAssertThrowsError(try scroll()) { error in
            let refusal = error as? ConfigScriptDispatchRefusal
            XCTAssertFalse(refusal?.reason.isEmpty ?? true)
            if let expectedReason {
                XCTAssertTrue(refusal?.reason.contains(expectedReason) == true, refusal?.reason ?? "")
            }
        }
        XCTAssertEqual(fixture.state, before)
        XCTAssertEqual(fixture.manager.focusSessionSnapshot, focus)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
    }
}

@MainActor
struct NiriWorkspaceScrollFixture {
    let controller: WMController
    let workspace: WorkspaceDescriptor.ID
    let monitor: Monitor
    let engine: NiriLayoutEngine

    var manager: WorkspaceManager {
        controller.workspaceManager
    }

    var state: ViewportState {
        manager.niriViewportState(for: workspace)
    }

    var selectedToken: WindowToken? {
        guard let id = state.selectedNodeId else { return nil }
        return (engine.findNode(by: id, in: workspace) as? NiriWindow)?.token
    }

    private var viewportSpan: CGFloat {
        controller.niriWorkingFrame(for: monitor).width
    }

    var noncenteredOffset: CGFloat {
        state.viewOffset + controller.innerGap(for: monitor)
    }

    var outOfBoundsOffset: CGFloat {
        state.viewOffset + viewportSpan * CGFloat(engine.columns(in: workspace).count)
    }

    init(
        center: CenterFocusedColumn = .never,
        overscroll: Bool = false,
        windowCount: Int = 5,
        layout: LayoutType = .niri
    ) throws {
        controller = WindowAdmissionTestSupport.controller(prefix: "NiriWorkspaceScroll")
        monitor = Self.makeMonitor()
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        let workspaceName = "1"
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(name: workspaceName, layoutType: layout),
            WorkspaceConfiguration(name: "2")
        ]
        manager.applySettings()
        workspace = try XCTUnwrap(manager.workspaceId(for: workspaceName, createIfMissing: true))
        _ = manager.focusWorkspace(named: workspaceName)
        XCTAssertEqual(controller.settings.workspaces.layoutType(for: workspaceName), layout)
        controller.motionPolicy.animationsEnabled = false
        controller.settings.borders.enabled = false
        controller.settings.workspaceBar.enabled = false
        controller.settings.niri.shrinkToFit = false
        controller.settings.niri.centerFocusedColumn = center
        controller.settings.niri.visibleContainerCount = 2
        controller.settings.niri.allowOverscroll = overscroll
        controller.niriLayoutHandler.enableNiriLayout(centerFocusedColumn: center)
        engine = try XCTUnwrap(controller.niriEngine)
        prepareRuntime()
        guard layout == .niri else { return }

        let pid: pid_t = 95_301
        for index in 0 ..< windowCount {
            let token = WindowToken(pid: pid, windowId: Int(pid) + index)
            _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
            manager.setCachedConstraints(.unconstrained, for: token)
        }
        _ = try reconcile()
        try selectInteriorColumn()
        _ = try reconcile()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
    }

    private static func makeMonitor() -> Monitor {
        let displayID: CGDirectDisplayID = 95_300
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        return Monitor(
            id: .init(displayId: displayID), displayId: displayID, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Workspace Scroll"
        )
    }

    private func prepareRuntime() {
        let refresh = controller.layoutRefreshController
        refresh.resetState()
        refresh.layoutState.backingScaleByDisplay = [monitor.displayId: 2]
        refresh.displayLinkActivationForTests = { _ in true }
    }

    private func selectInteriorColumn() throws {
        let columns = engine.columns(in: workspace)
        let index = columns.count / 2
        let selected = try XCTUnwrap(columns[index].windowNodes.first)
        manager.withNiriViewportState(for: workspace) {
            $0.activeColumnIndex = index
            $0.selectedNodeId = selected.id
        }
        XCTAssertTrue(manager.setManagedFocus(selected.token, in: workspace, onMonitor: monitor.id))
        _ = manager.commitWorkspaceSelection(nodeId: selected.id, focusedToken: selected.token, in: workspace)
    }

    func clampedOffset() throws -> CGFloat {
        let columns = engine.columns(in: workspace)
        let gap = controller.innerGap(for: monitor)
        let overscroll = engine.effectiveSettings(in: workspace).edgeOverscroll
        let bounds = try XCTUnwrap(NiriViewportGeometry(
            gap: gap, viewportSpan: viewportSpan, orientation: monitor.autoOrientation, edgeOverscroll: overscroll
        ).overscrollBounds(columns: columns))
        let activePosition = state.containerPosition(
            at: state.activeColumnIndex, containers: columns, gap: gap,
            sizeKeyPath: monitor.autoOrientation.settledSpanKeyPath
        )
        XCTAssertGreaterThan(activePosition + outOfBoundsOffset, bounds.upperBound)
        return bounds.upperBound - activePosition
    }

    func scroll(
        in target: WorkspaceDescriptor.ID? = nil,
        to offset: CGFloat,
        animate: Bool = false
    ) throws(ConfigScriptDispatchRefusal) -> Bool {
        try controller.niriLayoutHandler.scrollWorkspace(target ?? workspace, to: offset, animate: animate)
    }

    func reconcile() throws -> WorkspaceLayoutPlan {
        let plans = controller.layoutRefreshController.buildWorkspacePlansInBatch {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspace])
        }
        return try XCTUnwrap(plans.first)
    }

    func stop() {
        controller.deadlineWheel.stop()
        controller.intentLedger.reset()
        controller.layoutRefreshController.resetState()
        controller.mouseEventHandler.cleanup()
        controller.surfaceReconciler.cleanup()
        controller.axManager.cleanup()
    }
}
