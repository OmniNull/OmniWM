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

    func makeMoveFixture(_ kind: MoveKind, grouped: Bool = false) throws -> Fixture {
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
        let tokens = (1 ... (grouped ? 3 : 2)).map { host.addWindow($0, to: base.source, pid: 965_801, base) }
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

    private func assertFloating(_ fixture: Fixture, at touch: CGPoint) throws {
        let diff = try fixture.projection()
        XCTAssertEqual(
            diff.frameChanges.filter { $0.token == fixture.moved }.map(\.frame),
            [fixture.expectedFloatingFrame(at: touch)]
        )
        if fixture.kind == .dwindle {
            XCTAssertFalse(try XCTUnwrap(fixture.base.dwindle.interactiveMove).allowsInsertion)
        } else {
            XCTAssertFalse(try XCTUnwrap(fixture.base.niri.interactiveMove).allowsInsertion)
        }
    }
}
