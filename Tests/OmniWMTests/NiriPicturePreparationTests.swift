// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriPicturePreparationTests: XCTestCase {
    @MainActor private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let frame: CGRect
        let gap: CGFloat
        let nodes: [NiriWindow]
        let visibleRowCount: Int

        var handler: NiriLayoutHandler {
            controller.niriLayoutHandler
        }

        var columns: [NiriContainer] {
            engine.columns(in: workspaceId)
        }

        var state: ViewportState {
            ViewportState(activeColumnIndex: 0, selectedNodeId: nodes[0].id)
        }

        func snapshot(
            state: ViewportState? = nil,
            orientation: Monitor.Orientation = .vertical,
            parked: Set<WindowToken> = []
        ) -> NiriWorkspaceSnapshot {
            let viewport = state ?? self.state
            return NiriWorkspaceSnapshot(
                workspaceId: workspaceId,
                monitor: LayoutMonitorSnapshot(
                    monitorId: .init(displayId: 94), displayId: 94, frame: frame, visibleFrame: frame,
                    workingFrame: frame, fullscreenLayoutFrame: frame, scale: 2, orientation: orientation
                ),
                windows: nodes.map { node in
                    LayoutWindowSnapshot(
                        token: node.token, constraints: .unconstrained,
                        hiddenState: parked.contains(node.token) ? HiddenState(
                            proportionalPosition: .zero, referenceMonitorId: .init(displayId: 94),
                            reason: .layoutTransient(AxisHideEdge.maximum.encodedHideSide)
                        ) : nil,
                        layoutReason: .standard
                    )
                },
                excludedTokens: [], plannedSeq: 0, viewportState: viewport, preferredFocusToken: nil,
                hasCompletedInitialRefresh: true, useScrollAnimationPath: false, removalSeed: nil, gap: gap,
                niriWorkingFrame: frame, fullscreenLayoutFrame: frame, displayRefreshRate: 60,
                isActiveWorkspace: true, quietArrivalTokens: [],
                edgePictures: NiriEdgePictureState(isAvailable: true, parkedAboveTokens: parked)
            )
        }
    }

    func testWarmRolesUseLogicalFramesAndIncludeOneBottomColumn() throws {
        let fixture = try makeFixture()
        for column in fixture.columns {
            column.renderedFrame = try XCTUnwrap(column.frame).offsetBy(dx: -fixture.frame.width * 2, dy: 0)
        }
        let preparation = try XCTUnwrap(fixture.handler.picturePreparation(
            engine: fixture.engine, snapshot: fixture.snapshot(), state: fixture.state, isSettled: true, time: 0
        ))
        let edgeIndex = fixture.visibleRowCount - 1
        let expected = Set(fixture.nodes[edgeIndex ... edgeIndex + 1].map(\.token) + [fixture.nodes[0].token])
        XCTAssertEqual(Set(preparation.warmCandidates.keys), expected)
        XCTAssertTrue(preparation.motionCandidates.isEmpty)
        XCTAssertTrue(preparation.isSettled)
    }

    func testMotionCrossingUsesSettledHeightsWhileTheLiveSpanIsStillSmall() throws {
        let fixture = try makeFixture()
        fixture.columns[0].targetHeight = fixture.frame.height
        let preparation = try XCTUnwrap(fixture.handler.picturePreparation(
            engine: fixture.engine, snapshot: fixture.snapshot(), state: fixture.state, isSettled: false, time: 0
        ))
        let expected = Set(fixture.nodes[1 ..< fixture.visibleRowCount].map(\.token))
        XCTAssertEqual(Set(preparation.motionCandidates.keys), expected)
        XCTAssertFalse(preparation.isSettled)
    }

    func testParkedActiveTargetRequestsContentAndPreservesPreferredFocus() throws {
        let fixture = try makeFixture()
        let selected = try XCTUnwrap(fixture.nodes.last)
        let state = ViewportState(activeColumnIndex: fixture.nodes.count - 1, selectedNodeId: selected.id)
        let snapshot = fixture.snapshot(state: state, parked: [selected.token])
        let preparation = try XCTUnwrap(fixture.handler.picturePreparation(
            engine: fixture.engine, snapshot: snapshot, state: state, isSettled: false, time: 0
        ))
        XCTAssertNotNil(preparation.motionCandidates[selected.token])
        XCTAssertEqual(fixture.handler.picturePreferredFocus(
            in: fixture.workspaceId, state: state, pictures: snapshot.edgePictures, isRelayout: true
        ), selected.token)
        XCTAssertNil(fixture.handler.picturePreferredFocus(
            in: fixture.workspaceId, state: state, pictures: snapshot.edgePictures, isRelayout: false
        ))
        let inserted = fixture.engine.addWindow(
            token: WindowToken(pid: selected.token.pid, windowId: selected.token.windowId + 1),
            to: fixture.workspaceId, afterSelection: fixture.nodes[0].id,
            focusedToken: fixture.handler.picturePreferredFocus(
                in: fixture.workspaceId, state: state, pictures: snapshot.edgePictures, isRelayout: true
            )
        )
        let insertedColumn = try XCTUnwrap(fixture.engine.column(of: inserted))
        XCTAssertEqual(fixture.engine.columnIndex(of: insertedColumn, in: fixture.workspaceId), fixture.nodes.count)
    }

    func testSnapshotParkedAboveExcludesOtherReasonsAndHostedWindowsWithoutRequiringReadiness() throws {
        let fixture = try makeFixture(hostedLast: true)
        let source = fixture.nodes[0].token
        let hosted = try XCTUnwrap(fixture.nodes.last).token
        let snapshot = fixture.snapshot()
        for reason: HiddenReason in [
            .workspaceInactive,
            .scratchpad,
            .layoutTransient(.left),
            .layoutTransient(.right)
        ] {
            let windows = [source, hosted].map { token in
                LayoutWindowSnapshot(
                    token: token, constraints: .unconstrained,
                    hiddenState: HiddenState(
                        proportionalPosition: .zero, referenceMonitorId: snapshot.monitor.monitorId, reason: reason
                    ), layoutReason: .standard
                )
            }
            let input = WorkspaceRefreshInput(
                workspaceId: fixture.workspaceId, monitor: snapshot.monitor, windows: windows,
                excludedTokens: [], plannedSeq: 0, isActiveWorkspace: true
            )
            let pictures = fixture.handler.edgePictureState(for: input)
            XCTAssertTrue(pictures.readyTokens.isEmpty)
            XCTAssertEqual(pictures.parkedAboveTokens, reason == .layoutTransient(.right) ? [source] : [])
            XCTAssertEqual(pictures.parkedBelowTokens, reason == .layoutTransient(.left) ? [source] : [])
        }
    }

    func testHostedWindowAndNonNormalRowsAreNotCaptureCandidates() throws {
        let fixture = try makeFixture(hostedLast: true)
        let edgeIndex = fixture.visibleRowCount - 1
        fixture.nodes[edgeIndex].sizingMode = .maximized
        let preparation = try XCTUnwrap(fixture.handler.picturePreparation(
            engine: fixture.engine, snapshot: fixture.snapshot(), state: fixture.state, isSettled: true, time: 0
        ))
        XCTAssertEqual(Set(preparation.warmCandidates.keys), [fixture.nodes[0].token])
        XCTAssertTrue(preparation.motionCandidates.isEmpty)
        XCTAssertNil(fixture.controller.workspaceManager.entry(for: try XCTUnwrap(fixture.nodes.last).token)?.axRef)
    }

    func testHorizontalAndInteractiveResizeDoNotPreparePictures() throws {
        let fixture = try makeFixture()
        XCTAssertNil(fixture.handler.picturePreparation(
            engine: fixture.engine, snapshot: fixture.snapshot(orientation: .horizontal),
            state: fixture.state, isSettled: true, time: 0
        ))
        fixture.engine.interactiveResize = InteractiveResize(
            windowId: fixture.nodes[0].id, workspaceId: fixture.workspaceId,
            originalContainerSpan: fixture.columns[0].cachedHeight, originalWindowBaseline: nil,
            edges: .top, startMouseLocation: fixture.frame.center, columnIndex: 0, orientation: .vertical,
            originalViewOffset: fixture.state.viewOffset
        )
        XCTAssertNil(fixture.handler.picturePreparation(
            engine: fixture.engine, snapshot: fixture.snapshot(), state: fixture.state, isSettled: true, time: 0
        ))
    }

    func testMovingTicksPrepareOnceUntilGestureOrAnotherCommand() throws {
        let fixture = try makeFixture()
        let snapshot = fixture.snapshot()
        let tickTime: TimeInterval = 0
        XCTAssertTrue(fixture.handler.shouldPreparePictures(snapshot: snapshot, animationTime: tickTime))
        var diff = WorkspaceLayoutDiff()
        diff.picturePreparation = NiriPicturePreparation(isSettled: false, warmCandidates: [:], motionCandidates: [:])
        fixture.controller.niriEdgePictures.reconcile(WorkspaceLayoutPlan(
            workspaceId: fixture.workspaceId, monitor: snapshot.monitor,
            sessionPatch: WorkspaceSessionPatch(workspaceId: fixture.workspaceId, viewportState: nil), diff: diff,
            isAnimationTick: true
        ))
        XCTAssertFalse(fixture.handler.shouldPreparePictures(snapshot: snapshot, animationTime: tickTime))
        XCTAssertTrue(fixture.handler.shouldPreparePictures(snapshot: snapshot, animationTime: nil))
        _ = fixture.controller.workspaceManager.animationDriver.beginGesture(
            in: fixture.workspaceId, isTrackpad: true, timestamp: tickTime
        )
        XCTAssertTrue(fixture.handler.shouldPreparePictures(snapshot: snapshot, animationTime: tickTime))
        XCTAssertFalse(fixture.handler.shouldPreparePictures(
            snapshot: fixture.snapshot(orientation: .horizontal), animationTime: tickTime
        ))
    }

    func testOnlyNativeBottomEdgeColumnIsPrewarmed() throws {
        let fixture = try makeFixture()
        let activeIndex = fixture.visibleRowCount - 1
        let state = ViewportState(activeColumnIndex: activeIndex, selectedNodeId: fixture.nodes[activeIndex].id)
        let preparation = try XCTUnwrap(fixture.handler.picturePreparation(
            engine: fixture.engine, snapshot: fixture.snapshot(state: state), state: state, isSettled: true, time: 0
        ))
        XCTAssertNil(preparation.warmCandidates[fixture.nodes[activeIndex - 1].token])
        XCTAssertNil(preparation.warmCandidates[fixture.nodes[activeIndex - 2].token])
        XCTAssertNotNil(preparation.warmCandidates[fixture.nodes[activeIndex].token])
    }

    func testBottomMotionCapturePredictsBothExitAndEntry() throws {
        for entering in [false, true] {
            let fixture = try makeFixture()
            let distance = fixture.columns[0].settledHeight + fixture.gap
            var previous = fixture.state
            previous.jumpOffset(to: entering ? distance : 0)
            var next = fixture.state
            next.springOffset(to: entering ? 0 : distance)
            fixture.controller.workspaceManager.animationDriver.reconcileViewportCommit(
                workspaceId: fixture.workspaceId, previous: previous, next: next,
                transition: next.offsetTransition, at: 0
            )
            let preparation = try XCTUnwrap(fixture.handler.picturePreparation(
                engine: fixture.engine, snapshot: fixture.snapshot(state: next), state: next,
                isSettled: false, time: 0
            ))
            XCTAssertNotNil(preparation.motionCandidates[fixture.nodes[0].token])
        }
    }

    func testGestureBottomCandidateAppearsAtTheBandWithoutPrediction() throws {
        let fixture = try makeFixture()
        _ = fixture.controller.workspaceManager.animationDriver.beginGesture(
            in: fixture.workspaceId, isTrackpad: true, timestamp: 0
        )
        let floor = NiriLayoutViewport.minimumNativeBottomVisibility
        var state = fixture.state
        state.jumpOffset(to: fixture.columns[0].settledHeight - floor / 2)
        let preparation = try XCTUnwrap(fixture.handler.picturePreparation(
            engine: fixture.engine, snapshot: fixture.snapshot(state: state), state: state,
            isSettled: false, time: 0
        ))
        XCTAssertNotNil(preparation.motionCandidates[fixture.nodes[0].token])
    }

    private func makeFixture(hostedLast: Bool = false) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMNiriPicturePreparationTests")
        let frame = CGRect(x: -800, y: 250, width: 800, height: 900)
        let visibleRowCount = 3
        let height = frame.height / CGFloat(visibleRowCount)
        let gap = height / 10
        let monitor = Monitor(
            id: .init(displayId: 94), displayId: 94, frame: frame, visibleFrame: frame, hasNotch: false,
            name: "Portrait"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let nodes = try (0 ... visibleRowCount).map { index in
            let token = WindowToken(
                pid: hostedLast && index == visibleRowCount ? getpid() : 964_001,
                windowId: 964_101 + index
            )
            let windowFrame = CGRect(
                x: frame.minX, y: frame.minY + CGFloat(index) * (height + gap), width: frame.width, height: height
            )
            if hostedLast && index == visibleRowCount {
                XCTAssertEqual(controller.workspaceManager.addHostedWindow(
                    token: token, metadata: HostedWindowMetadata(
                        appId: "fixture", title: "Hosted", minimumSize: CGSize(width: height, height: height)
                    ), to: workspaceId, initialFrame: windowFrame
                ), token)
            } else {
                _ = controller.workspaceManager.addWindow(
                    AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId),
                    pid: token.pid, windowId: token.windowId, to: workspaceId
                )
            }
            let node = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            node.frame = windowFrame
            let column = try XCTUnwrap(engine.column(of: node))
            column.cachedHeight = height
            column.frame = windowFrame
            return node
        }
        return Fixture(
            controller: controller, engine: engine, workspaceId: workspaceId, frame: frame, gap: gap,
            nodes: nodes, visibleRowCount: visibleRowCount
        )
    }
}
