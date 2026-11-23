// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

extension TrackpadWindowMoveFrameTests {
    func startSettledCarry(_ fixture: Fixture) {
        let frames = fixture.initialFrames
        let refresh = fixture.controller.layoutRefreshController
        refresh.fastFrameProvider = { token, _ in frames[token] }
        let bounds = Dictionary(uniqueKeysWithValues: frames.map {
            (UInt32($0.key.windowId), ScreenCoordinateSpace.toWindowServer(rect: $0.value))
        })
        refresh.windowBoundsProvider = { ids in bounds.filter { ids.contains($0.key) } }
        let startTime = fixture.events.begin.timestamp
        fixture.handler.liveDragClock = { startTime }
        fixture.begin()
        fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 4)))
        XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
        XCTAssertNotNil(fixture.controller.layoutRefreshController.carriedWindowDrawStamp)
    }

    func assertFrameSubmission(
        _ token: WindowToken, frame: CGRect, file: StaticString = #filePath, line: UInt = #line
    ) {
        let events = FrameApplyTrace.shared.dump().split(separator: "\n")
        XCTAssertTrue(events.contains {
            $0.contains("win=\(token.windowId) ") && $0.contains("target=\(TraceFormat.rect(frame))")
        }, "\(events)", file: file, line: line)
    }

    private func drawCarried(_ fixture: Fixture, frame: CGRect, on monitor: Monitor? = nil) throws {
        let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspace))
        fixture.controller.layoutRefreshController.renderCarriedWindow(
            fixture.moved, frame: frame, engine: fixture.base.niri, monitor: monitor ?? fixture.monitor,
            context: context
        )
    }

    private func requireSettledFrame(_ token: WindowToken, in fixture: Fixture) -> Bool {
        fixture.controller.niriLayoutHandler.applyFramesOnDemand(
            wsId: fixture.workspace, state: fixture.base.manager.niriViewportState(for: fixture.workspace),
            engine: fixture.base.niri, monitor: fixture.monitor, isInteractiveMove: true,
            requiringSettledFrameFor: token
        )
    }

    func executePendingRelayout(_ refresh: LayoutRefreshController) throws {
        let request = try XCTUnwrap(refresh.layoutState.pendingRefresh)
        refresh.layoutState.pendingRefresh = nil
        let generation = refresh.layoutState.refreshGeneration
        XCTAssertTrue(refresh.executeImmediateRelayout(refresh: request, generation: generation))
    }

    func testSettledCarryWritesJustTheNewFrameAfterAFullDraw() throws {
        let fixture = try makeMoveFixture(.horizontal)
        let refresh = fixture.controller.layoutRefreshController
        startSettledCarry(fixture)
        let touch = fixture.slideWithinStartingWindow(1 / 8)
        let builds = refresh.layoutBuildMetricsCounts().totalBuilds
        fixture.controller.axManager.forceApplyNextFrame(for: fixture.moved.windowId)
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        fixture.send(fixture.event(at: touch))

        assertFrameSubmission(fixture.moved, frame: fixture.expectedFloatingFrame(at: touch))
        XCTAssertFalse(FrameApplyTrace.shared.dump().contains("win=\(fixture.target.windowId) "))
        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, builds)
        fixture.cancel()
    }

    func testSettledCarryRebuildsAfterAPeerChangesWidth() throws {
        let fixture = try makeMoveFixture(.horizontal)
        startSettledCarry(fixture)
        let refresh = fixture.controller.layoutRefreshController
        let node = try XCTUnwrap(fixture.base.niriNode(fixture.target))
        let peer = try XCTUnwrap(fixture.base.niri.findColumn(containing: node, in: fixture.workspace))
        let priorWidth = try XCTUnwrap(node.frame).width
        let width = (priorWidth / 2).rounded()
        let builds = refresh.layoutBuildMetricsCounts().totalBuilds
        fixture.base.manager.withEngineMutationScope(in: fixture.workspace) {
            peer.width = .fixed(width)
            peer.cachedWidth = 0
        }

        fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 8)))

        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, builds + 1)
        XCTAssertEqual(try XCTUnwrap(node.frame).width, width)
        fixture.cancel()
    }

    func testSettledCarryIgnoresQueuedPhysicalMouseMotion() throws {
        let fixture = try makeMoveFixture(.horizontal)
        startSettledCarry(fixture)
        let handler = fixture.handler
        handler.beginPerformanceCapture()
        let initial = try XCTUnwrap(fixture.base.niri.liveColumnMove?.floatingFrame)

        handler.dispatchQueuedMouseDragged(at: fixture.targetFrame.center, button: .left)

        XCTAssertEqual(try XCTUnwrap(handler.endPerformanceCapture()).mouseWarpSamples, 0)
        XCTAssertEqual(fixture.base.niri.liveColumnMove?.floatingFrame, initial)
        fixture.cancel()
    }

    func testSettledCarryRebuildsWhenAPeerHasAnUnscheduledAnimation() throws {
        let fixture = try makeMoveFixture(.horizontal)
        startSettledCarry(fixture)
        let refresh = fixture.controller.layoutRefreshController
        let node = try XCTUnwrap(fixture.base.niriNode(fixture.target))
        let column = try XCTUnwrap(fixture.base.niri.findColumn(containing: node, in: fixture.workspace))
        let displacement = CGPoint(x: fixture.targetFrame.midX - fixture.startFrame.midX, y: 0)
        column.animateMoveFrom(displacement: displacement, clock: fixture.controller.animationClock, animated: true)
        let before = refresh.layoutBuildMetricsCounts().totalBuilds

        fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 8)))

        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, before + 1)
        XCTAssertNil(refresh.carriedWindowDrawStamp)
        fixture.cancel()
    }

    func testSettledCarrySubmitsAForcedOrRestoredPeerFrame() throws {
        enum PeerRequest: CaseIterable {
            case force, restored
        }
        for request in PeerRequest.allCases {
            let fixture = try makeMoveFixture(.horizontal)
            let refresh = fixture.controller.layoutRefreshController
            startSettledCarry(fixture)
            let peer = fixture.target
            let peerFrame = try XCTUnwrap(fixture.initialFrames[peer])
            fixture.controller.axManager.confirmFrameWrite(for: peer.windowId, frame: peerFrame)
            switch request {
            case .force:
                fixture.controller.axManager.forceApplyNextFrame(for: peer.windowId)
            case .restored:
                refresh.markNativeFullscreenRestoredForFrameApply(peer)
            }
            let before = refresh.layoutBuildMetricsCounts().totalBuilds
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }

            fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 8)))

            XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, before + 1, "\(request)")
            assertFrameSubmission(peer, frame: peerFrame)
            XCTAssertFalse(refresh.nativeFullscreenRestoredFrameApplyTokens.contains(peer))
            XCTAssertNil(refresh.carriedWindowDrawStamp)
            fixture.cancel()
        }
    }

    func testSettledCarryRebuildsAfterAWorkspaceDisplayOrWorkingAreaChange() throws {
        let fixture = try makeMoveFixture(.horizontal, adjacentDisplay: true)
        let refresh = fixture.controller.layoutRefreshController
        startSettledCarry(fixture)
        let accepted = try XCTUnwrap(refresh.carriedWindowDrawStamp)
        let other = try XCTUnwrap(fixture.base.monitors.last)
        let otherArea = fixture.controller.niriInteractionGeometry(for: other).workingFrame
        let priorDraws: [LayoutRefreshController.CarriedWindowDrawStamp] = [
            .init(
                workspaceId: fixture.base.target, worldSeq: accepted.worldSeq,
                displayId: accepted.displayId, workingFrame: accepted.workingFrame
            ),
            .init(
                workspaceId: accepted.workspaceId, worldSeq: accepted.worldSeq,
                displayId: other.displayId, workingFrame: accepted.workingFrame
            ),
            .init(
                workspaceId: accepted.workspaceId, worldSeq: accepted.worldSeq,
                displayId: accepted.displayId, workingFrame: otherArea
            )
        ]
        let frame = try XCTUnwrap(fixture.base.niri.liveColumnMove?.floatingFrame)
        for prior in priorDraws {
            refresh.carriedWindowDrawStamp = prior
            let before = refresh.layoutBuildMetricsCounts().totalBuilds

            try drawCarried(fixture, frame: frame)

            XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, before + 1)
            XCTAssertEqual(refresh.carriedWindowDrawStamp, accepted)
        }
        fixture.cancel()
    }

    func testSettledCarryWaitsForThePictureOwnersMotionPass() throws {
        let fixture = try makeMoveFixture(.horizontal)
        let refresh = fixture.controller.layoutRefreshController
        startSettledCarry(fixture)
        let presenter = fixture.controller.niriEdgePictures
        let transitional = WorkspaceLayoutPlan(
            workspaceId: fixture.workspace, monitor: refresh.buildMonitorSnapshot(for: fixture.monitor),
            sessionPatch: WorkspaceSessionPatch(workspaceId: fixture.workspace),
            diff: WorkspaceLayoutDiff(picturePreparation: NiriPicturePreparation(isSettled: false))
        )
        presenter.preparePictures(transitional, enabled: true)
        XCTAssertTrue(presenter.requiresFullCarryDraw(in: fixture.workspace))
        let before = refresh.layoutBuildMetricsCounts().totalBuilds

        fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 8)))

        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, before + 1)
        XCTAssertFalse(presenter.requiresFullCarryDraw(in: fixture.workspace))
        XCTAssertNil(refresh.carriedWindowDrawStamp)
        fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 4)))
        XCTAssertNotNil(refresh.carriedWindowDrawStamp)
        fixture.cancel()
    }

    func testSettledCarryLeavesTheCurrentFrameForItsQueuedRelayout() throws {
        let fixture = try makeMoveFixture(.horizontal)
        startSettledCarry(fixture)
        let refresh = fixture.controller.layoutRefreshController
        refresh.requestImmediateRelayout(reason: .layoutCommand, affectedWorkspaceIds: [fixture.workspace])
        let touch = fixture.slideWithinStartingWindow(1 / 8)
        let frame = fixture.expectedFloatingFrame(at: touch)
        let builds = refresh.layoutBuildMetricsCounts().totalBuilds
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        fixture.send(fixture.event(at: touch))

        XCTAssertEqual(fixture.base.niri.liveColumnMove?.floatingFrame, frame)
        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, builds)
        XCTAssertFalse(FrameApplyTrace.shared.dump().contains("win=\(fixture.moved.windowId) "))
        try executePendingRelayout(refresh)
        assertFrameSubmission(fixture.moved, frame: frame)
        fixture.cancel()
    }

    func testSettledCarryChangingLandingQueuesOneDrawWithTheLatestFrame() throws {
        let fixture = try makeMoveFixture(.horizontal)
        startSettledCarry(fixture)
        let refresh = fixture.controller.layoutRefreshController
        let before = refresh.layoutBuildMetricsCounts().totalBuilds
        refresh.beginPerformanceCapture()
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        fixture.send(fixture.event(at: fixture.targetTouch))

        XCTAssertNotNil(fixture.base.niri.liveColumnMove?.narrowedSlot)
        XCTAssertNil(refresh.carriedWindowDrawStamp)
        XCTAssertEqual(try XCTUnwrap(refresh.endPerformanceCapture()).refreshesEnqueued, 1)
        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, before)
        let trace = FrameApplyTrace.shared.dump()
        let previous = fixture.expectedFloatingFrame(at: fixture.slideWithinStartingWindow(1 / 4))
        XCTAssertTrue(trace.split(separator: "\n").filter { $0.contains("win=\(fixture.moved.windowId) ") }.allSatisfy {
            $0.contains("/cancelled ") && $0.contains("target=\(TraceFormat.rect(previous))")
        }, trace)
        try executePendingRelayout(refresh)
        let frame = fixture.expectedFloatingFrame(at: fixture.targetTouch)
        XCTAssertTrue(FrameApplyTrace.shared.dump().split(separator: "\n").contains {
            $0.contains("win=\(fixture.moved.windowId) ") && $0.contains("target=\(TraceFormat.rect(frame))")
                && $0.contains("event=outcome=skip/contextUnavailable")
        })
        fixture.cancel()
    }

    func testSettledCarryLeavesTheCurrentFrameForItsPromotedRelocation() throws {
        let fixture = try makeMoveFixture(.horizontal)
        startSettledCarry(fixture)
        let refresh = fixture.controller.layoutRefreshController
        let previous = try XCTUnwrap(refresh.layoutState.activeRefresh)
        refresh.commitWorkspaceMonitorTransition(.init(
            status: .executed, affectedWorkspaces: [fixture.workspace],
            floatingRelocations: [.init(
                workspaceId: fixture.workspace,
                token: fixture.target,
                frame: fixture.targetFrame
            )]
        ))
        fixture.blocker.completion.finish()
        refresh.finishRefresh(previous, didComplete: true, generation: refresh.layoutState.refreshGeneration)
        XCTAssertNil(refresh.layoutState.pendingRefresh)
        let promoted = try XCTUnwrap(refresh.layoutState.activeRefresh)
        XCTAssertEqual(promoted.workspaceMonitorRelocations[fixture.target]?.allowsTerminalRecovery, true)
        XCTAssertFalse(refresh.layoutState.didExecuteEffectPlan)
        let touch = fixture.slideWithinStartingWindow(1 / 8)
        let builds = refresh.layoutBuildMetricsCounts().totalBuilds
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        fixture.send(fixture.event(at: touch))

        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, builds)
        XCTAssertFalse(FrameApplyTrace.shared.dump().contains("win=\(fixture.moved.windowId) "))
        XCTAssertTrue(refresh.executeImmediateRelayout(
            refresh: promoted, generation: refresh.layoutState.refreshGeneration
        ))
        assertFrameSubmission(fixture.moved, frame: fixture.expectedFloatingFrame(at: touch))
        XCTAssertTrue(refresh.layoutState.didExecuteEffectPlan)
        let next = fixture.slideWithinStartingWindow(1 / 4)
        fixture.send(fixture.event(at: next))
        assertFrameSubmission(fixture.moved, frame: fixture.expectedFloatingFrame(at: next))
        fixture.cancel()
    }

    func testSettledCarryDefersOnlyToARelayoutThatIncludesItsWorkspace() throws {
        enum Scope: CaseIterable {
            case another, additional, all
        }
        for scope in Scope.allCases {
            let fixture = try makeMoveFixture(.horizontal, adjacentDisplay: true)
            startSettledCarry(fixture)
            let refresh = fixture.controller.layoutRefreshController
            var request = LayoutRefreshController.ScheduledRefresh(
                kind: .relayout, reason: .layoutConfigChanged,
                affectedWorkspaceIds: scope == .all ? [] : [fixture.base.target]
            )
            if scope == .additional { request.additionalAffectedWorkspaceIds.insert(fixture.workspace) }
            refresh.enqueueRefresh(request)
            let touch = fixture.slideWithinStartingWindow(1 / 8)
            let before = refresh.layoutBuildMetricsCounts().totalBuilds
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }

            fixture.send(fixture.event(at: touch))

            XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, before)
            if scope == .another {
                assertFrameSubmission(fixture.moved, frame: fixture.expectedFloatingFrame(at: touch))
                XCTAssertNotNil(refresh.carriedWindowDrawStamp)
            } else {
                XCTAssertFalse(FrameApplyTrace.shared.dump().contains("win=\(fixture.moved.windowId) "))
                XCTAssertNil(refresh.carriedWindowDrawStamp)
            }
            fixture.cancel()
        }
    }

    func testSettledCarryLeavesTheCurrentFrameForItsAnimationTick() throws {
        let fixture = try makeMoveFixture(.horizontal)
        startSettledCarry(fixture)
        let refresh = fixture.controller.layoutRefreshController
        let niri = fixture.controller.niriLayoutHandler
        let displayId = fixture.monitor.displayId
        XCTAssertTrue(niri.registerScrollAnimation(fixture.workspace, on: displayId))
        let touch = fixture.slideWithinStartingWindow(1 / 8)
        let frame = fixture.expectedFloatingFrame(at: touch)
        let builds = refresh.layoutBuildMetricsCounts().totalBuilds
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        fixture.send(fixture.event(at: touch))

        XCTAssertEqual(fixture.base.niri.liveColumnMove?.floatingFrame, frame)
        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, builds)
        XCTAssertFalse(FrameApplyTrace.shared.dump().contains("win=\(fixture.moved.windowId) "))
        niri.tickScrollAnimation(targetTime: fixture.handler.liveDragClock(), displayId: displayId)
        assertFrameSubmission(fixture.moved, frame: frame)
        fixture.cancel()
    }

    func testSettledCarryKeepsDrawingWhileVisibilityIsPending() throws {
        let fixture = try makeMoveFixture(.horizontal)
        let refresh = fixture.controller.layoutRefreshController
        startSettledCarry(fixture)
        refresh.requestVisibilityRefresh(reason: .windowDeminiaturized, affectedWorkspaceIds: [fixture.workspace])
        let touch = fixture.slideWithinStartingWindow(1 / 8)
        let before = refresh.layoutBuildMetricsCounts().totalBuilds
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        fixture.send(fixture.event(at: touch))

        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, before + 1)
        XCTAssertNil(refresh.carriedWindowDrawStamp)
        assertFrameSubmission(fixture.moved, frame: fixture.expectedFloatingFrame(at: touch))
        fixture.cancel()
    }

    func testSettledCarryDoesNotReuseARejectedWorkspaceDraw() throws {
        let fixture = try makeMoveFixture(.horizontal)
        let refresh = fixture.controller.layoutRefreshController
        startSettledCarry(fixture)
        let disconnectedId = fixture.monitor.displayId + 1
        let gone = Monitor(
            id: .init(displayId: disconnectedId), displayId: disconnectedId, frame: fixture.monitor.frame,
            visibleFrame: fixture.monitor.visibleFrame, hasNotch: false, name: "Disconnected"
        )
        XCTAssertNil(fixture.base.manager.activeWorkspaceOrFirst(on: gone.id))
        try drawCarried(fixture, frame: fixture.startFrame, on: gone)
        XCTAssertNil(refresh.carriedWindowDrawStamp)
        let before = refresh.layoutBuildMetricsCounts().totalBuilds

        fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 8)))

        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, before + 1)
        XCTAssertNotNil(refresh.carriedWindowDrawStamp)
        fixture.cancel()
    }

    func testSettledCarryDoesNotAcceptAPlanThatOmitsItsMinimizedWindow() throws {
        let fixture = try makeMoveFixture(.horizontal)
        startSettledCarry(fixture)
        let refresh = fixture.controller.layoutRefreshController
        let frame = try XCTUnwrap(fixture.base.niri.liveColumnMove?.floatingFrame)
        XCTAssertTrue(fixture.base.manager.setWindowMinimized(true, token: fixture.moved))
        let projection = try fixture.projection()
        XCTAssertEqual(projection.frameChanges.map(\.token), [fixture.target])
        let peerFrame = try XCTUnwrap(projection.frameChanges.first).frame
        fixture.controller.axManager.confirmFrameWrite(for: fixture.target.windowId, frame: peerFrame)
        XCTAssertTrue(requireSettledFrame(fixture.target, in: fixture))
        XCTAssertFalse(requireSettledFrame(fixture.moved, in: fixture))
        XCTAssertNil(refresh.layoutState.pendingRefresh)
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        let builds = refresh.layoutBuildMetricsCounts().totalBuilds
        try drawCarried(fixture, frame: frame)
        XCTAssertEqual(refresh.layoutBuildMetricsCounts().totalBuilds, builds + 1)

        XCTAssertFalse(FrameApplyTrace.shared.dump().contains("win=\(fixture.moved.windowId) "))
        XCTAssertNil(refresh.carriedWindowDrawStamp)
        fixture.cancel()
    }

    func testSettledCarryDoesNotAcceptAFrameOnlyReceiptWhenAPeerNeedsShowing() throws {
        let fixture = try makeMoveFixture(.horizontal)
        startSettledCarry(fixture)
        let manager = fixture.base.manager
        let position = HiddenState.proportionalPosition(topLeft: fixture.targetFrame.origin, in: fixture.monitor.frame)
        manager.setHiddenState(.init(
            proportionalPosition: position,
            referenceMonitorId: fixture.monitor.id, reason: .layoutTransient(.right)
        ), for: fixture.target)

        XCTAssertFalse(requireSettledFrame(fixture.moved, in: fixture))
        XCTAssertNil(manager.hiddenState(for: fixture.target))
        XCTAssertNil(fixture.controller.layoutRefreshController.carriedWindowDrawStamp)
        fixture.cancel()
    }

    func testSettledCarryRechecksTheWorldAndPendingWorkAfterFrameSettlement() throws {
        enum Change: CaseIterable {
            case resizePeer, visibility
        }
        for change in Change.allCases {
            let fixture = try makeMoveFixture(.horizontal)
            startSettledCarry(fixture)
            let refresh = fixture.controller.layoutRefreshController
            let manager = fixture.base.manager
            let node = try XCTUnwrap(fixture.base.niriNode(fixture.target))
            let peer = try XCTUnwrap(fixture.base.niri.column(of: node))
            let current = try XCTUnwrap(fixture.base.niri.liveColumnMove?.floatingFrame)
            let ax = fixture.controller.axManager
            ax.confirmFrameWrite(for: fixture.moved.windowId, frame: current)
            ax.confirmFrameWrite(for: fixture.target.windowId, frame: fixture.targetFrame)
            let settlement = AXFrameSettlement(tokens: [fixture.target])
            var settled = false
            settlement.onChange = {
                settled = true
                switch change {
                case .resizePeer:
                    manager.withEngineMutationScope(in: fixture.workspace) {
                        peer.width = .fixed(fixture.targetFrame.width / 2)
                        peer.cachedWidth = 0
                    }
                case .visibility:
                    refresh.requestVisibilityRefresh(
                        reason: .windowDeminiaturized,
                        affectedWorkspaceIds: [fixture.workspace]
                    )
                }
            }
            ax.workspaceFrameSettlements.append(settlement)
            defer { ax.workspaceFrameSettlements.removeAll { $0 === settlement } }
            refresh.carriedWindowDrawStamp = nil

            try drawCarried(fixture, frame: current)

            XCTAssertTrue(settled)
            XCTAssertNil(refresh.carriedWindowDrawStamp, "\(change)")
            fixture.cancel()
        }
    }

    func testSettledCarryClearsItsAcceptedDrawOnReleaseAndCancellation() throws {
        let fixture = try makeMoveFixture(.horizontal)
        let refresh = fixture.controller.layoutRefreshController
        for phase in [NSEvent.Phase.cancelled, .ended, .changed] {
            startSettledCarry(fixture)
            if phase == .changed { fixture.base.niri.cancelInteractions(in: fixture.workspace) }
            let touch = fixture.slideWithinStartingWindow(1 / 8)

            fixture.send(fixture.event(at: touch, phase: phase))

            XCTAssertNil(fixture.handler.liveDragSession)
            XCTAssertNil(refresh.carriedWindowDrawStamp)
            if refresh.layoutState.pendingRefresh != nil { try executePendingRelayout(refresh) }
        }
    }
}
