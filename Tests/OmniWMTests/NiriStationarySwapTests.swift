// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class NiriStationarySwapTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let controller: WMController
        let workspace: WorkspaceDescriptor.ID
        let monitor: Monitor
        let engine: NiriLayoutEngine
        let stack: NiriContainer
        let neighbours: [NiriWindow]
        let orientation: Monitor.Orientation

        var handler: NiriLayoutHandler {
            controller.niriLayoutHandler
        }

        func plan(at time: TimeInterval? = nil, settled: Bool = false) throws -> WorkspaceLayoutPlan {
            let state = controller.workspaceManager.niriViewportState(for: workspace)
            var snapshot = try XCTUnwrap(handler.makeWorkspaceSnapshot(
                workspaceId: workspace,
                monitor: monitor,
                options: .init(
                    viewportState: state, useScrollAnimationPath: true, removalSeed: nil, isActiveWorkspace: true
                )
            ))
            snapshot.edgePictures = .none
            return handler.buildOnDemandLayoutPlan(
                snapshot: snapshot, engine: engine, monitor: monitor,
                animationTime: time, settlesAnimation: settled
            )
        }

        func recordNeighbourRequests(in plan: WorkspaceLayoutPlan) throws -> Int {
            let ledger = controller.axManager.frameLedger
            let peerTokens = Set(neighbours.map(\.token))
            var requests = 0
            for change in plan.diff.frameChanges where peerTokens.contains(change.token) {
                let window = try XCTUnwrap(controller.workspaceManager.entry(for: change.token)?.axRef)
                let target = AXFrameApplicationTarget(
                    pid: change.token.pid, window: window, frame: change.frame, components: change.components
                )
                let decision = ledger.prepareFrameApplication(
                    target, isRetry: false, verify: !plan.isAnimationTick, terminalObserver: nil
                )
                if let request = decision.request {
                    requests += 1
                    _ = ledger.handleFrameApplyResults([
                        WindowAdmissionTestSupport.successfulFrameResult(request: request)
                    ])
                }
            }
            return requests
        }
    }

    func testSwappingWithinAHorizontalStackKeepsBothNeighboursTucked() throws {
        try checkSwap(orientation: .horizontal, direction: .up)
    }

    func testSwappingWithinAVerticalStackKeepsBothNeighboursTucked() throws {
        try checkSwap(orientation: .vertical, direction: .right)
    }

    func testPrimaryWindowMotionKeepsTheUnsettledRevealWithoutViewportMotion() throws {
        for orientation: Monitor.Orientation in [.horizontal, .vertical] {
            let fixture = try makeFixture(orientation: orientation)
            let initial = try fixture.plan(settled: true)
            let member = try XCTUnwrap(fixture.stack.windowNodes.first)
            let peer = try XCTUnwrap(fixture.neighbours.last)
            let tucked = try XCTUnwrap(initial.diff.frameChanges.first { $0.token == peer.token }?.frame)
            let span = fixture.stack.cachedPrimarySpan(orientation: orientation)
            let displacement = orientation == .horizontal ? CGPoint(x: span, y: 0) : CGPoint(x: 0, y: span)
            let clock = try XCTUnwrap(fixture.engine.animationClock)
            member.animateMoveFrom(
                displacement: displacement, clock: clock,
                config: fixture.engine.windowMovementAnimationConfig, animated: true
            )

            XCTAssertFalse(fixture.controller.workspaceManager.animationDriver.hasMotion(in: fixture.workspace))
            XCTAssertFalse(fixture.engine.hasAnyColumnAnimationsRunning(in: fixture.workspace))
            let moving = try fixture.plan(at: clock.now())
            let revealed = try XCTUnwrap(moving.diff.frameChanges.first { $0.token == peer.token }?.frame)
            let display = fixture.monitor.frame
            switch orientation {
            case .horizontal:
                XCTAssertGreaterThan(revealed.intersection(display).width, tucked.intersection(display).width)
            case .vertical:
                XCTAssertGreaterThan(revealed.intersection(display).height, tucked.intersection(display).height)
            }
        }
    }

    private func checkSwap(orientation: Monitor.Orientation, direction: Direction) throws {
        let fixture = try makeFixture(orientation: orientation)
        let initial = try fixture.plan(settled: true)
        let frames = Dictionary(uniqueKeysWithValues: initial.diff.frameChanges.map { ($0.token, $0.frame) })
        let columns = fixture.engine.columns(in: fixture.workspace)
        let geometry = columns.map(\.frame)
        let parked = columns.map(\.isParked)
        let members = fixture.stack.windowNodes

        for neighbour in fixture.neighbours {
            let frame = try XCTUnwrap(frames[neighbour.token])
            let primarySpan = orientation == .horizontal ? frame.width : frame.height
            let intersection = frame.intersection(fixture.monitor.frame)
            let contact = orientation == .horizontal ? intersection.width : intersection.height
            XCTAssertGreaterThan(contact, 0)
            XCTAssertLessThan(contact, primarySpan)
            fixture.controller.axManager.confirmFrameWrite(for: neighbour.token.windowId, frame: frame)
        }

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.move(direction)), .executed)
        XCTAssertEqual(fixture.stack.windowNodes.map(\.token), members.reversed().map(\.token))
        let pairAnimations = try members.map { member in
            try XCTUnwrap(orientation == .horizontal ? member.moveYAnimation : member.moveXAnimation)
        }
        XCTAssertTrue(fixture.neighbours.allSatisfy { !$0.hasAnyAnimationRunning })

        let start = try XCTUnwrap(pairAnimations.map(\.animation.startTime).min())
        let end = try XCTUnwrap(pairAnimations.map { $0.animation.startTime + $0.animation.duration }.max())
        let firstRelayout = try initialRelayout(fixture, start: start)
        var requests = try fixture.recordNeighbourRequests(in: firstRelayout)
        let interval = 1 / fixture.engine.displayRefreshRate(in: fixture.workspace)

        let midway = try fixture.plan(at: start + (end - start) / 2)
        for (member, other) in zip(members, members.reversed()) {
            let sample = try XCTUnwrap(midway.diff.frameChanges.first { $0.token == member.token }?.frame)
            XCTAssertNotEqual(sample, frames[member.token])
            XCTAssertNotEqual(sample, frames[other.token])
        }
        for time in stride(from: start, to: end, by: interval) {
            let plan = try fixture.plan(at: time)
            requests += try fixture.recordNeighbourRequests(in: plan)
            for neighbour in fixture.neighbours {
                let planned = plan.diff.frameChanges.first { $0.token == neighbour.token }?.frame
                XCTAssertEqual(planned, frames[neighbour.token])
            }
        }

        XCTAssertFalse(fixture.engine.tickAllWindowAnimations(in: fixture.workspace, at: end.nextUp))
        let settled = try fixture.plan(at: end.nextUp, settled: true)
        requests += try fixture.recordNeighbourRequests(in: settled)
        XCTAssertEqual(requests, 0, "The frame ledger prepared writes for stationary neighbours")
        for (member, other) in zip(members, members.reversed()) {
            XCTAssertEqual(settled.diff.frameChanges.first { $0.token == member.token }?.frame, frames[other.token])
        }
        XCTAssertEqual(columns.map(\.frame), geometry)
        XCTAssertEqual(columns.map(\.isParked), parked)
    }

    private func initialRelayout(_ fixture: Fixture, start: TimeInterval) throws -> WorkspaceLayoutPlan {
        if fixture.orientation == .vertical {
            return try fixture.plan(at: start)
        }
        let plans = fixture.controller.workspaceManager.withBatchedLayoutBuild {
            fixture.handler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspace])
        }
        return try XCTUnwrap(plans.first)
    }

    private func makeFixture(orientation: Monitor.Orientation) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "NiriStationarySwapTests")
        let displayID: CGDirectDisplayID = 95_200
        let frame = orientation == .horizontal
            ? CGRect(x: 0, y: 0, width: 1_600, height: 900)
            : CGRect(x: 0, y: 0, width: 900, height: 1_600)
        let monitor = Monitor(
            id: .init(displayId: displayID), displayId: displayID, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Stationary Swap"
        )
        configureSwapGeometry(controller, monitor: monitor)
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        let workspace = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        _ = manager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        engine.animationClock = AnimationClock(time: CACurrentMediaTime())
        let working = controller.niriWorkingFrame(for: monitor)
        let span = orientation == .horizontal ? working.width : working.height
        let pid: pid_t = 95_201
        let tokens = (0 ..< 4).map { WindowToken(pid: pid, windowId: Int(pid) + $0) }
        let nodes = tokens.map { token in
            _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
            return engine.addWindow(token: token, to: workspace, afterSelection: nil)
        }
        let columns = engine.columns(in: workspace)
        let stack = columns[1]
        manager.withEngineMutationScope(in: workspace) {
            stack.appendChild(nodes[2])
            columns[2].remove()
            for column in engine.columns(in: workspace) {
                switch orientation {
                case .horizontal: column.width = .fixed(span)
                case .vertical: column.height = .fixed(span)
                }
                column.setCachedPrimarySpan(span, orientation: orientation)
            }
        }
        manager.withNiriViewportState(for: workspace) {
            $0.activeColumnIndex = 1
            $0.selectedNodeId = nodes[1].id
        }
        _ = manager.commitWorkspaceSelection(nodeId: nodes[1].id, focusedToken: tokens[1], in: workspace)
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        registerCleanup(controller)
        return Fixture(
            controller: controller, workspace: workspace, monitor: monitor, engine: engine, stack: stack,
            neighbours: [nodes[0], nodes[3]], orientation: orientation
        )
    }

    private func configureSwapGeometry(_ controller: WMController, monitor: Monitor) {
        let innerGap = 12.0
        let untuckedContact = 5.0
        let outerGap = innerGap + untuckedContact
        controller.settings.gaps.update(.init(
            monitorName: monitor.name, monitorDisplayId: monitor.displayId, innerGap: innerGap,
            outerGapLeft: outerGap, outerGapRight: outerGap, outerGapTop: outerGap, outerGapBottom: outerGap
        ), for: monitor)
        controller.motionPolicy.animationsEnabled = true
        controller.settings.borders.enabled = false
        controller.settings.workspaceBar.enabled = false
        controller.settings.niri.edgeGaps = true
        controller.settings.niri.edgePeekPercent = 0
        controller.settings.niri.shrinkToFit = false
        controller.settings.focus.moveCrossesMonitorAtEdge = false
    }

    private func registerCleanup(_ controller: WMController) {
        addTeardownBlock { @MainActor [controller] in
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
    }
}
