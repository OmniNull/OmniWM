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
        let moveSpeed: CGFloat
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
            tokens.dropFirst().first ?? moved
        }

        func touch(at point: CGPoint, grabbedAt grab: CGPoint? = nil) -> CGPoint {
            Self.touch(
                at: point,
                from: grab ?? startFrame.center,
                start: startTouch,
                display: monitor.frame,
                speed: moveSpeed
            )
        }

        static func touch(
            at point: CGPoint,
            from grab: CGPoint,
            start: CGPoint,
            display: CGRect,
            speed: CGFloat
        ) -> CGPoint {
            CGPoint(
                x: start.x + (point.x - grab.x) / (display.width * speed),
                y: start.y + (point.y - grab.y) / (display.height * speed)
            )
        }

        func slideWithinStartingWindow(_ fraction: CGFloat) -> CGPoint {
            let point = kind == .vertical
                ? CGPoint(x: startFrame.midX + startFrame.width * fraction, y: startFrame.midY)
                : CGPoint(x: startFrame.midX, y: startFrame.midY + startFrame.height * fraction)
            return touch(at: point)
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
            let display = monitor.frame
            let x = startFrame.midX + (touch.x - startTouch.x) * display.width * moveSpeed
            let y = startFrame.midY + (touch.y - startTouch.y) * display.height * moveSpeed
            let lastScreenPoint = CGPoint(x: display.maxX - 1, y: display.maxY - 1)
            let frame = startFrame.offsetBy(
                dx: min(max(display.minX, x), lastScreenPoint.x) - startFrame.midX,
                dy: min(max(display.minY, y), lastScreenPoint.y) - startFrame.midY
            )
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
        adjacentDisplay: Bool = false,
        firstWindowId: Int = 1,
        moveSpeed: CGFloat = CGFloat(SettingsExport.Gestures.defaultMoveSensitivity),
        prepare: (CrossDisplayDragTests.Fixture, [WindowToken]) throws -> Void = { _, _ in }
    ) throws -> Fixture {
        let host = CrossDisplayDragTests()
        let frame = CGRect(x: 137, y: -241, width: 1600, height: 1200)
        let layouts: [LayoutType] = adjacentDisplay ? [.niri, .niri] : [kind == .dwindle ? .dwindle : .niri]
        let base = try host.makeFixture(
            layouts,
            sourceOrientation: kind == .vertical ? .vertical : .horizontal,
            frames: adjacentDisplay ? [frame, frame.offsetBy(dx: frame.width, dy: 0)] : [frame]
        )
        let controller = base.controller
        let gestures = controller.settings.gestures
        gestures.scrollEnabled = false
        gestures.workspaceSwipeEnabled = false
        gestures.windowMoveEnabled = true
        gestures.windowMoveFingerCount = .four
        gestures.windowResizeEnabled = false
        gestures.windowMoveSensitivity = Double(moveSpeed)
        controller.motionPolicy.animationsEnabled = false
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        let tokens = (0 ..< (grouped ? 3 : windows)).map {
            host.addWindow(firstWindowId + $0, to: base.source, pid: 965_801, base)
        }
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
        let target = try XCTUnwrap(initial[tokens.dropFirst().first ?? tokens[0]])
        let startTouch = CGPoint(x: 1 / 4, y: 1 / 4)
        let targetTouch = Fixture.touch(
            at: target.center, from: start.center, start: startTouch, display: base.monitors[0].frame, speed: moveSpeed
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
        controller.layoutRefreshController.layoutState.didExecuteEffectPlan = true
        let fixture = Fixture(
            base: base, kind: kind, tokens: tokens, initialFrames: initial, startFrame: start, targetFrame: target,
            startTouch: startTouch, targetTouch: targetTouch, moveSpeed: moveSpeed, events: events, blocker: blocker
        )
        addTeardownBlock { @MainActor in fixture.finish() }
        return fixture
    }

    func testTrackpadMovesThePhysicalWindowOnBothNiriAxesAndDwindleBeforeLanding() throws {
        for kind in MoveKind.allCases {
            let fixture = try makeMoveFixture(kind)
            let original = [[fixture.moved], [fixture.target]]
            XCTAssertEqual(fixture.order(), original)
            fixture.begin()
            fixture.move()
            XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
            XCTAssertEqual(fixture.handler.state.activeInteractionSource, .trackpadGesture)
            XCTAssertNil(fixture.handler.state.activeInteractionButton)
            if kind == .dwindle {
                XCTAssertEqual(fixture.order(), [[fixture.target], [fixture.moved]])
            } else {
                XCTAssertNotNil(fixture.base.niri.liveColumnMove?.narrowedSlot)
            }
            try assertFloating(fixture, at: fixture.targetTouch)
            fixture.release()
            XCTAssertFalse(fixture.handler.state.isMoving)
            XCTAssertEqual(fixture.order(), [[fixture.target], [fixture.moved]])
            XCTAssertNil(fixture.base.niri.liveColumnMove)
            XCTAssertNil(fixture.base.dwindle.interactiveMove)
        }
    }

    func testRepeatedTrackpadPointAndPhysicalMouseCannotRetargetOrSubmitAnotherFrame() throws {
        for kind in MoveKind.allCases {
            let fixture = try makeMoveFixture(kind)
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }
            let touch = fixture.slideWithinStartingWindow(1 / 4)
            fixture.begin()
            fixture.send(fixture.event(at: touch))
            try assertFloating(fixture, at: touch)
            let trace = FrameApplyTrace.shared.dump()
            XCTAssertTrue(trace.contains("win=\(fixture.moved.windowId) "))
            let sequence = fixture.base.manager.worldSeq
            fixture.send(fixture.event(at: touch, sample: 3))
            fixture.handler.dispatchMouseDragged(at: fixture.startFrame.center)
            fixture.handler.dispatchMouseUp(at: fixture.startFrame.center)
            XCTAssertEqual(FrameApplyTrace.shared.dump(), trace)
            XCTAssertEqual(fixture.base.manager.worldSeq, sequence)
            XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
            try assertFloating(fixture, at: touch)
            fixture.cancel()
        }
    }

    func testTrackpadCancellationAndReleaseAtTheStartRestoreTheOriginalPhysicalFrames() throws {
        for kind in MoveKind.allCases {
            for cancels in [true, false] {
                let fixture = try makeMoveFixture(kind)
                let touch = cancels ? fixture.targetTouch : fixture.slideWithinStartingWindow(1 / 4)
                fixture.begin()
                fixture.send(fixture.event(at: touch))
                try assertFloating(fixture, at: touch)
                if cancels {
                    fixture.cancel()
                } else {
                    fixture.send(fixture.event(at: fixture.startTouch))
                    fixture.release()
                }
                XCTAssertFalse(fixture.handler.state.isMoving)
                XCTAssertEqual(fixture.handler.tapInputs.gesturePhase, .idle)
                XCTAssertEqual(fixture.order(), [[fixture.moved], [fixture.target]])
                XCTAssertNil(fixture.base.niri.liveColumnMove)
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
            if kind != .dwindle {
                let point = try XCTUnwrap(fixture.handler.livePointer.location)
                XCTAssertTrue(fixture.monitor.frame.contains(point))
                XCTAssertEqual(fixture.base.niri.liveColumnMove?.workspaceId, fixture.workspace)
            }
            fixture.cancel()
            XCTAssertEqual(fixture.order(), [[fixture.moved], [fixture.target]])
        }
    }

    func testTrackpadTakesOneStackMemberInNiriAndTheWholeTileInDwindle() throws {
        for kind in MoveKind.allCases {
            let fixture = try makeMoveFixture(kind, grouped: true)
            let sibling = fixture.tokens[2]
            XCTAssertEqual(fixture.order(), [[fixture.moved, sibling], [fixture.target]])
            fixture.begin()
            fixture.move()
            if kind == .dwindle {
                XCTAssertEqual(fixture.order(), [[fixture.target], [fixture.moved, sibling]])
            } else {
                XCTAssertFalse(try XCTUnwrap(fixture.base.niri.liveColumnMove).isWholeColumn)
            }
            try assertFloating(fixture, at: fixture.targetTouch)
            fixture.release()
            if kind == .dwindle {
                XCTAssertEqual(fixture.order(), [[fixture.target], [fixture.moved, sibling]])
            } else {
                XCTAssertTrue(fixture.order().contains([sibling]))
                XCTAssertTrue(fixture.order().contains([fixture.moved]))
                XCTAssertTrue(fixture.order().contains([fixture.target]))
            }
        }
    }

    private func floatingFrame(of fixture: Fixture) -> CGRect? {
        fixture.kind == .dwindle
            ? fixture.base.dwindle.interactiveMove?.floatingFrame
            : fixture.base.niri.liveColumnMove?.floatingFrame
    }

    private func beginMoveWithStartedServices(_ fixture: Fixture) {
        fixture.controller.hasStartedServices = true
        fixture.begin()
        fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 4)))
        XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
        XCTAssertTrue(fixture.handler.state.isMoving)
        fixture.controller.surfaceReconciler.reconcileNow()
        XCTAssertNil(fixture.controller.surfaceReconciler.pendingReconcileScope)
    }

    private func sendChangedPoint(_ fixture: Fixture) {
        let before = floatingFrame(of: fixture)
        fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 8)))
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
            try assertFloating(fixture, at: fixture.slideWithinStartingWindow(1 / 8))
            fixture.send(fixture.event(at: fixture.targetTouch, sample: 3))
            reconciler.reconcileNow()
            XCTAssertNil(reconciler.pendingReconcileScope)

            fixture.send(fixture.event(at: fixture.targetTouch, phase: .ended, sample: 4))
            if kind == .dwindle { try executePendingRelayout(fixture.controller.layoutRefreshController) }

            XCTAssertEqual(fixture.order(), [[fixture.target], [fixture.moved]], "\(kind)")
            XCTAssertEqual(reconciler.pendingReconcileScope, .fullScene, "\(kind)")
        }
    }

    func testChangedTrackpadPointSchedulesTheFullSceneWhileTabRailsExist() throws {
        for kind in MoveKind.allCases {
            let fixture = try makeMoveFixture(kind, grouped: kind == .dwindle, windows: 3) { base, tokens in
                if kind != .dwindle {
                    try CrossDisplayDragTests().stack(tokens[2], onto: tokens[1], in: base.source, base)
                    let tab = try XCTUnwrap(base.niriNode(tokens[1]))
                    base.manager.withEngineMutationScope(in: base.source) {
                        let column = base.niri.findColumn(containing: tab, in: base.source)
                        column?.displayMode = .tabbed
                        base.niri.activateWindow(tab.id, in: base.source)
                    }
                }
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
            kind, grouped: kind == .dwindle, windows: Self.windowsWithAnOffscreenColumn,
            firstWindowId: Int(CGWindowID.max) - Self.windowsWithAnOffscreenColumn
        )
        let hidden = try XCTUnwrap(fixture.tokens.last)
        let controller = fixture.controller
        let refresh = controller.layoutRefreshController
        let relayout = try XCTUnwrap(fixture.base.manager.withBatchedLayoutBuild {
            kind == .dwindle
                ? controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [fixture.workspace])
                : controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [fixture.workspace])
        }.first)
        let ax = controller.axManager
        var physical = fixture.initialFrames
        for token in fixture.tokens where physical[token] == nil {
            physical[token] = fixture.base.frame(token)
        }
        var parks: [WindowToken: (frame: CGRect, side: HideSide)] = [:]
        for change in relayout.diff.visibilityChanges {
            guard case let .hide(token, side) = change else { continue }
            let seed = try XCTUnwrap(
                kind == .dwindle ? fixture.initialFrames[fixture.moved] : fixture.base.niriNode(token)?.frame
            )
            let origin = try XCTUnwrap(
                refresh.liveFrameHideOrigin(for: seed, monitor: fixture.monitor, side: side, reason: .layoutTransient)
            )
            let frame = CGRect(origin: origin, size: seed.size)
            physical[token] = frame
            parks[token] = (frame, side)
            ax.confirmFrameWrite(for: token.windowId, frame: frame)
            let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
            _ = ax.prepareParkFrameApplications([.init(
                pid: token.pid,
                window: try XCTUnwrap(entry.axRef),
                frame: frame
            )])
            if let request = ax.pendingParkFrameRequest(for: token.windowId) {
                XCTAssertEqual(request.frame, frame)
                XCTAssertTrue(ax.processParkFrameApplyResults([
                    WindowAdmissionTestSupport.successfulFrameResult(request: request)
                ]).isEmpty)
            }
        }
        XCTAssertNotNil(parks[hidden])
        refresh.fastFrameProvider = { token, _ in physical[token] }
        let bounds = Dictionary(uniqueKeysWithValues: physical.map {
            (UInt32($0.key.windowId), ScreenCoordinateSpace.toWindowServer(rect: $0.value))
        })
        refresh.windowBoundsProvider = { ids in bounds.filter { ids.contains($0.key) } }
        XCTAssertTrue(refresh.executeLayoutPlan(relayout))
        for (token, park) in parks {
            XCTAssertEqual(controller.workspaceManager.hiddenState(for: token)?.offscreenSide, park.side)
            XCTAssertEqual(ax.verifiedParkFrame(for: token.windowId), park.frame)
        }
        XCTAssertTrue(ax.pendingParkWindowIds.isEmpty)
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
            fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 4)))
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
            fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 4)))
            XCTAssertTrue(fixture.handler.state.isMoving)
            let world = fixture.base.manager.worldSeq
            if kind == .horizontal {
                XCTAssertNotNil(fixture.controller.layoutRefreshController.carriedWindowDrawStamp)
            }
            manager.markParkPending(for: hidden.windowId, pid: hidden.pid)
            XCTAssertEqual(fixture.base.manager.worldSeq, world)
            XCTAssertEqual(manager.pendingParkWindowIds, [hidden.windowId])
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
            fixture.send(fixture.event(at: fixture.slideWithinStartingWindow(1 / 4)))
            XCTAssertTrue(fixture.handler.state.isMoving)
            if kind == .horizontal {
                XCTAssertNotNil(controller.layoutRefreshController.carriedWindowDrawStamp)
            }
            controller.layoutRefreshController.applyLayoutTransientHides(
                [(entry, side)], monitor: fixture.monitor, isAnimationTick: true, preserveWorkspaceInactive: false
            )
            XCTAssertEqual(manager.pendingParkWindowIds, [hidden.windowId])
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
            XCTAssertTrue(try XCTUnwrap(fixture.base.dwindle.interactiveMove).allowsInsertion)
        } else {
            XCTAssertEqual(try XCTUnwrap(fixture.base.niri.liveColumnMove).windowToken, fixture.moved)
        }
    }
}
