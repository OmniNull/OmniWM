// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class TrackpadWindowMoveFrameTests: XCTestCase {
    enum MoveKind: CaseIterable {
        case horizontal, vertical, dwindle
    }

    static let windowsWithAnOffscreenColumn = 6

    struct MoveEvents {
        let begin: MouseEventHandler.GestureEventSnapshot
        let target: MouseEventHandler.GestureEventSnapshot
        let repeated: MouseEventHandler.GestureEventSnapshot
        let release: MouseEventHandler.GestureEventSnapshot
        let cancel: MouseEventHandler.GestureEventSnapshot
    }

    @MainActor
    struct Fixture {
        let base: CrossDisplayDragTests.Fixture
        let kind: MoveKind
        let tokens: [WindowToken]
        let initialFrames: [WindowToken: CGRect]
        let startFrame: CGRect
        let targetFrame: CGRect
        let startTouch: CGPoint
        let targetTouch: CGPoint
        let events: MoveEvents
        let blocker: DwindleLiveTitleBarDragTests.RefreshBlocker

        var controller: WMController {
            base.controller
        }

        var handler: MouseEventHandler {
            base.handler
        }

        var workspace: WorkspaceDescriptor.ID {
            base.source
        }

        var monitor: Monitor {
            base.monitors[0]
        }

        var moved: WindowToken {
            tokens[0]
        }

        var target: WindowToken {
            tokens[1]
        }

        func send(_ event: MouseEventHandler.GestureEventSnapshot) {
            handler.receiveTapGestureEvent(event)
        }

        func begin() {
            send(events.begin)
        }

        func move() {
            send(events.target)
        }

        func repeatPoint() {
            send(events.repeated)
        }

        func release() {
            send(events.release)
        }

        func cancel() {
            send(events.cancel)
        }

        func event(at touch: CGPoint, phase: NSEvent.Phase = .changed, sample: Int = 2)
            -> MouseEventHandler.GestureEventSnapshot
        {
            Self.event(location: startFrame.center, touch: touch, phase: phase, sample: sample)
        }

        static func event(location: CGPoint, touch: CGPoint, phase: NSEvent.Phase, sample: Int)
            -> MouseEventHandler.GestureEventSnapshot
        {
            let frameRate: TimeInterval = 120
            let touches = phase == .ended || phase == .cancelled ? [] : (0 ..< 4).map { _ in
                MouseEventHandler.GestureTouchSample(phase: .moved, normalizedPosition: touch)
            }
            return .init(
                location: location, phaseRawValue: phase.rawValue,
                timestamp: TimeInterval(sample) / frameRate, touches: touches
            )
        }

        func expectedFloatingFrame(at touch: CGPoint) -> CGRect {
            let point = TrackpadGestureIntent.windowGestureLocation(
                start: startFrame.center, startTouch: startTouch, currentTouch: touch,
                monitorFrame: monitor.frame,
                sensitivity: CGFloat(controller.settings.gestures.windowGestureSensitivity)
            )
            let frame = startFrame.offsetBy(dx: point.x - startFrame.midX, dy: point.y - startFrame.midY)
            guard kind == .dwindle else { return frame }
            let scale = controller.layoutRefreshController.buildMonitorSnapshot(for: monitor).scale
            return frame.roundedToPhysicalPixels(scale: scale)
        }

        func projection() throws -> WorkspaceLayoutDiff {
            let plans = base.manager.withBatchedLayoutBuild {
                if kind == .dwindle {
                    controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [workspace])
                } else {
                    controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspace])
                }
            }
            return try XCTUnwrap(plans.first).diff
        }

        func order() -> [[WindowToken]] {
            if kind == .dwindle {
                base.dwindle.root(for: workspace)?.collectAllLeaves().compactMap { $0.tile?.members.map(\.token) } ?? []
            } else {
                base.columns(workspace)
            }
        }

        func finish() {
            blocker.completion.finish()
            blocker.task.cancel()
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            handler.cleanup()
            controller.axManager.cleanup()
            controller.surfaceReconciler.cleanup()
        }
    }

    func makeMoveFixture(
        _ kind: MoveKind,
        grouped: Bool = false,
        windows: Int = 2,
        prepare: (CrossDisplayDragTests.Fixture, [WindowToken]) throws -> Void = { _, _ in }
    ) throws -> Fixture {
        let host = CrossDisplayDragTests()
        let base = try host.makeFixture(
            [kind == .dwindle ? .dwindle : .niri],
            sourceOrientation: kind == .vertical ? .vertical : .horizontal,
            frames: [CGRect(x: 137, y: -241, width: 1600, height: 1200)]
        )
        let controller = base.controller
        let gestures = controller.settings.gestures
        gestures.scrollEnabled = false
        gestures.workspaceSwipeEnabled = false
        gestures.windowMoveEnabled = true
        gestures.windowMoveFingerCount = .four
        gestures.windowResizeEnabled = false
        gestures.windowGestureSensitivity = 1
        controller.motionPolicy.animationsEnabled = false
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        let tokens = (1 ... (grouped ? 3 : windows)).map { host.addWindow($0, to: base.source, pid: 965_801, base) }
        for token in tokens { base.manager.setCachedConstraints(.unconstrained, for: token) }
        if grouped {
            if kind == .dwindle {
                base.manager.withEngineMutationScope(in: base.source) {
                    XCTAssertTrue(base.dwindle.groupWindow(tokens[2], into: tokens[0], in: base.source))
                    XCTAssertTrue(base.dwindle.activateWindow(tokens[0], in: base.source))
                }
            } else {
                try host.stack(tokens[2], onto: tokens[0], in: base.source, base)
            }
        }
        for column in base.niri.columns(in: base.source) {
            column.width = .proportion(1 / 3)
            column.height = .proportion(1 / 3)
            column.cachedWidth = 0
            column.cachedHeight = 0
        }
        try prepare(base, tokens)
        base.layout()
        XCTAssertTrue(base.manager.confirmManagedFocus(tokens[0], in: base.source, activateWorkspaceOnMonitor: false))
        let plans = base.manager.withBatchedLayoutBuild {
            kind == .dwindle
                ? controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [base.source])
                : controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [base.source])
        }
        let initial = Dictionary(uniqueKeysWithValues: try XCTUnwrap(plans.first).diff.frameChanges.map {
            ($0.token, $0.frame)
        })
        let start = try XCTUnwrap(initial[tokens[0]])
        let target = try XCTUnwrap(initial[tokens[1]])
        let startTouch = CGPoint(x: 1 / 4, y: 1 / 4)
        let targetTouch = CGPoint(
            x: startTouch.x + (target.midX - start.midX) / base.monitors[0].frame.width,
            y: startTouch.y + (target.midY - start.midY) / base.monitors[0].frame.height
        )
        let events = MoveEvents(
            begin: Fixture.event(location: start.center, touch: startTouch, phase: .began, sample: 0),
            target: Fixture.event(location: start.center, touch: targetTouch, phase: .changed, sample: 1),
            repeated: Fixture.event(location: start.center, touch: targetTouch, phase: .changed, sample: 2),
            release: Fixture.event(location: start.center, touch: targetTouch, phase: .ended, sample: 3),
            cancel: Fixture.event(location: start.center, touch: targetTouch, phase: .cancelled, sample: 3)
        )
        for (token, frame) in initial { controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame) }
        let blocker = DwindleLiveTitleBarDragTests().blockRefreshes(controller, workspace: base.source)
        let fixture = Fixture(
            base: base, kind: kind, tokens: tokens, initialFrames: initial, startFrame: start, targetFrame: target,
            startTouch: startTouch, targetTouch: targetTouch, events: events, blocker: blocker
        )
        addTeardownBlock { @MainActor in fixture.finish() }
        return fixture
    }

    func testTrackpadMovesThePhysicalWindowOnBothNiriAxesAndDwindleBeforeSwapRelease() throws {
        for kind in MoveKind.allCases {
            let fixture = try makeMoveFixture(kind)
            let original = [[fixture.moved], [fixture.target]]
            XCTAssertEqual(fixture.order(), original)
            fixture.begin()
            fixture.move()
            XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
            XCTAssertEqual(fixture.handler.state.activeInteractionSource, .trackpadGesture)
            XCTAssertNil(fixture.handler.state.activeInteractionButton)
            XCTAssertEqual(fixture.order(), original)
            try assertFloating(fixture, at: fixture.targetTouch)
            fixture.release()
            XCTAssertFalse(fixture.handler.state.isMoving)
            XCTAssertEqual(fixture.order(), [[fixture.target], [fixture.moved]])
            XCTAssertNil(fixture.base.niri.interactiveMove)
            XCTAssertNil(fixture.base.dwindle.interactiveMove)
        }
    }

    func testRepeatedTrackpadPointAndPhysicalMouseCannotRetargetOrSubmitAnotherFrame() throws {
        for kind in MoveKind.allCases {
            let fixture = try makeMoveFixture(kind)
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }
            fixture.begin()
            fixture.move()
            try assertFloating(fixture, at: fixture.targetTouch)
            let trace = FrameApplyTrace.shared.dump()
            XCTAssertTrue(trace.contains("win=\(fixture.moved.windowId) "))
            let sequence = fixture.base.manager.worldSeq
            fixture.repeatPoint()
            fixture.handler.dispatchMouseDragged(at: fixture.startFrame.center)
            fixture.handler.dispatchMouseUp(at: fixture.startFrame.center)
            XCTAssertEqual(FrameApplyTrace.shared.dump(), trace)
            XCTAssertEqual(fixture.base.manager.worldSeq, sequence)
            XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
            try assertFloating(fixture, at: fixture.targetTouch)
            fixture.cancel()
        }
    }

    func testTrackpadCancellationAndNoTargetReleaseRestoreTheOriginalPhysicalFrames() throws {
        for kind in MoveKind.allCases {
            for cancels in [true, false] {
                let fixture = try makeMoveFixture(kind)
                fixture.begin()
                fixture.move()
                try assertFloating(fixture, at: fixture.targetTouch)
                if cancels {
                    fixture.cancel()
                } else {
                    fixture.send(fixture.event(at: fixture.startTouch))
                    fixture.release()
                }
                XCTAssertFalse(fixture.handler.state.isMoving)
                XCTAssertEqual(fixture.handler.tapInputs.gesturePhase, .idle)
                XCTAssertEqual(fixture.order(), [[fixture.moved], [fixture.target]])
                XCTAssertNil(fixture.base.niri.interactiveMove)
                XCTAssertNil(fixture.base.dwindle.interactiveMove)
                let restored = try fixture.projection()
                XCTAssertEqual(
                    Dictionary(uniqueKeysWithValues: restored.frameChanges.map { ($0.token, $0.frame) }),
                    fixture.initialFrames
                )
            }
        }
    }

    func testTrackpadMotionRemainsMonitorClamped() throws {
        for kind in MoveKind.allCases {
            let fixture = try makeMoveFixture(kind)
            let beyondMonitor = CGPoint(x: fixture.startTouch.x + 2, y: fixture.startTouch.y + 2)
            fixture.begin()
            fixture.send(fixture.event(at: beyondMonitor))
            try assertFloating(fixture, at: beyondMonitor)
            XCTAssertEqual(fixture.order(), [[fixture.moved], [fixture.target]])
            fixture.cancel()
        }
    }

    func testTrackpadKeepsNiriWindowAndDwindleWholeTileSwapUnits() throws {
        for kind in MoveKind.allCases {
            let fixture = try makeMoveFixture(kind, grouped: true)
            let sibling = fixture.tokens[2]
            XCTAssertEqual(fixture.order(), [[fixture.moved, sibling], [fixture.target]])
            fixture.begin()
            fixture.move()
            XCTAssertEqual(fixture.order(), [[fixture.moved, sibling], [fixture.target]])
            try assertFloating(fixture, at: fixture.targetTouch)
            fixture.release()
            let expected = kind == .dwindle
                ? [[fixture.target], [fixture.moved, sibling]]
                : [[fixture.target, sibling], [fixture.moved]]
            XCTAssertEqual(fixture.order(), expected)
        }
    }

    private func midpoint(of fixture: Fixture) -> CGPoint {
        CGPoint(
            x: (fixture.startTouch.x + fixture.targetTouch.x) / 2,
            y: (fixture.startTouch.y + fixture.targetTouch.y) / 2
        )
    }

    private func floatingFrame(of fixture: Fixture) -> CGRect? {
        fixture.kind == .dwindle
            ? fixture.base.dwindle.interactiveMove?.floatingFrame
            : fixture.base.niri.interactiveMove?.floatingFrame
    }

    private func beginMoveWithStartedServices(_ fixture: Fixture) {
        fixture.controller.hasStartedServices = true
        fixture.begin()
        fixture.move()
        XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
        XCTAssertTrue(fixture.handler.state.isMoving)
        fixture.controller.surfaceReconciler.reconcileNow()
        XCTAssertNil(fixture.controller.surfaceReconciler.pendingReconcileScope)
    }

    private func sendChangedPoint(_ fixture: Fixture) {
        let before = floatingFrame(of: fixture)
        fixture.send(fixture.event(at: midpoint(of: fixture)))
        XCTAssertNotNil(before)
        XCTAssertNotEqual(floatingFrame(of: fixture), before)
    }

    private func renderOnDemandFramesWithoutAMovePoint(_ fixture: Fixture) {
        let refresh = fixture.controller.layoutRefreshController
        if fixture.kind == .dwindle {
            refresh.renderDwindleInteractiveResize(for: fixture.workspace)
        } else {
            refresh.renderInteractiveResize(for: fixture.workspace)
        }
    }

    func testChangedTrackpadPointSchedulesOnlyTheBorderPass() throws {
        for kind in MoveKind.allCases {
            let fixture = try makeMoveFixture(kind)
            let reconciler = fixture.controller.surfaceReconciler
            beginMoveWithStartedServices(fixture)
            XCTAssertTrue(reconciler.appliedScene.tabRails.isEmpty)
            XCTAssertFalse(fixture.controller.hasWindowOrLayoutEventSubscribers)

            sendChangedPoint(fixture)

            XCTAssertEqual(reconciler.pendingReconcileScope, .borderOnly, "\(kind)")
            try assertFloating(fixture, at: midpoint(of: fixture))
            fixture.send(fixture.event(at: fixture.targetTouch, sample: 3))
            reconciler.reconcileNow()
            XCTAssertNil(reconciler.pendingReconcileScope)

            fixture.send(fixture.event(at: fixture.targetTouch, phase: .ended, sample: 4))

            XCTAssertEqual(fixture.order(), [[fixture.target], [fixture.moved]], "\(kind)")
            XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene, "\(kind)")
        }
    }

    func testChangedTrackpadPointSchedulesTheFullSceneWhileTabRailsExist() throws {
        for kind in MoveKind.allCases {
            let fixture = try makeMoveFixture(kind, grouped: true)
            if kind != .dwindle {
                fixture.base.manager.withEngineMutationScope(in: fixture.workspace) {
                    let column = fixture.base.niri.columns(in: fixture.workspace)[0]
                    column.displayMode = .tabbed
                    column.setActiveTileIdx(0)
                }
                fixture.base.layout()
            }
            let reconciler = fixture.controller.surfaceReconciler
            beginMoveWithStartedServices(fixture)
            XCTAssertFalse(reconciler.appliedScene.tabRails.isEmpty, "\(kind)")

            sendChangedPoint(fixture)

            XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene, "\(kind)")
            fixture.cancel()
            fixture.controller.tabRailManager.removeAll()
        }
    }

    func testChangedTrackpadPointSchedulesTheFullSceneForWindowEventSubscribers() async throws {
        for kind in MoveKind.allCases {
            let fixture = try makeMoveFixture(kind)
            let controller = fixture.controller
            let bridge = IPCApplicationBridge(
                controller: controller,
                appVersion: "0.0.0-test",
                sessionToken: "session",
                authorizationToken: "token"
            )
            controller.ipcApplicationBridge = bridge
            let stream = await bridge.stream(for: .windowsChanged)
            XCTAssertTrue(controller.hasWindowOrLayoutEventSubscribers)
            beginMoveWithStartedServices(fixture)

            sendChangedPoint(fixture)

            XCTAssertEqual(controller.surfaceReconciler.pendingReconcileScope, .fullScene, "\(kind)")
            fixture.cancel()
            withExtendedLifetime(stream) {}
            controller.ipcApplicationBridge = nil
            await bridge.shutdown()
        }
    }

    func testRelayoutPlanAcceptedDuringATrackpadMoveSchedulesTheFullScene() throws {
        for kind in MoveKind.allCases {
            let fixture = try makeMoveFixture(kind)
            let controller = fixture.controller
            let reconciler = controller.surfaceReconciler
            beginMoveWithStartedServices(fixture)
            let plans = fixture.base.manager.withBatchedLayoutBuild {
                kind == .dwindle
                    ? controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [fixture.workspace])
                    : controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspace])
            }
            let plan = try XCTUnwrap(plans.first)
            XCTAssertFalse(plan.isInteractiveMove, "\(kind)")

            XCTAssertTrue(controller.layoutRefreshController.executeLayoutPlan(plan))

            XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene, "\(kind)")
            fixture.cancel()
        }
    }

    func testOnDemandFramesThatAreNotAMovePointScheduleTheFullScene() throws {
        for kind in MoveKind.allCases {
            for duringMove in [false, true] {
                let fixture = try makeMoveFixture(kind)
                let reconciler = fixture.controller.surfaceReconciler
                if duringMove {
                    beginMoveWithStartedServices(fixture)
                } else {
                    fixture.controller.hasStartedServices = true
                    reconciler.reconcileNow()
                }

                renderOnDemandFramesWithoutAMovePoint(fixture)

                XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene, "\(kind) during a move: \(duringMove)")
                if duringMove { fixture.cancel() }
            }
        }
    }

    private func offscreenFixture(_ kind: MoveKind) throws -> (fixture: Fixture, hidden: WindowToken) {
        let fixture = try makeMoveFixture(
            kind, grouped: kind == .dwindle, windows: Self.windowsWithAnOffscreenColumn
        )
        let hidden = try XCTUnwrap(fixture.tokens.last)
        let controller = fixture.controller
        let refresh = controller.layoutRefreshController
        let relayout = try XCTUnwrap(fixture.base.manager.withBatchedLayoutBuild {
            kind == .dwindle
                ? controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [fixture.workspace])
                : controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspace])
        }.first)
        let side = try XCTUnwrap(hideSide(of: hidden, in: relayout.diff))
        let seed = try XCTUnwrap(
            kind == .dwindle ? fixture.initialFrames[fixture.moved] : fixture.base.niriNode(hidden)?.frame
        )
        let origin = try XCTUnwrap(
            refresh.liveFrameHideOrigin(for: seed, monitor: fixture.monitor, side: side, reason: .layoutTransient)
        )
        let parked = CGRect(origin: origin, size: seed.size)
        refresh.fastFrameProvider = { token, _ in token == hidden ? parked : nil }
        XCTAssertTrue(refresh.executeLayoutPlan(relayout))
        XCTAssertEqual(controller.workspaceManager.hiddenState(for: hidden)?.offscreenSide, side)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: hidden))
        let request = try XCTUnwrap(controller.axManager.prepareParkFrameApplications([
            .init(pid: hidden.pid, window: XCTUnwrap(entry.axRef), frame: parked)
        ]).first)
        XCTAssertTrue(controller.axManager.processParkFrameApplyResults([
            WindowAdmissionTestSupport.successfulFrameResult(request: request)
        ]).isEmpty)
        XCTAssertEqual(controller.axManager.verifiedParkFrame(for: hidden.windowId), parked)
        XCTAssertFalse(controller.axManager.pendingParkWindowIds.contains(hidden.windowId))
        return (fixture, hidden)
    }

    private func hideSide(of token: WindowToken, in diff: WorkspaceLayoutDiff) -> HideSide? {
        for change in diff.visibilityChanges {
            if case let .hide(hidden, side) = change, hidden == token { return side }
        }
        return nil
    }

    private func tracedFrameEvents(for token: WindowToken) -> [Substring] {
        FrameApplyTrace.shared.dump().split(separator: "\n").filter { $0.contains("win=\(token.windowId) ") }
    }

    private func settledParkWasSubmitted(for token: WindowToken) -> Bool {
        tracedFrameEvents(for: token).contains { $0.contains("outcome=sls-park-intent/settled") }
    }

    func testChangedTrackpadPointDoesNotHideAnOffscreenWindowAgain() throws {
        for kind in MoveKind.allCases {
            let (fixture, hidden) = try offscreenFixture(kind)
            fixture.begin()
            fixture.move()
            XCTAssertTrue(fixture.handler.state.isMoving)
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }

            sendChangedPoint(fixture)

            XCTAssertFalse(tracedFrameEvents(for: fixture.moved).isEmpty, "\(kind)")
            XCTAssertEqual(tracedFrameEvents(for: hidden), [], "\(kind)")
            XCTAssertNotNil(try hideSide(of: hidden, in: fixture.projection()), "\(kind)")
            fixture.cancel()
        }
    }

    func testChangedTrackpadPointStillHidesAWindowWhoseParkIsPending() throws {
        for kind in MoveKind.allCases {
            let (fixture, hidden) = try offscreenFixture(kind)
            let manager = fixture.controller.axManager
            fixture.begin()
            fixture.move()
            XCTAssertTrue(fixture.handler.state.isMoving)
            manager.markParkPending(for: hidden.windowId, pid: hidden.pid)
            XCTAssertTrue(manager.pendingParkWindowIdsAwaitingSkyLightMove.contains(hidden.windowId))
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }

            sendChangedPoint(fixture)

            XCTAssertTrue(settledParkWasSubmitted(for: hidden), "\(kind)")
            fixture.cancel()
        }
    }

    func testChangedTrackpadPointConfirmsAParkAnAnimationFrameMadeByPositionOnly() throws {
        for kind in MoveKind.allCases {
            let (fixture, hidden) = try offscreenFixture(kind)
            let controller = fixture.controller
            let manager = controller.axManager
            let entry = try XCTUnwrap(controller.workspaceManager.entry(for: hidden))
            let side = try XCTUnwrap(controller.workspaceManager.hiddenState(for: hidden)?.offscreenSide)
            fixture.begin()
            fixture.move()
            XCTAssertTrue(fixture.handler.state.isMoving)
            controller.layoutRefreshController.applyLayoutTransientHides(
                [(entry, side)], monitor: fixture.monitor, isAnimationTick: true, preserveWorkspaceInactive: false
            )
            XCTAssertTrue(manager.pendingParkWindowIds.contains(hidden.windowId))
            XCTAssertNotNil(manager.skyLightLivePosition(for: hidden.windowId))
            XCTAssertFalse(manager.pendingParkWindowIdsAwaitingSkyLightMove.contains(hidden.windowId))
            XCTAssertNil(manager.pendingParkFrameRequest(for: hidden.windowId))
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }

            sendChangedPoint(fixture)

            XCTAssertTrue(settledParkWasSubmitted(for: hidden), "\(kind)")
            fixture.cancel()
        }
    }

    func testOnDemandFramesThatAreNotAMovePointHideAnOffscreenWindowAgain() throws {
        for kind in MoveKind.allCases {
            for duringMove in [false, true] {
                let (fixture, hidden) = try offscreenFixture(kind)
                if duringMove {
                    fixture.begin()
                    fixture.move()
                    XCTAssertTrue(fixture.handler.state.isMoving)
                }
                FrameApplyTrace.shared.beginCapture()
                defer { FrameApplyTrace.shared.endCapture() }

                renderOnDemandFramesWithoutAMovePoint(fixture)

                XCTAssertTrue(settledParkWasSubmitted(for: hidden), "\(kind) during a move: \(duringMove)")
                if duringMove { fixture.cancel() }
            }
        }
    }

    private func assertFloating(_ fixture: Fixture, at touch: CGPoint) throws {
        let diff = try fixture.projection()
        XCTAssertEqual(
            diff.frameChanges.filter { $0.token == fixture.moved }.map(\.frame),
            [fixture.expectedFloatingFrame(at: touch)]
        )
        if fixture.kind == .dwindle {
            XCTAssertFalse(try XCTUnwrap(fixture.base.dwindle.interactiveMove).allowsInsertion)
        } else {
            XCTAssertTrue(try XCTUnwrap(fixture.base.niri.interactiveMove).allowsInsertion)
        }
    }
}
