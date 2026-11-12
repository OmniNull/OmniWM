// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import XCTest

private final class ReportedFrame {
    var frame: CGRect?

    init(_ frame: CGRect?) {
        self.frame = frame
    }
}

private func nativeDragLocation(from frame: CGRect) -> CGPoint {
    CGPoint(x: (frame.midX + FrameTolerance.frameWrite).nextUp, y: frame.midY)
}

@MainActor
final class NativeResizeAdoptionTests: NiriInteractionTestCase {
    @MainActor
    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let tokens: [WindowToken]
        let nativeFrames: [Int: ReportedFrame]

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        var manager: WorkspaceManager {
            controller.workspaceManager
        }

        var phase: MouseInputState.NativeTitleBarDragPhase? {
            handler.state.nativeTitleBarDrag?.phase
        }

        func entry(_ token: WindowToken) throws -> WindowState {
            try XCTUnwrap(manager.entry(for: token))
        }

        func niriNode(_ token: WindowToken) throws -> NiriWindow {
            try XCTUnwrap(controller.niriEngine?.findNode(for: token, in: workspaceId))
        }

        func frames() throws -> [WindowToken: CGRect] {
            let workingFrame = controller.insetWorkingFrame(for: monitor)
            switch manager.activeLayoutKind(for: workspaceId) {
            case .niri:
                let gap = controller.innerGap(for: monitor)
                return try XCTUnwrap(controller.niriEngine).calculateLayout(
                    state: manager.niriViewportState(for: workspaceId),
                    workspaceId: workspaceId,
                    monitorFrame: workingFrame,
                    gaps: (horizontal: gap, vertical: gap),
                    orientation: controller.settings.monitors.effectiveOrientation(for: monitor)
                )
            case .dwindle:
                let engine = try XCTUnwrap(controller.dwindleEngine)
                return engine.calculateLayout(
                    for: workspaceId,
                    screen: workingFrame,
                    calculationSettings: controller.dwindleLayoutHandler.calculationSettings(
                        controller.resolvedDwindleSettings(for: monitor),
                        from: engine
                    )
                )
            }
        }

        func frame(_ token: WindowToken) throws -> CGRect {
            try XCTUnwrap(frames()[token])
        }

        func confirmLayout() throws {
            for (token, frame) in try frames() {
                nativeFrames[token.windowId]?.frame = frame
                controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
            }
        }

        func addUnrelatedAnimationWorkspace() throws -> (workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
            let displayId = monitor.displayId + 1
            let frame = monitor.frame.offsetBy(dx: monitor.frame.width, dy: 0)
            let animationMonitor = Monitor(
                id: .init(displayId: displayId),
                displayId: displayId,
                frame: frame,
                visibleFrame: frame,
                hasNotch: false,
                name: "Unrelated Animation"
            )
            let workspaceName = String(controller.settings.workspaces.configurations.count + 1)
            controller.settings.workspaces.configurations.append(WorkspaceConfiguration(
                name: workspaceName,
                monitorAssignment: .specificDisplay(OutputId(from: animationMonitor)),
                layoutType: .niri
            ))
            manager.applyMonitorConfigurationChange([monitor, animationMonitor])
            manager.applySettings()
            if controller.niriEngine == nil {
                controller.enableNiriLayout()
            } else {
                controller.syncMonitorsToNiriEngine()
            }
            let workspaceId = try XCTUnwrap(manager.workspaceId(named: workspaceName))
            XCTAssertEqual(manager.activeWorkspace(on: animationMonitor.id)?.id, workspaceId)
            try confirmLayout()
            controller.layoutRefreshController.resetState()
            return (workspaceId, animationMonitor)
        }

        func beginDrag(_ token: WindowToken) throws {
            handler.retireNativeTitleBarDragAtInputBoundary()
            handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            let start = try frame(token)
            XCTAssertFalse(handler.dispatchMouseDown(
                at: start.center,
                modifiers: [],
                windowIdUnderPointer: token.windowId
            ))
            handler.dispatchMouseDragged(at: nativeDragLocation(from: start))
            XCTAssertEqual(phase, .dragging)
        }

        func annotatedDrag(windowId: Int?, at location: CGPoint, timestamp: CGEventTimestamp? = nil) throws {
            MouseEventHandler._instance = handler
            let event = try XCTUnwrap(CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: ScreenCoordinateSpace.toWindowServer(point: location),
                mouseButton: .left
            ))
            if let timestamp { event.timestamp = timestamp }
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 0)
            event.setIntegerValueField(
                .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                value: Int64(windowId ?? 0)
            )
            XCTAssertEqual(MouseEventHandler.eventWindowIdUnderPointer(event), windowId)
            _ = MouseEventHandler.annotatedMoveTapCallback(OpaquePointer(bitPattern: 1)!, .leftMouseDragged, event, nil)
        }

        func release(_ token: WindowToken, at observed: CGRect) throws {
            let reported = ReportedFrame(controller.axManager.lastAppliedFrame(for: token.windowId))
            handler.nativeWindowFrameProvider = { _ in reported.frame }
            try beginDrag(token)
            reported.frame = observed
            let entry = try entry(token)
            XCTAssertTrue(handler.handleNativeTitleBarDragFrameChanged(for: entry))
            handler.dispatchMouseUp(at: observed.center)
        }

        func updateDrag(_ token: WindowToken, at observed: CGRect) {
            handler.nativeWindowFrameProvider = { _ in observed }
            controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
        }

        func wireFrameApplyCallbacks() {
            controller.axManager.onFrameApplySucceeded = { [weak controller] result in
                controller?.serviceLifecycleManager.handleFrameApplySucceeded(result)
            }
            controller.axManager.onStableSizeClamp = { [weak controller] result in
                controller?.adoptObservedMinimumAfterStableSizeClamp(result)
            }
        }

        func confirmWrite(of token: WindowToken) throws {
            _ = controller.axManager.cancelPendingFrameRetry(for: token.windowId)
            let target = try frame(token)
            let reference = try XCTUnwrap(entry(token).axRef)
            let request = try XCTUnwrap(controller.axManager.stageFrameWrite(
                for: AXFrameApplicationTarget(pid: token.pid, window: reference, frame: target)
            ))
            controller.axManager
                .handleFrameApplyResults([WindowAdmissionTestSupport.successfulFrameResult(request: request)])
            nativeFrames[token.windowId]?.frame = target
            XCTAssertEqual(controller.axManager.lastAppliedFrame(for: token.windowId), target)
        }

        func refuseWrite(of token: WindowToken, growingWidthBy growth: CGFloat) throws {
            let target = try frame(token)
            let window = try XCTUnwrap(entry(token).axRef)
            let observed = CGRect(x: target.minX, y: target.minY, width: target.width + growth, height: target.height)
            controller.axManager.forceApplyNextFrame(for: token.windowId)
            let first = try XCTUnwrap(controller.axManager.stageFrameWrite(
                for: AXFrameApplicationTarget(pid: token.pid, window: window, frame: target)
            ))
            controller.axManager.handleFrameApplyResults([
                WindowAdmissionTestSupport.verificationMismatchFrameResult(request: first, observed: observed)
            ])
            _ = controller.axManager.cancelPendingFrameRetry(for: token.windowId)
            let retry = try XCTUnwrap(WindowAdmissionTestSupport.frameRequest(
                controller.axManager.frameLedger,
                pid: token.pid,
                window: window,
                frame: target,
                isRetry: true
            ))
            controller.axManager.handleFrameApplyResults([
                WindowAdmissionTestSupport.verificationMismatchFrameResult(request: retry, observed: observed)
            ])
        }
    }

    func testSettingOffKeepsCorrectingNativeEdgeResizes() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_001 + index))
            fixture.controller.settings.gestures.adoptNativeResize = false
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let before = try fixture.frames()
            let worldSeq = fixture.manager.worldSeq
            let start = try fixture.frame(fixture.tokens[0])

            try fixture.release(fixture.tokens[0], at: grown(start, right: 200))

            XCTAssertEqual(fixture.phase, .awaitingCorrection, "\(layout)")
            XCTAssertEqual(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
                [fixture.workspaceId]
            )
            XCTAssertEqual(try fixture.frames(), before, "\(layout)")
            XCTAssertEqual(fixture.manager.worldSeq, worldSeq, "\(layout)")
        }
    }

    func testNiriRightEdgeWidensOnlyThatColumn() throws {
        let fixture = try makeFixture(.niri, pid: 834_011)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (resized, neighbor) = (fixture.tokens[0], fixture.tokens[1])
        let start = try fixture.frame(resized)
        let neighborWidth = try fixture.frame(neighbor).width
        let worldSeq = fixture.manager.worldSeq

        try fixture.release(resized, at: grown(start, right: 200))

        XCTAssertEqual(try fixture.frame(resized).width, start.width + 200, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(try fixture.frame(neighbor).width, neighborWidth, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
        XCTAssertGreaterThan(fixture.manager.worldSeq, worldSeq)
        XCTAssertTrue(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh != nil
                || fixture.controller.niriLayoutHandler.scrollAnimationByDisplay[fixture.monitor.displayId]
                == fixture.workspaceId
        )
    }

    func testNiriLeftEdgeKeepsTheRightEdgeInPlace() throws {
        let fixture = try makeFixture(.niri, pid: 834_012)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let resized = fixture.tokens[1]
        let start = try fixture.frame(resized)

        try fixture.release(resized, at: grown(start, left: 150))

        let adopted = try fixture.frame(resized)
        XCTAssertEqual(adopted.width, start.width + 150, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(adopted.maxX, start.maxX, accuracy: FrameTolerance.frameWrite)
    }

    func testNiriStackedEdgeSetsTheExactHeight() throws {
        let fixture = try makeFixture(.niri, stacked: true, pid: 834_013)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (top, bottom) = try stackedTopAndBottom(fixture)
        let topStart = try fixture.frame(top)
        let bottomStart = try fixture.frame(bottom)

        try fixture.release(top, at: grown(topStart, bottom: 100))

        XCTAssertEqual(try fixture.frame(top).height, topStart.height + 100, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(try fixture.frame(bottom).height, bottomStart.height - 100, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(try fixture.frame(top).width, topStart.width, accuracy: FrameTolerance.frameWrite)
    }

    func testStackedShrinkUsesTheRenderedSpanNotTheStoredOne() throws {
        for portrait in [false, true] {
            let fixture = try makeFixture(.niri, stacked: true, portrait: portrait, pid: portrait ? 834_015 : 834_014)
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let (resized, sibling) = try portrait ? stackedLeftAndRight(fixture) : stackedTopAndBottom(fixture)
            let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
            let resizedNode = try fixture.niriNode(resized)
            let siblingNode = try fixture.niriNode(sibling)
            if portrait {
                resizedNode.windowWidth = .fixed(workingFrame.width)
                siblingNode.constraints.minSize.width = workingFrame.width / 2
            } else {
                resizedNode.height = .fixed(workingFrame.height)
                siblingNode.constraints.minSize.height = workingFrame.height / 2
            }
            try fixture.confirmLayout()
            let rendered = try fixture.frame(resized)
            XCTAssertLessThan(
                portrait ? rendered.width : rendered.height,
                portrait ? workingFrame.width : workingFrame.height
            )
            let shrunk = portrait ? grown(rendered, right: -50) : grown(rendered, bottom: -50)

            try fixture.release(resized, at: shrunk)

            let adopted = try fixture.frame(resized)
            XCTAssertEqual(
                portrait ? adopted.width : adopted.height,
                portrait ? shrunk.width : shrunk.height,
                accuracy: FrameTolerance.frameWrite
            )
        }
    }

    func testClampedStackedResizeLeavesTheStackUntouched() throws {
        let fixture = try makeFixture(.niri, stacked: true, pid: 834_016)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (top, bottom) = try stackedTopAndBottom(fixture)
        let topNode = try fixture.niriNode(top)
        let bottomNode = try fixture.niriNode(bottom)
        bottomNode.constraints.minSize.height = try fixture.frame(bottom).height
        let heights = (topNode.height, bottomNode.height)
        let before = try fixture.frames()

        try fixture.release(top, at: grown(fixture.frame(top), bottom: 100))

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertEqual(topNode.height, heights.0)
        XCTAssertEqual(bottomNode.height, heights.1)
        XCTAssertEqual(try fixture.frames(), before)
    }

    func testDwindleSplitEdgeMovesTheSharedSplit() throws {
        let fixture = try makeFixture(.dwindle, pid: 834_021)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (left, right) = (fixture.tokens[0], fixture.tokens[1])
        let leftStart = try fixture.frame(left)
        let rightStart = try fixture.frame(right)
        XCTAssertLessThan(leftStart.maxX, rightStart.minX + 1)

        try fixture.release(left, at: grown(leftStart, right: 150))

        XCTAssertEqual(try fixture.frame(left).width, leftStart.width + 150, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(try fixture.frame(right).width, rightStart.width - 150, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
    }

    func testDwindleNativeResizeWritesOnlyNeighborsBeforeMouseUp() throws {
        let fixture = try makeFixture(.dwindle, pid: 834_081)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (left, right) = (fixture.tokens[0], fixture.tokens[1])
        let leftStart = try fixture.frame(left)
        let rightStart = try fixture.frame(right)
        try fixture.beginDrag(left)
        defer { FrameApplyTrace.shared.endCapture() }
        let deltas: [CGFloat] = [80, 150, 150, -40]
        var writtenWidths: [CGFloat] = []

        for (index, delta) in deltas.enumerated() {
            FrameApplyTrace.shared.beginCapture()
            fixture.updateDrag(left, at: grown(leftStart, right: delta))

            XCTAssertEqual(try fixture.frame(left).width, leftStart.width + delta, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(
                try fixture.frame(right).width,
                rightStart.width - delta,
                accuracy: FrameTolerance.frameWrite
            )
            XCTAssertEqual(fixture.phase, .dragging)
            XCTAssertTrue(fixture.handler.isInteractiveGestureActive)
            XCTAssertNotNil(fixture.controller.dwindleEngine?.interactiveResize)
            XCTAssertNil(firstWriteTarget(for: left))
            if index == 2 {
                XCTAssertNil(firstWriteTarget(for: right))
            } else {
                writtenWidths.append(try XCTUnwrap(firstWriteTarget(for: right)).width)
            }
        }
        XCTAssertLessThan(writtenWidths[1], writtenWidths[0])
        XCTAssertGreaterThan(writtenWidths[2], writtenWidths[1])

        fixture.handler.dispatchMouseUp(at: leftStart.center)

        XCTAssertEqual(try fixture.frame(left).width, leftStart.width - 40, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: left))
    }

    func testDwindleNativeResizeCapturesStartBeforeForwardingMouseDown() async throws {
        let fixture = try makeFixture(.dwindle, pid: 835_261)
        let (left, right) = (fixture.tokens[0], fixture.tokens[1])
        let leftStart = try fixture.frame(left)
        let rightStart = try fixture.frame(right)
        let delta: CGFloat = 140
        let observed = grown(leftStart, right: delta)
        let expectedNeighbor = grown(rightStart, left: -delta)
        let press = CGPoint(x: leftStart.maxX - FrameTolerance.frameWrite, y: leftStart.midY)
        let drag = CGPoint(x: press.x + delta, y: press.y)
        let reported = try XCTUnwrap(fixture.nativeFrames[left.windowId])
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        MouseEventHandler._instance = fixture.handler
        fixture.handler.syncTapFilterSnapshot()
        let tap = fixture.handler.inputTapThread
        let snapshot = tap.filterSnapshot
        let windowServerFrame = ScreenCoordinateSpace.toWindowServer(rect: leftStart)
        let intake = fixture.controller.eventIntake
        intake.open(sink: fixture.controller.eventInterpreter)
        defer { intake.close() }

        let returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            tap.evaluateLeftMouseDown(at: press, modifiers: [], timestamp: 0, snapshot: snapshot) {
                XCTAssertFalse(Thread.isMainThread)
                return [left: windowServerFrame]
            }
            returned.signal()
        }
        XCTAssertEqual(returned.wait(timeout: .now() + 1), .success)
        reported.frame = observed
        intake.drainNow()

        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        fixture.handler.receiveAnnotatedNativeMouseDragged(at: drag, windowIdUnderPointer: left.windowId)
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(left.windowId))
        XCTAssertEqual(firstWriteTarget(for: right), expectedNeighbor)
        XCTAssertNil(firstWriteTarget(for: left))

        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.receiveTapMouseUp(at: drag)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        let target = try XCTUnwrap(firstWriteTarget(for: left))
        XCTAssertEqual(target.width, observed.width, accuracy: FrameTolerance.frameWrite)
    }

    func testDwindleNativeResizeKeepsDragDeliveredBeforeMainMouseDown() async throws {
        let fixture = try makeFixture(.dwindle, pid: 835_271)
        let (left, right) = (fixture.tokens[0], fixture.tokens[1])
        let leftStart = try fixture.frame(left)
        let rightStart = try fixture.frame(right)
        let delta: CGFloat = 140
        let observed = grown(leftStart, right: delta)
        let press = CGPoint(x: leftStart.maxX - FrameTolerance.frameWrite, y: leftStart.midY)
        let drag = CGPoint(x: press.x + delta, y: press.y)
        let reported = try XCTUnwrap(fixture.nativeFrames[left.windowId])
        let intake = fixture.controller.eventIntake
        intake.open(sink: fixture.controller.eventInterpreter)
        defer { intake.close() }

        fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        MouseEventHandler._instance = fixture.handler
        fixture.handler.syncTapFilterSnapshot()
        let tap = fixture.handler.inputTapThread

        tap.evaluateLeftMouseDown(at: press, modifiers: [], timestamp: 10, snapshot: tap.filterSnapshot) {
            [left: ScreenCoordinateSpace.toWindowServer(rect: leftStart)]
        }
        reported.frame = observed
        XCTAssertTrue(EventIntake.post(.mouseDragged(button: .left, location: drag)))
        try fixture.annotatedDrag(windowId: left.windowId, at: drag, timestamp: 20)
        intake.drainNow()

        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(left.windowId))
        XCTAssertEqual(firstWriteTarget(for: right), grown(rightStart, left: -delta))

        fixture.handler.pressedMouseButtonsProvider = { 0 }
        let release = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: ScreenCoordinateSpace.toWindowServer(point: drag),
            mouseButton: .left
        ))
        XCTAssertNotNil(tap.evaluateTap(type: .leftMouseUp, event: release))
        intake.drainNow()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(firstWriteTarget(for: left)?.width, observed.width)
    }

    func testDwindleNativeResizeKeepsFirstDragWhenAnotherPressIsQueued() async throws {
        let fixture = try makeFixture(.dwindle, pid: 835_272)
        let (left, right) = (fixture.tokens[0], fixture.tokens[1])
        let leftStart = try fixture.frame(left)
        let rightStart = try fixture.frame(right)
        let delta: CGFloat = 140
        let observed = grown(leftStart, right: delta)
        let press = CGPoint(x: leftStart.maxX - FrameTolerance.frameWrite, y: leftStart.midY)
        let drag = CGPoint(x: press.x + delta, y: press.y)
        let reported = try XCTUnwrap(fixture.nativeFrames[left.windowId])
        let intake = fixture.controller.eventIntake
        intake.open(sink: fixture.controller.eventInterpreter)
        defer { intake.close() }

        fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        MouseEventHandler._instance = fixture.handler
        fixture.handler.syncTapFilterSnapshot()
        let tap = fixture.handler.inputTapThread

        tap.evaluateLeftMouseDown(at: press, modifiers: [], timestamp: 10, snapshot: tap.filterSnapshot) {
            [left: ScreenCoordinateSpace.toWindowServer(rect: leftStart)]
        }
        reported.frame = observed
        XCTAssertTrue(EventIntake.post(.mouseDragged(button: .left, location: drag)))
        XCTAssertTrue(EventIntake.post(.leftMouseUp(location: drag)))
        tap.evaluateLeftMouseDown(at: rightStart.center, modifiers: [], timestamp: 30, snapshot: tap.filterSnapshot) {
            [right: ScreenCoordinateSpace.toWindowServer(rect: rightStart)]
        }
        try fixture.annotatedDrag(windowId: left.windowId, at: drag, timestamp: 20)
        intake.drainNow()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try fixture.frame(left).width, observed.width, accuracy: FrameTolerance.frameWrite)
    }

    func testDwindleNativeResizeRejectsPriorDragTargetAfterNextPressDrains() throws {
        let fixture = try makeFixture(.dwindle, pid: 835_275)
        let (first, second) = (fixture.tokens[0], fixture.tokens[1])
        let firstFrame = try fixture.frame(first)
        let secondFrame = try fixture.frame(second)
        let firstDrag = nativeDragLocation(from: firstFrame)
        let intake = fixture.controller.eventIntake
        intake.open(sink: fixture.controller.eventInterpreter)
        defer { intake.close() }
        fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        fixture.handler.syncTapFilterSnapshot()
        let tap = fixture.handler.inputTapThread

        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        tap.evaluateLeftMouseDown(at: firstFrame.center, modifiers: [], timestamp: 10, snapshot: tap.filterSnapshot) {
            [first: ScreenCoordinateSpace.toWindowServer(rect: firstFrame)]
        }
        XCTAssertTrue(EventIntake.post(.mouseDragged(button: .left, location: firstDrag)))
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        XCTAssertTrue(EventIntake.post(.leftMouseUp(location: firstDrag)))
        intake.drainNow()
        XCTAssertTrue(fixture.handler.state.nativeTitleBarDragFallbackReleased)

        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        tap.evaluateLeftMouseDown(at: secondFrame.center, modifiers: [], timestamp: 30, snapshot: tap.filterSnapshot) {
            [second: ScreenCoordinateSpace.toWindowServer(rect: secondFrame)]
        }
        intake.drainNow()
        XCTAssertTrue(fixture.handler.state.awaitsNativeTitleBarDragTarget)
        XCTAssertEqual(fixture.handler.state.nativeResizeStart?.token, second)

        try fixture.annotatedDrag(windowId: first.windowId, at: firstDrag, timestamp: 20)
        XCTAssertNotEqual(
            fixture.handler.state.nativeTitleBarDrag?.token,
            first,
            "The prior drag claimed the new press"
        )

        try fixture.annotatedDrag(windowId: second.windowId, at: nativeDragLocation(from: secondFrame), timestamp: 40)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, second)
    }

    func testDwindleQueuedReleaseWithNilDragTargetAllowsOverview() throws {
        let drainOrders = [
            (beforeRelease: false, beforeAnnotation: true),
            (beforeRelease: false, beforeAnnotation: false),
            (beforeRelease: true, beforeAnnotation: false)
        ]
        for (index, drain) in drainOrders.enumerated() {
            let fixture = try makeFixture(.dwindle, pid: pid_t(835_276 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            defer { fixture.controller.windowActionHandler.invalidateOverviewDeferredActionsForServiceStop() }
            fixture.controller.isEnabled = true
            try fixture.controller.settings.setOverviewMouseButton(2)
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let location = nativeDragLocation(from: start)
            let intake = fixture.controller.eventIntake
            intake.open(sink: fixture.controller.eventInterpreter)
            defer { intake.close() }
            fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
            fixture.handler.syncTapFilterSnapshot()
            let tap = fixture.handler.inputTapThread

            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            tap.evaluateLeftMouseDown(at: start.center, modifiers: [], timestamp: 10, snapshot: tap.filterSnapshot) {
                [token: ScreenCoordinateSpace.toWindowServer(rect: start)]
            }
            XCTAssertTrue(EventIntake.post(.mouseDragged(button: .left, location: location)))
            if drain.beforeRelease { intake.drainNow() }
            fixture.handler.pressedMouseButtonsProvider = { 0 }
            XCTAssertTrue(EventIntake.post(.leftMouseUp(location: location)))

            if drain.beforeAnnotation {
                intake.drainNow()
                XCTAssertTrue(fixture.handler.state.nativeTitleBarDragFallbackReleased)
            }
            try fixture.annotatedDrag(windowId: nil, at: location, timestamp: 20)
            if !drain.beforeAnnotation { intake.drainNow() }

            XCTAssertFalse(fixture.handler.state.awaitsNativeTitleBarDragTarget, "\(drain)")
            let captured = fixture.handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2)
            XCTAssertTrue(captured, "\(drain)")
            XCTAssertTrue(fixture.controller.isOverviewOpen(), "\(drain)")
            if captured {
                XCTAssertTrue(fixture.handler.receiveTapOtherMouseButton(type: .otherMouseUp, button: 2))
            }
        }
    }

    func testDwindleNativeResizeKeepsItsQueuedReleaseWhenABlockedRightPressArrives() async throws {
        let fixture = try makeFixture(.dwindle, pid: 835_274)
        let left = fixture.tokens[0]
        let leftStart = try fixture.frame(left)
        let delta: CGFloat = 140
        let observed = grown(leftStart, right: delta)
        let press = CGPoint(x: leftStart.maxX - FrameTolerance.frameWrite, y: leftStart.midY)
        let drag = CGPoint(x: press.x + delta, y: press.y)
        let reported = try XCTUnwrap(fixture.nativeFrames[left.windowId])
        let intake = fixture.controller.eventIntake
        intake.open(sink: fixture.controller.eventInterpreter)
        defer { intake.close() }

        fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        MouseEventHandler._instance = fixture.handler
        fixture.handler.syncTapFilterSnapshot()
        let tap = fixture.handler.inputTapThread

        tap.evaluateLeftMouseDown(at: press, modifiers: [], timestamp: 10, snapshot: tap.filterSnapshot) {
            [left: ScreenCoordinateSpace.toWindowServer(rect: leftStart)]
        }
        reported.frame = observed
        XCTAssertTrue(EventIntake.post(.mouseDragged(button: .left, location: drag)))
        try fixture.annotatedDrag(windowId: left.windowId, at: drag, timestamp: 20)
        intake.drainNow()
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(left.windowId))
        XCTAssertNotNil(fixture.handler.state.nativeTitleBarDrag)

        let ownedFrame = CGRect(x: -800, y: -800, width: 40, height: 40)
        let surfaceId = "blocked-right-press-\(left.windowId)"
        fixture.controller.ownedWindowRegistry.registerWindowNumber(
            surfaceId: surfaceId,
            policy: SurfacePolicy(
                kind: .utility,
                hitTestPolicy: .interactive,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: true
            ),
            windowNumber: left.windowId + 10_000,
            frameProvider: { ownedFrame },
            visibilityProvider: { true }
        )
        defer { fixture.controller.ownedWindowRegistry.unregister(surfaceId: surfaceId) }
        XCTAssertTrue(fixture.handler.shouldBlockOwnWindowInput(at: ownedFrame.center))

        fixture.handler.pressedMouseButtonsProvider = { 0 }
        XCTAssertTrue(EventIntake.post(.leftMouseUp(location: drag)))
        XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: ownedFrame.center, modifiers: [], button: .right))
        intake.drainNow()
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(firstWriteTarget(for: left)?.width, observed.width)
    }

    func testVisibilityChangeDiscardsPendingNativeResizePress() throws {
        let fixture = try makeFixture(.dwindle, pid: 835_273)
        let left = fixture.tokens[0]
        let frame = try fixture.frame(left)
        let intake = fixture.controller.eventIntake
        intake.open(sink: fixture.controller.eventInterpreter)
        defer { intake.close() }
        fixture.handler.syncTapFilterSnapshot()
        let tap = fixture.handler.inputTapThread

        func press(timestamp: CGEventTimestamp) {
            tap.evaluateLeftMouseDown(
                at: frame.center,
                modifiers: [],
                timestamp: timestamp,
                snapshot: tap.filterSnapshot
            ) {
                [left: ScreenCoordinateSpace.toWindowServer(rect: frame)]
            }
        }

        press(timestamp: 10)
        fixture.handler.handleAppVisibilityChanged()
        intake.drainNow()
        XCTAssertFalse(fixture.handler.state.awaitsNativeTitleBarDragTarget)
        XCTAssertNil(fixture.handler.state.nativeResizeStart)

        press(timestamp: 20)
        intake.drainNow()
        XCTAssertTrue(fixture.handler.state.awaitsNativeTitleBarDragTarget)
        XCTAssertEqual(fixture.handler.state.nativeResizeStart?.token, left)
    }

    func testDwindleNativeResizeReturningToStartRestoresTheSplit() throws {
        let fixture = try makeFixture(.dwindle, pid: 834_082)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        let before = try fixture.frames()
        try fixture.beginDrag(token)
        fixture.updateDrag(token, at: grown(start, right: 150))
        XCTAssertNotEqual(try fixture.frames(), before)

        fixture.updateDrag(token, at: start)
        fixture.handler.dispatchMouseUp(at: start.center)

        XCTAssertEqual(try fixture.frames(), before)
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
    }

    func testDwindleNativeResizeFollowsLeftTopAndBottomEdges() throws {
        let cases: [(Bool, Int, (CGRect) -> CGRect)] = [
            (false, 1, { self.grown($0, left: 80) }),
            (true, 0, { self.grown($0, top: 80) }),
            (true, 2, { self.grown($0, bottom: 80) })
        ]
        for (index, (stacked, tokenIndex, change)) in cases.enumerated() {
            let fixture = try makeFixture(
                .dwindle, stacked: stacked, windowCount: stacked ? 3 : 2, pid: pid_t(834_096 + index)
            )
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[tokenIndex]
            let observed = change(try fixture.frame(token))
            try fixture.beginDrag(token)

            fixture.updateDrag(token, at: observed)

            XCTAssertTrue(try fixture.frame(token).approximatelyEqual(
                to: observed,
                tolerance: FrameTolerance.frameWrite
            ))
            XCTAssertEqual(fixture.phase, .dragging)
            fixture.handler.dispatchMouseUp(at: observed.center)
            XCTAssertTrue(try fixture.frame(token).approximatelyEqual(
                to: observed,
                tolerance: FrameTolerance.frameWrite
            ))
        }
    }

    func testDwindleNativeResizeUsesTheFinalFrameWithoutAccumulatingTheLiveDelta() throws {
        let fixture = try makeFixture(.dwindle, pid: 834_083)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        try fixture.beginDrag(token)
        fixture.updateDrag(token, at: grown(start, right: 100))
        fixture.handler.nativeWindowFrameProvider = { _ in self.grown(start, right: 180) }
        fixture.handler.nativeWindowFrameFallbackProvider = { _ in
            XCTFail("a readable fast frame must not use the AX fallback")
            return nil
        }

        fixture.handler.dispatchMouseUp(at: start.center)

        XCTAssertEqual(try fixture.frame(token).width, start.width + 180, accuracy: FrameTolerance.frameWrite)
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
        let worldSeq = fixture.manager.worldSeq
        fixture.updateDrag(token, at: grown(start, right: 200))
        XCTAssertEqual(try fixture.frame(token).width, start.width + 180, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(fixture.manager.worldSeq, worldSeq)
    }

    func testDwindleNativeResizeReleaseFallsBackToAXForTheFinalFrame() throws {
        let fixture = try makeFixture(.dwindle, pid: 834_114)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        let finalFrame = grown(start, right: 180)
        var fallbackReads = 0
        fixture.handler.nativeWindowFrameFallbackProvider = { window in
            XCTAssertEqual(window.windowId, token.windowId)
            fallbackReads += 1
            return finalFrame
        }
        try fixture.beginDrag(token)
        fixture.updateDrag(token, at: grown(start, right: 100))
        fixture.handler.nativeWindowFrameProvider = { _ in nil }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: try fixture.entry(token)))
        XCTAssertEqual(fallbackReads, 0)
        XCTAssertEqual(try fixture.frame(token).width, start.width + 100, accuracy: FrameTolerance.frameWrite)
        FrameEffectTraceContext.beginCapture(generation: 1)
        FrameApplyTrace.shared.beginCapture()
        defer {
            FrameApplyTrace.shared.endCapture()
            FrameEffectTraceContext.endCapture()
        }

        fixture.handler.dispatchMouseUp(at: finalFrame.center)

        XCTAssertEqual(fallbackReads, 1)
        XCTAssertTrue(try fixture.frame(token).approximatelyEqual(to: finalFrame, tolerance: FrameTolerance.frameWrite))
        for window in fixture.tokens {
            XCTAssertEqual(frameDecisions(for: window).count, 1, FrameApplyTrace.shared.dump())
            let target = try fixture.frame(window)
            XCTAssertTrue(firstWriteTarget(for: window)?.approximatelyEqual(
                to: target,
                tolerance: FrameTolerance.frameWrite
            ) == true)
        }
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
    }

    func testDwindleNativeResizeReleaseAppliesFinalFramesOnce() throws {
        for (index, finalDelta) in [CGFloat?(180), 100, nil].enumerated() {
            let fixture = try makeFixture(.dwindle, pid: pid_t(834_110 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            try fixture.beginDrag(token)
            fixture.updateDrag(token, at: grown(start, right: 100))
            fixture.handler.nativeWindowFrameProvider = { _ in finalDelta.map { self.grown(start, right: $0) } }
            FrameEffectTraceContext.beginCapture(generation: 1)
            FrameApplyTrace.shared.beginCapture()
            defer {
                FrameApplyTrace.shared.endCapture()
                FrameEffectTraceContext.endCapture()
            }

            fixture.handler.dispatchMouseUp(at: start.center)

            XCTAssertEqual(
                try fixture.frame(token).width,
                start.width + (finalDelta ?? 100),
                accuracy: FrameTolerance.frameWrite
            )
            for window in fixture.tokens {
                XCTAssertEqual(frameDecisions(for: window).count, 1, "case \(index): \(FrameApplyTrace.shared.dump())")
                let target = try fixture.frame(window)
                XCTAssertTrue(firstWriteTarget(for: window)?.approximatelyEqual(
                    to: target,
                    tolerance: FrameTolerance.frameWrite
                ) == true)
            }
            XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
            XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
        }
    }

    func testDwindleNativeResizeReleaseAtMinimumSizesForcesTheFinalFrame() throws {
        let fixture = try makeFixture(.dwindle, pid: 834_113)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let before = try fixture.frames()
        for (token, frame) in before {
            fixture.manager.setCachedConstraints(
                WindowSizeConstraints(minSize: CGSize(width: frame.width, height: 1), maxSize: .zero, isFixed: false),
                for: token
            )
        }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        try fixture.beginDrag(token)
        fixture.updateDrag(token, at: grown(start, right: 100))
        XCTAssertEqual(try fixture.frames(), before)
        XCTAssertNotNil(fixture.controller.dwindleEngine?.interactiveResize)
        fixture.handler.nativeWindowFrameProvider = { _ in self.grown(start, right: 200) }
        FrameEffectTraceContext.beginCapture(generation: 1)
        FrameApplyTrace.shared.beginCapture()
        defer {
            FrameApplyTrace.shared.endCapture()
            FrameEffectTraceContext.endCapture()
        }

        fixture.handler.dispatchMouseUp(at: start.center)

        XCTAssertEqual(try fixture.frames(), before)
        for window in fixture.tokens {
            XCTAssertEqual(frameDecisions(for: window).count, 1, FrameApplyTrace.shared.dump())
        }
        XCTAssertTrue(frameDecisions(for: token).first?.contains(" event=ledger-prepared ") == true)
        XCTAssertEqual(firstWriteTarget(for: token), start)
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
    }

    func testDwindleNativeResizeCleansUpAtInputAndWindowLifecycleBoundaries() throws {
        let cancellations: [(MouseEventHandler, WindowToken) -> Void] = [
            { handler, _ in handler.handleInputSuppressionBegan() },
            { handler, _ in handler.handleAppVisibilityChanged() },
            { handler, token in handler.discardNativeTitleBarDrag(for: token) },
            { handler, _ in handler.cleanup() }
        ]
        for (index, cancel) in cancellations.enumerated() {
            let fixture = try makeFixture(.dwindle, pid: pid_t(834_084 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            try fixture.beginDrag(token)
            fixture.updateDrag(token, at: grown(start, right: 100))
            XCTAssertNotNil(fixture.controller.dwindleEngine?.interactiveResize)

            cancel(fixture.handler, token)

            XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
            XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
            XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
        }
    }

    func testDwindleNativeCornerResizeCanDiscoverTheSecondAxisLater() throws {
        let fixture = try makeFixture(.dwindle, stacked: true, windowCount: 3, pid: 834_088)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        let aboveStart = try fixture.frame(fixture.tokens[2])
        try fixture.beginDrag(token)
        fixture.updateDrag(token, at: grown(start, right: 100))

        fixture.updateDrag(token, at: grown(start, right: 150, top: 80))

        XCTAssertEqual(try fixture.frame(token).width, start.width + 150, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(try fixture.frame(token).height, start.height + 80, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(
            try fixture.frame(fixture.tokens[2]).height,
            aboveStart.height - 80,
            accuracy: FrameTolerance.frameWrite
        )
        fixture.handler.dispatchMouseUp(at: start.center)
        XCTAssertEqual(try fixture.frame(token).width, start.width + 150, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(try fixture.frame(token).height, start.height + 80, accuracy: FrameTolerance.frameWrite)
    }

    func testDwindleNativeResizeAtMinimumSizesStillEndsAfterReturningToStart() throws {
        let fixture = try makeFixture(.dwindle, pid: 834_089)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let before = try fixture.frames()
        for (token, frame) in before {
            fixture.manager.setCachedConstraints(
                WindowSizeConstraints(minSize: CGSize(width: frame.width, height: 1), maxSize: .zero, isFixed: false),
                for: token
            )
        }
        let start = try fixture.frame(token)
        try fixture.beginDrag(token)
        fixture.updateDrag(token, at: grown(start, right: 100))
        XCTAssertEqual(try fixture.frames(), before)
        XCTAssertNotNil(fixture.controller.dwindleEngine?.interactiveResize)

        fixture.updateDrag(token, at: start)
        fixture.handler.dispatchMouseUp(at: start.center)

        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
        XCTAssertEqual(try fixture.frames(), before)
    }

    func testDisablingNativeResizeStopsLiveUpdatesAndReleasesTheEngine() throws {
        let fixture = try makeFixture(.dwindle, pid: 834_090)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        try fixture.beginDrag(token)
        fixture.updateDrag(token, at: grown(start, right: 100))

        fixture.controller.settings.gestures.adoptNativeResize = false
        fixture.updateDrag(token, at: grown(start, right: 180))

        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
        XCTAssertEqual(try fixture.frame(token).width, start.width + 100, accuracy: FrameTolerance.frameWrite)
        fixture.handler.dispatchMouseUp(at: start.center)
        XCTAssertEqual(try fixture.frame(token).width, start.width + 100, accuracy: FrameTolerance.frameWrite)
    }

    func testNeighborFrameNotificationsDoNotScheduleRelayoutDuringNativeResize() async throws {
        let fixture = try makeFixture(.dwindle, pid: 834_095)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (token, neighbor) = (fixture.tokens[0], fixture.tokens[1])
        let start = try fixture.frame(token)
        try fixture.beginDrag(token)
        fixture.updateDrag(token, at: grown(start, right: 100))
        let frame = try fixture.frame(neighbor)
        fixture.controller.axEventHandler.frameObservations.query = { windowId in
            WindowServerInfo(id: windowId, pid: neighbor.pid, level: 0, frame: frame)
        }

        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(neighbor.windowId))
        let observation = try XCTUnwrap(
            fixture.controller.axEventHandler.frameObservations.byWindowId[UInt32(neighbor.windowId)]
        )
        await observation.task.value

        XCTAssertTrue(fixture.controller.axEventHandler.frameObservations.byWindowId.isEmpty)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertTrue(fixture.handler.isInteractiveGestureActive)
    }

    func testNativeResizeWithoutALiveDwindleTargetLeavesTheLayoutUnchangedWhileDragging() throws {
        let cases: [(LayoutType, Bool, (CGRect, CGFloat) -> CGRect)] = [
            (.niri, true, { self.grown($0, right: $1) }),
            (.dwindle, false, { self.grown($0, right: $1) }),
            (.dwindle, true, { $0.offsetBy(dx: $1, dy: 0) }),
            (.dwindle, true, { self.grown($0, left: $1) })
        ]
        for (index, (layout, enabled, change)) in cases.enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_091 + index))
            fixture.controller.settings.gestures.adoptNativeResize = enabled
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let before = try fixture.frames()
            let start = try fixture.frame(token)
            try fixture.beginDrag(token)
            let worldSeq = fixture.manager.worldSeq

            for delta: CGFloat in [20, 60, 100, 40] {
                fixture.updateDrag(token, at: change(start, delta))

                XCTAssertEqual(try fixture.frames(), before)
                XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
                XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
                XCTAssertEqual(fixture.manager.worldSeq, worldSeq, "case \(index), delta \(delta)")
            }
        }
    }

    func testDwindleOuterEdgeIsCorrectedAndACornerAdoptsOnlyTheSplitAxis() throws {
        let outer = try makeFixture(.dwindle, pid: 834_022)
        let outerBlocker = blockRefreshes(outer)
        defer { unblockRefreshes(outer, blocker: outerBlocker) }
        let before = try outer.frames()

        try outer.release(outer.tokens[0], at: grown(try outer.frame(outer.tokens[0]), left: 100))

        XCTAssertEqual(outer.phase, .awaitingCorrection)
        XCTAssertEqual(try outer.frames(), before)

        let corner = try makeFixture(.dwindle, pid: 834_023)
        let cornerBlocker = blockRefreshes(corner)
        defer { unblockRefreshes(corner, blocker: cornerBlocker) }
        let start = try corner.frame(corner.tokens[0])

        try corner.release(corner.tokens[0], at: grown(grown(start, right: 150), top: -60))

        let adopted = try corner.frame(corner.tokens[0])
        XCTAssertEqual(adopted.width, start.width + 150, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(adopted.height, start.height, accuracy: FrameTolerance.frameWrite)
    }

    func testPlainMovesAndTwoSidedResizesAreStillCorrected() throws {
        var pid: pid_t = 834_031
        for layout in [LayoutType.niri, .dwindle] {
            for change in [
                { (frame: CGRect) in frame.offsetBy(dx: 40, dy: 0) },
                { (frame: CGRect) in frame.offsetBy(dx: 0, dy: -30) },
                { (frame: CGRect) in frame.insetBy(dx: -20, dy: 0) }
            ] {
                let fixture = try makeFixture(layout, pid: pid)
                pid += 1
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                let before = try fixture.frames()
                let worldSeq = fixture.manager.worldSeq

                try fixture.release(fixture.tokens[0], at: change(try fixture.frame(fixture.tokens[0])))

                XCTAssertEqual(fixture.phase, .awaitingCorrection, "\(layout)")
                XCTAssertEqual(try fixture.frames(), before, "\(layout)")
                XCTAssertEqual(fixture.manager.worldSeq, worldSeq, "\(layout)")
            }
        }
    }

    func testDelayedFinalFrameIsAdoptedOnce() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_041 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            fixture.handler.nativeWindowFrameProvider = { _ in start }
            try fixture.beginDrag(token)
            fixture.handler.dispatchMouseUp(at: start.center)
            XCTAssertEqual(fixture.phase, .awaitingFrameChange)

            fixture.handler.nativeWindowFrameProvider = { _ in self.grown(start, right: 200) }
            XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: try fixture.entry(token)))
            XCTAssertEqual(try fixture.frame(token).width, start.width + 200, accuracy: FrameTolerance.frameWrite)
            let worldSeq = fixture.manager.worldSeq

            fixture.handler.nativeWindowFrameProvider = { _ in self.grown(start, right: 260) }
            XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: try fixture.entry(token)))
            XCTAssertEqual(try fixture.frame(token).width, start.width + 200, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(fixture.manager.worldSeq, worldSeq)
        }
    }

    func testDelayedResizeAfterASettledCorrectionIsCorrected() throws {
        let fixture = try makeFixture(.niri, pid: 834_042)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        try fixture.release(token, at: start.offsetBy(dx: 40, dy: 0))
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        fixture.handler.nativeWindowFrameProvider = { _ in start }
        fixture.handler.handleNativeTitleBarDragFrameApplySucceeded(
            try succeeded(fixture, token: token, frame: start, requestId: 1)
        )
        XCTAssertEqual(fixture.phase, .awaitingFrameChange)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)

        fixture.handler.nativeWindowFrameProvider = { _ in self.grown(start, right: 200) }
        XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: try fixture.entry(token)))

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
    }

    func testPendingWriteAtDragStartDisablesAdoption() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_043 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let reference = try XCTUnwrap(fixture.entry(token).axRef)
            fixture.controller.axManager.applyFramesParallel([
                AXFrameApplicationTarget(
                    pid: token.pid,
                    window: reference,
                    frame: start.offsetBy(dx: 0, dy: -20)
                )
            ])
            XCTAssertTrue(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
            let grownFrame = grown(start, right: 200)
            fixture.handler.nativeWindowFrameProvider = { _ in grownFrame }

            try fixture.beginDrag(token)
            XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
            fixture.handler.dispatchMouseUp(at: grownFrame.center)

            XCTAssertEqual(fixture.phase, .awaitingCorrection)
            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
        }
    }

    func testFrameFallbackAdoptsNativeResizeThroughTheNormalDragLifecycle() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_101 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let observed = grown(start, right: 120)
            let reported = ReportedFrame(start)
            fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            XCTAssertFalse(fixture.handler.dispatchMouseDown(at: start.center, modifiers: []))
            fixture.handler.dispatchMouseDragged(at: nativeDragLocation(from: start))
            XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
            XCTAssertEqual(fixture.handler.state.nativeTitleBarDragFallbackToken, token)
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }

            reported.frame = observed
            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))

            XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame, start, "\(layout)")
            XCTAssertTrue(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            XCTAssertNil(firstWriteTarget(for: token))
            XCTAssertEqual(
                try fixture.frame(token).width,
                layout == .dwindle ? observed.width : start.width,
                accuracy: FrameTolerance.frameWrite,
                "\(layout)"
            )

            fixture.handler.dispatchMouseUp(at: observed.center)

            XCTAssertEqual(
                try fixture.frame(token).width,
                observed.width,
                accuracy: FrameTolerance.frameWrite,
                "\(layout)"
            )
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
        }
    }

    func testMouseDownWithoutAFastFrameDoesNotReadAXOrArmResize() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(835_201 + index))
            let start = try fixture.frame(fixture.tokens[0])
            var fallbackReads = 0
            fixture.handler.nativeWindowFrameProvider = { _ in nil }
            fixture.handler.nativeWindowFrameFallbackProvider = { _ in
                fallbackReads += 1
                return start
            }

            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))

            XCTAssertEqual(fallbackReads, 0)
            XCTAssertNil(fixture.handler.state.nativeResizeStart)
            XCTAssertTrue(fixture.handler.state.awaitsNativeTitleBarDragTarget)
            XCTAssertEqual(fixture.handler.state.nativeTitleBarDragFallbackToken, fixture.tokens[0])
        }
    }

    func testPointerBeyondTheFrameToleranceConfirmsNativeResize() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(835_211 + index))
            let start = try fixture.frame(fixture.tokens[0])
            let location = CGPoint(x: (start.midX + FrameTolerance.frameWrite).nextUp, y: start.midY)
            fixture.handler.nativeWindowFrameProvider = { _ in start }

            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
            fixture.handler.receiveTapMouseDragged(at: location)

            XCTAssertEqual(fixture.handler.state.nativeResizeStart?.wasDragged, true)
        }
    }

    func testNativeFrameMismatchBeforeMouseDownDoesNotBecomeAResize() throws {
        var scenario = 0
        for layout in [LayoutType.niri, .dwindle] {
            for annotated in [false, true] {
                let fixture = try makeFixture(layout, pid: pid_t(835_001 + scenario))
                scenario += 1
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                let token = fixture.tokens[0]
                let start = try fixture.frame(token)
                let reported = ReportedFrame(grown(start, right: 80))
                fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                if annotated {
                    fixture.handler.receiveAnnotatedNativeMouseDragged(
                        at: nativeDragLocation(from: start),
                        windowIdUnderPointer: token.windowId
                    )
                } else {
                    fixture.handler.receiveTapMouseDragged(at: nativeDragLocation(from: start))
                }

                reported.frame = grown(start, right: 140)
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                fixture.handler.receiveTapMouseUp(at: start.center)

                XCTAssertEqual(
                    try fixture.frame(token).width,
                    start.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), annotated=\(annotated)"
                )
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
            }
        }
    }

    func testReleasedFallbackJitterDoesNotAdoptAProgrammaticResize() throws {
        var scenario = 0
        for layout in [LayoutType.niri, .dwindle] {
            for jitter in [FrameTolerance.frameWrite / 2, FrameTolerance.frameWrite] {
                for earlyFrame in [false, true] {
                    let fixture = try makeFixture(layout, pid: pid_t(835_021 + scenario))
                    scenario += 1
                    let blocker = blockRefreshes(fixture)
                    defer { unblockRefreshes(fixture, blocker: blocker) }
                    let token = fixture.tokens[0]
                    let start = try fixture.frame(token)
                    let reported = ReportedFrame(start)
                    let location = CGPoint(x: start.midX + jitter, y: start.midY)
                    fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                    fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                    XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                    fixture.handler.receiveTapMouseDragged(at: location)
                    if earlyFrame {
                        reported.frame = grown(start, right: jitter)
                        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                    }
                    fixture.handler.pressedMouseButtonsProvider = { 0 }
                    fixture.handler.receiveTapMouseUp(at: location)

                    reported.frame = grown(start, right: 140)
                    fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))

                    XCTAssertEqual(
                        try fixture.frame(token).width,
                        start.width,
                        accuracy: FrameTolerance.frameWrite,
                        "\(layout), jitter=\(jitter), earlyFrame=\(earlyFrame)"
                    )
                    XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                    XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
                }
            }
        }
    }

    func testAnnotatedJitterDoesNotAdoptAProgrammaticResizeAfterRelease() throws {
        var scenario = 0
        for layout in [LayoutType.niri, .dwindle] {
            let threshold = FrameTolerance.frameWrite
            let deltas = [
                CGPoint(x: threshold / 2, y: 0), CGPoint(x: 0, y: -threshold / 2),
                CGPoint(x: threshold, y: -threshold)
            ]
            for delta in deltas {
                let fixture = try makeFixture(layout, pid: pid_t(835_101 + scenario))
                scenario += 1
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
                let token = fixture.tokens[0]
                let start = try fixture.frame(token)
                let location = CGPoint(x: start.midX + delta.x, y: start.midY + delta.y)
                let reported = ReportedFrame(start)
                fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                fixture.handler.receiveTapMouseDragged(at: location)
                try fixture.annotatedDrag(windowId: token.windowId, at: location)
                fixture.handler.pressedMouseButtonsProvider = { 0 }
                fixture.handler.receiveTapMouseUp(at: location)

                reported.frame = grown(start, right: 140)
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))

                XCTAssertEqual(
                    try fixture.frame(token).width,
                    start.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), delta=\(delta)"
                )
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            }
        }
    }

    func testReleasedFrameFallbackAdoptsTheDelayedFinalNativeResize() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_111 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let observed = grown(start, right: 140)
            fixture.handler.nativeWindowFrameProvider = { _ in start }
            fixture.handler.pressedMouseButtonsProvider = { 0 }
            XCTAssertFalse(fixture.handler.dispatchMouseDown(at: start.center, modifiers: []))
            fixture.handler.dispatchMouseDragged(at: nativeDragLocation(from: start))
            fixture.handler.dispatchMouseUp(at: start.center)
            XCTAssertTrue(fixture.handler.state.nativeTitleBarDragFallbackReleased)

            fixture.handler.nativeWindowFrameProvider = { _ in observed }
            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))

            XCTAssertEqual(
                try fixture.frame(token).width,
                observed.width,
                accuracy: FrameTolerance.frameWrite,
                "\(layout)"
            )
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
        }
    }

    func testFrameFallbackCanPrecedeTheQueuedDragEvent() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_181 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let observed = grown(start, right: 140)
            let reported = ReportedFrame(start)
            fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            XCTAssertFalse(fixture.handler.dispatchMouseDown(at: start.center, modifiers: []))

            reported.frame = observed
            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
            XCTAssertEqual(
                try fixture.frame(token).width,
                start.width,
                accuracy: FrameTolerance.frameWrite,
                "\(layout), before drag"
            )
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            fixture.handler.dispatchQueuedMouseDragged(at: nativeDragLocation(from: start), button: .left)
            XCTAssertEqual(
                try fixture.frame(token).width,
                layout == .dwindle ? observed.width : start.width,
                accuracy: FrameTolerance.frameWrite,
                "\(layout), confirmed drag"
            )
            fixture.handler.dispatchMouseUp(at: observed.center)

            XCTAssertEqual(
                try fixture.frame(token).width,
                observed.width,
                accuracy: FrameTolerance.frameWrite,
                "\(layout)"
            )
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
        }
    }

    func testHeldFallbackClickDoesNotAdoptAProgrammaticResize() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_191 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let observed = grown(start, right: 140)
            let reported = ReportedFrame(start)
            fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))

            reported.frame = observed
            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))

            XCTAssertEqual(
                try fixture.frame(token).width,
                start.width,
                accuracy: FrameTolerance.frameWrite,
                "\(layout), held"
            )
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)

            fixture.handler.receiveTapMouseUp(at: observed.center)

            XCTAssertEqual(
                try fixture.frame(token).width,
                start.width,
                accuracy: FrameTolerance.frameWrite,
                "\(layout), released"
            )
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
        }
    }

    func testSizeChangingPendingFrameJobsDoNotRebaseTheNativeResize() throws {
        var scenario = 0
        for retry in [false, true] {
            for annotated in [false, true] {
                for queuedBeforeMouseDown in [false, true] {
                    let fixture = try makeFixture(.niri, pid: pid_t(834_201 + scenario))
                    scenario += 1
                    let blocker = blockRefreshes(fixture)
                    defer { unblockRefreshes(fixture, blocker: blocker) }
                    let token = fixture.tokens[0]
                    let start = try fixture.frame(token)
                    let reported = ReportedFrame(start)
                    fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                    fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                    if !queuedBeforeMouseDown {
                        XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                    }
                    let engine = try XCTUnwrap(fixture.controller.niriEngine)
                    let column = try XCTUnwrap(engine.findColumn(
                        containing: fixture.niriNode(token), in: fixture.workspaceId
                    ))
                    fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
                        engine.setContainerPrimarySpan(
                            column,
                            change: .setFixed(start.width - 100),
                            context: .init(
                                workspaceId: fixture.workspaceId,
                                motion: .disabled,
                                workingFrame: fixture.controller.insetWorkingFrame(for: fixture.monitor),
                                gaps: fixture.controller.innerGap(for: fixture.monitor),
                                orientation: .horizontal
                            ),
                            state: &state
                        )
                    }
                    let target = try fixture.frame(token)
                    XCTAssertEqual(target.width, start.width - 100, accuracy: FrameTolerance.frameWrite)
                    if retry {
                        fixture.controller.axManager.scheduleFrameRetry(AXFrameRetryRequest(
                            requestId: 1, pid: token.pid, windowId: token.windowId,
                            expectedWindow: try XCTUnwrap(fixture.entry(token).axRef),
                            frame: target, currentFrameHint: start
                        ))
                    } else {
                        XCTAssertNotNil(try fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                            pid: token.pid, window: XCTUnwrap(fixture.entry(token).axRef), frame: target
                        )))
                    }
                    if queuedBeforeMouseDown {
                        XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                    }
                    if annotated {
                        fixture.handler.receiveAnnotatedNativeMouseDragged(
                            at: nativeDragLocation(from: start),
                            windowIdUnderPointer: token.windowId
                        )
                    } else {
                        fixture.handler.dispatchMouseDragged(at: nativeDragLocation(from: start))
                    }

                    let observed = grown(start, right: 60)
                    reported.frame = observed
                    fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                    XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
                    fixture.handler.receiveTapMouseUp(at: observed.center)

                    XCTAssertEqual(
                        try fixture.frame(token).width, target.width, accuracy: FrameTolerance.frameWrite,
                        "retry=\(retry), annotated=\(annotated), queuedBeforeMouseDown=\(queuedBeforeMouseDown)"
                    )
                    XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                }
            }
        }
    }

    func testCompletedSizeWriteBetweenMouseDownAndDragDoesNotRebaseTheNativeResize() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            for annotated in [false, true] {
                let fixture = try makeFixture(layout, pid: pid_t(834_231 + index * 2 + (annotated ? 1 : 0)))
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                let token = fixture.tokens[0]
                let start = try fixture.frame(token)
                let reported = ReportedFrame(start)
                fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))

                switch layout {
                case .niri,
                     .defaultLayout:
                    let engine = try XCTUnwrap(fixture.controller.niriEngine)
                    let column = try XCTUnwrap(engine.findColumn(
                        containing: fixture.niriNode(token), in: fixture.workspaceId
                    ))
                    fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
                        engine.setContainerPrimarySpan(
                            column,
                            change: .setFixed(start.width - 100),
                            context: .init(
                                workspaceId: fixture.workspaceId,
                                motion: .disabled,
                                workingFrame: fixture.controller.insetWorkingFrame(for: fixture.monitor),
                                gaps: fixture.controller.innerGap(for: fixture.monitor),
                                orientation: .horizontal
                            ),
                            state: &state
                        )
                    }
                case .dwindle:
                    let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
                    fixture.manager.withEngineMutationScope(in: fixture.workspaceId) {
                        engine.setSelectedNode(
                            engine.findNode(for: token, in: fixture.workspaceId),
                            in: fixture.workspaceId
                        )
                        XCTAssertTrue(engine.cycleSplitRatio(forward: false, in: fixture.workspaceId))
                    }
                }
                let target = try fixture.frame(token)
                XCTAssertGreaterThan(abs(target.width - start.width), FrameTolerance.frameWrite)
                try fixture.confirmWrite(of: token)
                reported.frame = target
                XCTAssertFalse(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
                if annotated {
                    fixture.handler.receiveAnnotatedNativeMouseDragged(
                        at: nativeDragLocation(from: start),
                        windowIdUnderPointer: token.windowId
                    )
                } else {
                    fixture.handler.dispatchQueuedMouseDragged(
                        at: nativeDragLocation(from: start),
                        button: .left
                    )
                }

                let observed = grown(target, right: 60)
                reported.frame = observed
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                fixture.handler.receiveTapMouseUp(at: observed.center)

                XCTAssertEqual(
                    try fixture.frame(token).width,
                    target.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), annotated=\(annotated)"
                )
                XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            }
        }
    }

    func testAnnotatedDragWithoutAMouseDownBaselineDoesNotAdoptTheResize() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_241 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let reported = ReportedFrame(start)
            fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            fixture.controller.axManager.invalidateAppliedFrame(for: token.windowId)
            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
            XCTAssertNil(fixture.handler.state.nativeResizeStart)
            try fixture.confirmLayout()

            fixture.handler.receiveAnnotatedNativeMouseDragged(
                at: nativeDragLocation(from: start),
                windowIdUnderPointer: token.windowId
            )
            let observed = grown(start, right: 100)
            reported.frame = observed
            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
            fixture.handler.receiveTapMouseUp(at: observed.center)

            XCTAssertEqual(
                try fixture.frame(token).width,
                start.width,
                accuracy: FrameTolerance.frameWrite,
                "\(layout)"
            )
            XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
        }
    }

    func testAnnotatedDragAfterMouseUpAdoptsTheDeferredResize() throws {
        var scenario = 0
        for layout in [LayoutType.niri, .dwindle] {
            for frameOrder in 0 ..< 3 {
                let fixture = try makeFixture(layout, pid: pid_t(835_041 + scenario))
                scenario += 1
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
                let token = fixture.tokens[0]
                let start = try fixture.frame(token)
                let observed = grown(start, right: 140)
                let location = nativeDragLocation(from: start)
                let reported = ReportedFrame(start)
                fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                if frameOrder != 0 { fixture.handler.receiveTapMouseDragged(at: location) }
                if frameOrder != 2 {
                    reported.frame = observed
                    fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                }
                if frameOrder == 0 { fixture.handler.receiveTapMouseDragged(at: location) }

                fixture.handler.pressedMouseButtonsProvider = { 0 }
                fixture.handler.receiveTapMouseUp(at: location)
                if frameOrder == 2 {
                    reported.frame = observed
                    fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                }
                XCTAssertNil(
                    fixture.controller.layoutRefreshController.layoutState.pendingRefresh,
                    "\(layout), before annotation"
                )
                try fixture.annotatedDrag(windowId: token.windowId, at: location)

                XCTAssertEqual(
                    try fixture.frame(token).width,
                    observed.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), frameOrder=\(frameOrder)"
                )
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
            }
        }
    }

    func testUnclaimedLateAnnotationsCorrectTheDeferredCandidate() throws {
        var scenario = 0
        for layout in [LayoutType.niri, .dwindle] {
            for target in 0 ..< 3 {
                let fixture = try makeFixture(layout, pid: pid_t(835_081 + scenario))
                scenario += 1
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
                let (token, other) = (fixture.tokens[0], fixture.tokens[1])
                let start = try fixture.frame(token)
                let otherFrame = try fixture.frame(other)
                let reported = ReportedFrame(start)
                let location = nativeDragLocation(from: start)
                fixture.handler.nativeWindowFrameProvider = { ref in
                    ref.windowId == token.windowId ? reported.frame : otherFrame
                }
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                fixture.handler.receiveTapMouseDragged(at: location)
                reported.frame = grown(start, right: 140)
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                fixture.handler.pressedMouseButtonsProvider = { 0 }
                fixture.handler.receiveTapMouseUp(at: location)

                let windowId: Int? = target == 0 ? nil : target == 1 ? token.windowId + 10_000 : other.windowId
                try fixture.annotatedDrag(windowId: windowId, at: location)

                XCTAssertFalse(fixture.handler.state.awaitsNativeTitleBarDragTarget)
                XCTAssertNil(fixture.handler.state.nativeResizeStart)
                XCTAssertNotNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                XCTAssertEqual(
                    try fixture.frame(token).width,
                    start.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), target=\(target)"
                )
                XCTAssertEqual(
                    try fixture.frame(other).width,
                    otherFrame.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), target=\(target)"
                )
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: other))
            }
        }
    }

    func testRejectedReleasedAnnotationCorrectsALaterFrameDuringAnotherDisplayAnimation() async throws {
        var scenario = 0
        for layout in [LayoutType.niri, .dwindle] {
            for earlyFrame in [false, true] {
                let fixture = try makeFixture(layout, pid: pid_t(835_181 + scenario))
                scenario += 1
                let (animationWorkspace, animationMonitor) = try fixture.addUnrelatedAnimationWorkspace()
                fixture.wireFrameApplyCallbacks()
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
                let token = fixture.tokens[0]
                let start = try fixture.frame(token)
                let reported = ReportedFrame(start)
                let location = nativeDragLocation(from: start)
                fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                let windowInfo: @MainActor (UInt32) -> WindowServerInfo? = { windowId in
                    guard windowId == UInt32(token.windowId), let frame = reported.frame else { return nil }
                    return WindowServerInfo(
                        id: windowId,
                        pid: token.pid,
                        level: 0,
                        frame: ScreenCoordinateSpace.toWindowServer(rect: frame)
                    )
                }
                fixture.controller.axEventHandler.frameObservations.query = { windowInfo($0) }
                fixture.controller.axEventHandler.frameObservations.nativeDragQuery = windowInfo
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                fixture.handler.receiveTapMouseDragged(at: location)
                if earlyFrame {
                    reported.frame = grown(start, right: 80)
                    fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                }
                fixture.handler.pressedMouseButtonsProvider = { 0 }
                fixture.handler.receiveTapMouseUp(at: location)
                try fixture.annotatedDrag(windowId: nil, at: location)
                if fixture.controller.layoutRefreshController.layoutState.pendingRefresh != nil {
                    reported.frame = start
                    try fixture.confirmWrite(of: token)
                    fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
                }

                XCTAssertTrue(fixture.controller.niriLayoutHandler.registerScrollAnimation(
                    animationWorkspace,
                    on: animationMonitor.displayId
                ))
                XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.workspaceId))
                reported.frame = grown(start, right: 140)
                fixture.controller.axEventHandler.handleCGSEvent(.frameChanged(windowId: UInt32(token.windowId)))
                await fixture.controller.axEventHandler.frameObservations.byWindowId[UInt32(token.windowId)]?.task.value

                XCTAssertEqual(
                    fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
                    [fixture.workspaceId],
                    "\(layout), earlyFrame=\(earlyFrame)"
                )
                XCTAssertEqual(
                    fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
                    .interactiveGesture
                )
                XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            }
        }
    }

    func testOwnedClickRetiresReleasedAnnotatedCandidate() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(835_191 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let reported = ReportedFrame(start)
            let location = nativeDragLocation(from: start)
            fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
            fixture.handler.receiveTapMouseDragged(at: location)
            reported.frame = grown(start, right: 140)
            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
            fixture.handler.pressedMouseButtonsProvider = { 0 }
            fixture.handler.receiveTapMouseUp(at: location)
            XCTAssertTrue(fixture.handler.state.nativeTitleBarDragFallbackReleased)

            let ownedFrame = CGRect(x: -800, y: -800, width: 40, height: 40)
            let surfaceId = "released-native-resize-\(token.windowId)"
            fixture.controller.ownedWindowRegistry.registerWindowNumber(
                surfaceId: surfaceId,
                policy: SurfacePolicy(
                    kind: .utility,
                    hitTestPolicy: .interactive,
                    capturePolicy: .included,
                    suppressesManagedFocusRecovery: true
                ),
                windowNumber: token.windowId + 10_000,
                frameProvider: { ownedFrame },
                visibilityProvider: { true }
            )
            defer { fixture.controller.ownedWindowRegistry.unregister(surfaceId: surfaceId) }
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: ownedFrame.center, modifiers: []))
            XCTAssertFalse(fixture.handler.state.awaitsNativeTitleBarDragTarget)
            XCTAssertNil(fixture.handler.state.nativeResizeStart)
            XCTAssertNotNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)

            fixture.handler.receiveTapMouseDragged(at: location)
            try fixture.annotatedDrag(windowId: token.windowId, at: location)
            fixture.handler.pressedMouseButtonsProvider = { 0 }
            fixture.handler.receiveTapMouseUp(at: location)

            XCTAssertEqual(
                try fixture.frame(token).width,
                start.width,
                accuracy: FrameTolerance.frameWrite,
                "\(layout)"
            )
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        }
    }

    func testOverviewButtonOnlyPassesAMatchingRejectedTerminalDrag() throws {
        var scenario = 0
        for layout in [LayoutType.niri, .dwindle] {
            for rejected in [false, true] {
                for matching in [false, true] {
                    let fixture = try makeFixture(layout, pid: pid_t(835_201 + scenario))
                    scenario += 1
                    let blocker = blockRefreshes(fixture)
                    defer { unblockRefreshes(fixture, blocker: blocker) }
                    defer { fixture.controller.windowActionHandler.invalidateOverviewDeferredActionsForServiceStop() }
                    fixture.controller.isEnabled = true
                    try fixture.controller.settings.setOverviewMouseButton(2)
                    let token = fixture.tokens[0]
                    let start = try fixture.frame(token)
                    let reported = ReportedFrame(start)
                    fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                    if rejected {
                        fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(
                            kCFAllocatorDefault,
                            nil,
                            nil,
                            nil
                        ))
                        let location = nativeDragLocation(from: start)
                        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                        XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                        fixture.handler.receiveTapMouseDragged(at: location)
                        fixture.handler.pressedMouseButtonsProvider = { 0 }
                        fixture.handler.receiveTapMouseUp(at: location)
                        try fixture.annotatedDrag(windowId: nil, at: location)
                    } else {
                        try fixture.beginDrag(token)
                        fixture.handler.pressedMouseButtonsProvider = { 0 }
                        fixture.handler.receiveTapMouseUp(at: start.center)
                    }
                    XCTAssertEqual(fixture.phase, .awaitingFrameChange)
                    if !matching { reported.frame = grown(start, right: 140) }

                    let captures = fixture.handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2)
                    XCTAssertEqual(
                        captures,
                        rejected && matching,
                        "\(layout), rejected=\(rejected), matching=\(matching)"
                    )
                    XCTAssertEqual(fixture.controller.isOverviewOpen(), rejected && matching)
                    XCTAssertEqual(fixture.phase, .awaitingFrameChange)
                    if captures {
                        XCTAssertTrue(fixture.handler.receiveTapOtherMouseButton(type: .otherMouseUp, button: 2))
                        reported.frame = grown(start, right: 140)
                        XCTAssertTrue(try fixture.handler
                            .handleNativeTitleBarDragFrameChanged(for: fixture.entry(token)))
                        XCTAssertEqual(
                            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
                            [fixture.workspaceId]
                        )
                        XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
                    }
                }
            }
        }
    }

    func testOwnedClickPreservesRejectedDragCorrectionDuringAnotherDisplayAnimation() async throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(835_211 + index))
            let (animationWorkspace, animationMonitor) = try fixture.addUnrelatedAnimationWorkspace()
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let reported = ReportedFrame(start)
            fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
            let windowInfo: @MainActor (UInt32) -> WindowServerInfo? = { windowId in
                guard windowId == UInt32(token.windowId), let frame = reported.frame else { return nil }
                return WindowServerInfo(
                    id: windowId,
                    pid: token.pid,
                    level: 0,
                    frame: ScreenCoordinateSpace.toWindowServer(rect: frame)
                )
            }
            fixture.controller.axEventHandler.frameObservations.query = { windowInfo($0) }
            fixture.controller.axEventHandler.frameObservations.nativeDragQuery = windowInfo
            let location = nativeDragLocation(from: start)
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
            fixture.handler.receiveTapMouseDragged(at: location)
            fixture.handler.pressedMouseButtonsProvider = { 0 }
            fixture.handler.receiveTapMouseUp(at: location)
            try fixture.annotatedDrag(windowId: nil, at: location)
            XCTAssertEqual(fixture.phase, .awaitingFrameChange)
            let surfaceId = "rejected-native-resize-\(token.windowId)"
            let ownedFrame = start.offsetBy(dx: -fixture.monitor.frame.width, dy: -fixture.monitor.frame.height)
            fixture.controller.ownedWindowRegistry.registerWindowNumber(
                surfaceId: surfaceId,
                policy: SurfacePolicy(
                    kind: .utility,
                    hitTestPolicy: .interactive,
                    capturePolicy: .included,
                    suppressesManagedFocusRecovery: true
                ),
                windowNumber: try XCTUnwrap(fixture.tokens.map(\.windowId).max()) + 1,
                frameProvider: { ownedFrame },
                visibilityProvider: { true }
            )
            defer { fixture.controller.ownedWindowRegistry.unregister(surfaceId: surfaceId) }

            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: ownedFrame.center, modifiers: []))

            XCTAssertEqual(fixture.phase, .awaitingFrameChange, "\(layout)")
            XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.targetWasRejected, true)
            XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
            XCTAssertFalse(fixture.handler.state.awaitsNativeTitleBarDragTarget)
            XCTAssertNil(fixture.handler.state.nativeResizeStart)
            XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
            XCTAssertTrue(fixture.controller.niriLayoutHandler.registerScrollAnimation(
                animationWorkspace,
                on: animationMonitor.displayId
            ))
            XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.workspaceId))
            reported.frame = CGRect(
                origin: start.origin,
                size: CGSize(
                    width: (start.width + AXRecentFrameWriteFailure.maxAcceptedSizeSnap).nextUp,
                    height: start.height
                )
            )
            fixture.controller.axEventHandler.handleCGSEvent(.frameChanged(windowId: UInt32(token.windowId)))
            await fixture.controller.axEventHandler.frameObservations.byWindowId[UInt32(token.windowId)]?.task.value

            XCTAssertEqual(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
                [fixture.workspaceId],
                "\(layout)"
            )
            XCTAssertEqual(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.reason,
                .interactiveGesture,
                "\(layout)"
            )
            XCTAssertEqual(fixture.phase, .awaitingCorrection, "\(layout)")
            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            let correction = try fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                pid: token.pid,
                window: XCTUnwrap(fixture.entry(token).axRef),
                frame: start
            ))
            XCTAssertEqual(correction?.frame, start, "\(layout)")
        }
    }

    func testReleasedCandidatesStayCorrectableAfterTargetOrOwnedInputChanges() async throws {
        var scenario = 0
        for layout in [LayoutType.niri, .dwindle] {
            for acceptsOther in [false, true] {
                let fixture = try makeFixture(layout, pid: pid_t(835_221 + scenario))
                scenario += 1
                let (animationWorkspace, animationMonitor) = try fixture.addUnrelatedAnimationWorkspace()
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                fixture.wireFrameApplyCallbacks()
                fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
                let (token, other) = (fixture.tokens[0], fixture.tokens[1])
                let expectedActiveToken = acceptsOther ? other : token
                let start = try fixture.frame(token)
                let location = nativeDragLocation(from: start)
                let tokens = fixture.tokens
                let nativeFrames = fixture.nativeFrames
                let info: @MainActor (UInt32) -> WindowServerInfo? = { windowId in
                    guard let token = tokens.first(where: { $0.windowId == Int(windowId) }),
                          let frame = nativeFrames[Int(windowId)]?.frame else { return nil }
                    return WindowServerInfo(
                        id: windowId, pid: token.pid, level: 0,
                        frame: ScreenCoordinateSpace.toWindowServer(rect: frame)
                    )
                }
                fixture.controller.axEventHandler.frameObservations.query = { info($0) }
                fixture.controller.axEventHandler.frameObservations.nativeDragQuery = info
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                fixture.handler.receiveTapMouseDragged(at: location)
                fixture.handler.pressedMouseButtonsProvider = { 0 }
                fixture.handler.receiveTapMouseUp(at: location)
                try fixture.annotatedDrag(windowId: acceptsOther ? other.windowId : nil, at: location)
                if !acceptsOther {
                    let surfaceId = "retired-native-resize-\(token.windowId)"
                    let frame = CGRect(x: -800, y: -800, width: 40, height: 40)
                    fixture.controller.ownedWindowRegistry.registerWindowNumber(
                        surfaceId: surfaceId,
                        policy: SurfacePolicy(
                            kind: .utility, hitTestPolicy: .interactive, capturePolicy: .included,
                            suppressesManagedFocusRecovery: true
                        ),
                        windowNumber: token.windowId + 10_000,
                        frameProvider: { frame }, visibilityProvider: { true }
                    )
                    defer { fixture.controller.ownedWindowRegistry.unregister(surfaceId: surfaceId) }
                    XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: frame.center, modifiers: []))
                }
                XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, expectedActiveToken)
                XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                XCTAssertTrue(fixture.controller.niriLayoutHandler.registerScrollAnimation(
                    animationWorkspace, on: animationMonitor.displayId
                ))

                var displaced = start
                displaced.size.width = (start.width + max(FrameTolerance.frameWrite, FrameTolerance.screenMatch)).nextUp
                fixture.nativeFrames[token.windowId]?.frame = displaced
                fixture.controller.axEventHandler.handleCGSEvent(.frameChanged(windowId: UInt32(token.windowId)))
                await fixture.controller.axEventHandler.frameObservations.byWindowId[UInt32(token.windowId)]?.task.value

                let refresh = fixture.controller.layoutRefreshController.layoutState.pendingRefresh
                XCTAssertEqual(
                    refresh?.affectedWorkspaceIds,
                    [fixture.workspaceId],
                    "\(layout), acceptsOther=\(acceptsOther)"
                )
                XCTAssertEqual(refresh?.reason, .interactiveGesture)
                if refresh != nil { try fixture.confirmWrite(of: token) }
                XCTAssertEqual(fixture.nativeFrames[token.windowId]?.frame, start)
                XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
                XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, expectedActiveToken)
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                XCTAssertTrue(fixture.handler.tracksNativeTitleBarDrag(windowId: token.windowId))
                fixture.handler.discardNativeTitleBarDrag(for: WindowToken(
                    pid: token.pid + 10_000,
                    windowId: token.windowId
                ))
                XCTAssertTrue(fixture.handler.tracksNativeTitleBarDrag(windowId: token.windowId))
                XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, expectedActiveToken)
                fixture.handler.discardNativeTitleBarDrag(for: token)
                XCTAssertFalse(fixture.handler.tracksNativeTitleBarDrag(windowId: token.windowId))
                XCTAssertEqual(
                    fixture.handler.state.nativeTitleBarDrag?.token,
                    acceptsOther ? other : nil
                )
            }
        }
    }

    func testOverviewGateDoesNotReadAXWhenTheFastFrameIsUnavailable() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(835_231 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            defer { fixture.controller.windowActionHandler.invalidateOverviewDeferredActionsForServiceStop() }
            fixture.controller.isEnabled = true
            try fixture.controller.settings.setOverviewMouseButton(2)
            fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
            let start = try fixture.frame(fixture.tokens[0])
            let location = nativeDragLocation(from: start)
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
            fixture.handler.receiveTapMouseDragged(at: location)
            fixture.handler.pressedMouseButtonsProvider = { 0 }
            fixture.handler.receiveTapMouseUp(at: location)
            try fixture.annotatedDrag(windowId: nil, at: location)
            var fallbackReads = 0
            fixture.handler.nativeWindowFrameProvider = { _ in nil }
            fixture.handler.nativeWindowFrameFallbackProvider = { _ in
                fallbackReads += 1
                return start
            }

            XCTAssertFalse(fixture.handler.receiveTapOtherMouseButton(type: .otherMouseDown, button: 2))

            XCTAssertEqual(fallbackReads, 0)
            XCTAssertFalse(fixture.controller.isOverviewOpen())
        }
    }

    func testOrdinaryFrameChangesKeepTheirBusyRelayoutPolicy() async throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(835_241 + index))
            let (animationWorkspace, animationMonitor) = try fixture.addUnrelatedAnimationWorkspace()
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            fixture.controller.axEventHandler.frameObservations.query = { windowId in
                WindowServerInfo(id: windowId, pid: token.pid, level: 0, frame: start)
            }
            XCTAssertTrue(fixture.controller.niriLayoutHandler.registerScrollAnimation(
                animationWorkspace, on: animationMonitor.displayId
            ))
            var displaced = start
            displaced.size.width = (start.width + max(FrameTolerance.frameWrite, FrameTolerance.screenMatch)).nextUp
            fixture.nativeFrames[token.windowId]?.frame = displaced

            fixture.controller.axEventHandler.handleCGSEvent(.frameChanged(windowId: UInt32(token.windowId)))
            await fixture.controller.axEventHandler.frameObservations.byWindowId[UInt32(token.windowId)]?.task.value

            XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
            XCTAssertFalse(fixture.handler.tracksNativeTitleBarDrag(windowId: token.windowId))
        }
    }

    func testRetainedCorrectionWaitsForAFrameWriteAndRechecksItsCompletion() throws {
        var scenario = 0
        for layout in [LayoutType.niri, .dwindle] {
            for lateFrameSurvives in [false, true] {
                let fixture = try makeFixture(layout, pid: pid_t(835_251 + scenario))
                scenario += 1
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                fixture.wireFrameApplyCallbacks()
                fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
                let (token, other) = (fixture.tokens[0], fixture.tokens[1])
                let start = try fixture.frame(token)
                let location = nativeDragLocation(from: start)
                var intermediate = start
                intermediate.size.width = (start.width + max(FrameTolerance.frameWrite, FrameTolerance.screenMatch))
                    .nextUp
                var displaced = intermediate
                displaced.origin.x = (start.minX + FrameTolerance.frameWrite).nextUp
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                fixture.handler.receiveTapMouseDragged(at: location)
                fixture.handler.pressedMouseButtonsProvider = { 0 }
                fixture.handler.receiveTapMouseUp(at: location)
                try fixture.annotatedDrag(windowId: other.windowId, at: location)
                fixture.nativeFrames[token.windowId]?.frame = displaced
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                XCTAssertNotNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                let reference = try XCTUnwrap(fixture.entry(token).axRef)
                let request = try XCTUnwrap(fixture.controller.axManager.stageFrameWrite(
                    for: AXFrameApplicationTarget(pid: token.pid, window: reference, frame: start)
                ))
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil

                fixture.nativeFrames[token.windowId]?.frame = intermediate
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))

                XCTAssertNil(
                    fixture.controller.layoutRefreshController.layoutState.pendingRefresh,
                    "\(layout), intermediate frame, lateFrameSurvives=\(lateFrameSurvives)"
                )
                XCTAssertEqual(fixture.controller.axManager.pendingFrameWrite(for: token.windowId), start)
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
                if !lateFrameSurvives { fixture.nativeFrames[token.windowId]?.frame = start }
                fixture.controller.axManager.handleFrameApplyResults([
                    WindowAdmissionTestSupport.successfulFrameResult(request: request)
                ])

                XCTAssertNil(fixture.controller.axManager.pendingFrameWrite(for: token.windowId))
                XCTAssertEqual(fixture.controller.axManager.lastAppliedFrame(for: token.windowId), start)
                XCTAssertEqual(
                    fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
                    lateFrameSurvives ? [fixture.workspaceId] : nil,
                    "\(layout), completion, lateFrameSurvives=\(lateFrameSurvives)"
                )
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
                var lateFrame = start
                lateFrame.size.width = (start.width + FrameTolerance.frameWrite).nextUp
                fixture.nativeFrames[token.windowId]?.frame = lateFrame
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                XCTAssertEqual(
                    fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
                    [fixture.workspaceId]
                )
                XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
            }
        }
    }

    func testRetainedCorrectionRecoversOnceAfterTerminalFailure() throws {
        var scenario = 0
        for layout in [LayoutType.niri, .dwindle] {
            for receivedFrame in [false, true] {
                for observedOnFailure in [false, true] {
                    let fixture = try makeFixture(layout, pid: pid_t(835_271 + scenario))
                    scenario += 1
                    let blocker = blockRefreshes(fixture)
                    defer { unblockRefreshes(fixture, blocker: blocker) }
                    fixture.controller.axManager
                        .onFrameApplyTerminated = { [weak controller = fixture.controller] result in
                            controller?.mouseEventHandler.handleNativeTitleBarDragFrameApplyTerminated(result)
                        }
                    let token = fixture.tokens[0]
                    let start = try fixture.frame(token)
                    var displaced = start
                    displaced.size.width = (start.width + FrameTolerance.frameWrite).nextUp
                    let reference = try XCTUnwrap(fixture.entry(token).axRef)
                    fixture.handler.retainNativeResizeCorrection(for: token)
                    fixture.nativeFrames[token.windowId]?.frame = observedOnFailure ? displaced : nil
                    fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                    XCTAssertNotNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                    fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
                    for attempt in 0 ..< 2 {
                        fixture.controller.axManager.forceApplyNextFrame(for: token.windowId)
                        let request = try XCTUnwrap(fixture.controller.axManager.stageFrameWrite(
                            for: AXFrameApplicationTarget(pid: token.pid, window: reference, frame: start)
                        ))
                        if receivedFrame {
                            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                            XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                        }
                        fixture.controller.axManager.handleFrameApplyResults([
                            WindowAdmissionTestSupport.verificationMismatchFrameResult(
                                request: request,
                                observed: displaced
                            )
                        ])
                        _ = fixture.controller.axManager.cancelPendingFrameRetry(for: token.windowId)
                        let retry = try XCTUnwrap(WindowAdmissionTestSupport.frameRequest(
                            fixture.controller.axManager.frameLedger,
                            pid: token.pid, window: reference, frame: start, isRetry: true
                        ))
                        let failure = AXFrameApplyResult(
                            requestId: retry.requestId, pid: retry.pid, windowId: retry.windowId,
                            expectedWindow: retry.expectedWindow, targetFrame: retry.frame,
                            currentFrameHint: retry.currentFrameHint,
                            writeResult: AXFrameWriteResult(
                                observedFrame: observedOnFailure ? displaced : nil, writeOrder: .sizeThenPosition,
                                sizeError: .cannotComplete, positionError: .success, failureReason: .contextUnavailable
                            )
                        )

                        fixture.controller.axManager.handleFrameApplyResults([failure])

                        XCTAssertNil(fixture.controller.axManager.pendingFrameWrite(for: token.windowId))
                        XCTAssertEqual(
                            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
                            attempt == 0 ? [fixture.workspaceId] : nil,
                            "\(layout), receivedFrame=\(receivedFrame), observedOnFailure=\(observedOnFailure), attempt=\(attempt)"
                        )
                        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
                        fixture.handler.handleNativeTitleBarDragFrameApplyTerminated(failure)
                        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                    }
                    fixture.nativeFrames[token.windowId]?.frame = displaced
                    fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                    XCTAssertNotNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                    XCTAssertEqual(try fixture.frame(token), start)
                }
            }
        }
    }

    func testRetainedCorrectionResumesWhenAHeldFallbackChangesTarget() throws {
        var scenario = 0
        for layout in [LayoutType.niri, .dwindle] {
            for rejectsTarget in [false, true] {
                let fixture = try makeFixture(layout, pid: pid_t(835_291 + scenario))
                scenario += 1
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                fixture.wireFrameApplyCallbacks()
                fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
                let (token, other) = (fixture.tokens[0], fixture.tokens[1])
                let start = try fixture.frame(token)
                let unknownWindowId = try XCTUnwrap(fixture.tokens.map(\.windowId).max()) + 1
                XCTAssertNil(fixture.manager.entry(forWindowId: unknownWindowId))
                let reference = try XCTUnwrap(fixture.entry(token).axRef)
                fixture.handler.retainNativeResizeCorrection(for: token)
                fixture.controller.axManager.forceApplyNextFrame(for: token.windowId)
                let request = try XCTUnwrap(fixture.controller.axManager.stageFrameWrite(
                    for: AXFrameApplicationTarget(pid: token.pid, window: reference, frame: start)
                ))
                var displaced = start
                displaced.size.width = (start.width + FrameTolerance.frameWrite).nextUp
                fixture.nativeFrames[token.windowId]?.frame = displaced
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                fixture.handler.receiveTapMouseDragged(at: nativeDragLocation(from: start))
                XCTAssertEqual(fixture.handler.state.nativeTitleBarDragFallbackToken, token)
                XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)

                fixture.controller.axManager.handleFrameApplyResults([
                    WindowAdmissionTestSupport.successfulFrameResult(request: request)
                ])

                XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                try fixture.annotatedDrag(
                    windowId: rejectsTarget ? unknownWindowId : other.windowId, at: nativeDragLocation(from: start)
                )

                XCTAssertEqual(
                    fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds,
                    [fixture.workspaceId], "\(layout), rejectsTarget=\(rejectsTarget)"
                )
                XCTAssertNil(fixture.handler.state.nativeTitleBarDragFallbackToken)
                XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, rejectsTarget ? nil : other)
                XCTAssertEqual(try fixture.frame(token), start)
            }
        }
    }

    func testReleasedAnnotatedCandidateIsRetiredAtTheNextInputBoundary() throws {
        var scenario = 0
        for layout in [LayoutType.niri, .dwindle] {
            for suppression in [false, true] {
                let fixture = try makeFixture(layout, pid: pid_t(835_121 + scenario))
                scenario += 1
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
                let (token, other) = (fixture.tokens[0], fixture.tokens[1])
                let start = try fixture.frame(token)
                let otherFrame = try fixture.frame(other)
                let reported = ReportedFrame(start)
                let location = nativeDragLocation(from: start)
                fixture.handler.nativeWindowFrameProvider = { ref in
                    ref.windowId == token.windowId ? reported.frame : otherFrame
                }
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                fixture.handler.receiveTapMouseDragged(at: location)
                reported.frame = grown(start, right: 140)
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                fixture.handler.pressedMouseButtonsProvider = { 0 }
                fixture.handler.receiveTapMouseUp(at: location)

                if suppression {
                    fixture.handler.handleInputSuppressionBegan()
                } else {
                    XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: otherFrame.center, modifiers: []))
                }

                XCTAssertNotEqual(fixture.handler.state.nativeResizeStart?.token, token)
                XCTAssertNotNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            }
        }
    }

    func testAnnotatedMoveCallbackIgnoresTargetsAfterConfirmation() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(835_061 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            fixture.controller.settings.gestures.adoptNativeMoveAcrossDisplays = true
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let location = nativeDragLocation(from: start)
            fixture.handler.nativeWindowFrameProvider = { _ in start }
            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
            try fixture.annotatedDrag(windowId: token.windowId, at: location)
            XCTAssertFalse(fixture.handler.state.awaitsNativeTitleBarDragTarget)
            XCTAssertEqual(fixture.handler.state.nativeCrossDisplayMove?.token, token)

            try fixture.annotatedDrag(windowId: token.windowId + 10_000, at: location)

            XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, token)
            XCTAssertEqual(fixture.handler.state.nativeCrossDisplayMove?.token, token)
            fixture.handler.receiveTapMouseUp(at: location)
        }
    }

    func testAnnotatedMoveCallbackDoesNotClaimTargetsOffMainThread() async throws {
        let fixture = try makeFixture(.dwindle, pid: 835_071)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        let point = ScreenCoordinateSpace.toWindowServer(point: start.center)
        fixture.handler.nativeWindowFrameProvider = { _ in start }
        MouseEventHandler._instance = fixture.handler
        XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
        let callback = MouseEventHandler.annotatedMoveTapCallback

        let callbackRan: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard !Thread.isMainThread, let event = CGEvent(
                    mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left
                ) else {
                    continuation.resume(returning: false)
                    return
                }
                event.setIntegerValueField(
                    .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                    value: Int64(token.windowId)
                )
                _ = callback(OpaquePointer(bitPattern: 1)!, .leftMouseDragged, event, nil)
                continuation.resume(returning: true)
            }
        }

        XCTAssertTrue(callbackRan)
        XCTAssertTrue(fixture.handler.state.awaitsNativeTitleBarDragTarget)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        fixture.handler.receiveTapMouseUp(at: start.center)
    }

    func testInstalledMoveTapDefersFramesUntilTheAnnotatedDrag() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            for queuedDragOrder in 0 ..< 3 {
                let fixture = try makeFixture(layout, pid: pid_t(834_251 + index * 3 + queuedDragOrder))
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
                let token = fixture.tokens[0]
                let start = try fixture.frame(token)
                let observed = grown(start, right: 140)
                let reported = ReportedFrame(start)
                fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                if queuedDragOrder == 1 {
                    fixture.handler.dispatchQueuedMouseDragged(
                        at: nativeDragLocation(from: start),
                        button: .left
                    )
                }

                reported.frame = observed
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))

                XCTAssertEqual(fixture.controller.axManager.lastAppliedFrame(for: token.windowId), start)
                XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                XCTAssertEqual(
                    try fixture.frame(token).width,
                    start.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), before annotation"
                )
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                if queuedDragOrder == 2 {
                    fixture.handler.dispatchQueuedMouseDragged(
                        at: nativeDragLocation(from: start),
                        button: .left
                    )
                }
                try fixture.annotatedDrag(windowId: token.windowId, at: nativeDragLocation(from: start))

                XCTAssertEqual(fixture.phase, .dragging)
                XCTAssertEqual(
                    try fixture.frame(token).width,
                    layout == .dwindle ? observed.width : start.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), queuedDragOrder=\(queuedDragOrder), confirmed drag"
                )
                fixture.handler.receiveTapMouseUp(at: observed.center)

                XCTAssertEqual(
                    try fixture.frame(token).width,
                    observed.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), queuedDragOrder=\(queuedDragOrder)"
                )
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
            }
        }
    }

    func testDeferredAnnotatedFramesAreCorrectedWhenTheTargetIsNotClaimed() throws {
        enum Boundary: CaseIterable {
            case mouseUp, nextMouseDown, suppression, unmanagedTarget, otherTiledTarget
        }
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            for (boundaryIndex, boundary) in Boundary.allCases.enumerated() {
                let fixture = try makeFixture(layout, pid: pid_t(834_271 + index * 5 + boundaryIndex))
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                fixture.handler.state.moveTap = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil))
                let (token, other) = (fixture.tokens[0], fixture.tokens[1])
                let start = try fixture.frame(token)
                let otherFrame = try fixture.frame(other)
                let observed = grown(start, right: 140)
                let reported = ReportedFrame(start)
                fixture.handler.nativeWindowFrameProvider = { ref in
                    ref.windowId == token.windowId ? reported.frame : otherFrame
                }
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                reported.frame = observed
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)

                switch boundary {
                case .mouseUp:
                    fixture.handler.pressedMouseButtonsProvider = { 0 }
                    fixture.handler.receiveTapMouseUp(at: observed.center)
                case .nextMouseDown:
                    XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: otherFrame.center, modifiers: []))
                case .suppression:
                    fixture.handler.handleInputSuppressionBegan()
                case .unmanagedTarget:
                    fixture.handler.receiveAnnotatedNativeMouseDragged(
                        at: nativeDragLocation(from: start),
                        windowIdUnderPointer: token.windowId + 10_000
                    )
                case .otherTiledTarget:
                    fixture.handler.receiveAnnotatedNativeMouseDragged(
                        at: nativeDragLocation(from: start),
                        windowIdUnderPointer: other.windowId
                    )
                    XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, other)
                    XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
                }

                let correction = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                XCTAssertEqual(correction.reason, .interactiveGesture, "\(layout), \(boundary)")
                XCTAssertTrue(correction.affectedWorkspaceIds.contains(fixture.workspaceId))
                XCTAssertNotEqual(fixture.handler.state.nativeResizeStart?.token, token)
                XCTAssertEqual(
                    try fixture.frame(token).width,
                    start.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), \(boundary)"
                )
                XCTAssertEqual(
                    try fixture.frame(other).width,
                    otherFrame.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), \(boundary)"
                )
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
                XCTAssertNotNil(try fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                    pid: token.pid, window: XCTUnwrap(fixture.entry(token).axRef), frame: start
                )))
                fixture.handler.receiveTapMouseUp(at: otherFrame.center)
            }
        }
    }

    func testAnnotatedDragAdoptsAfterCancellingPositionOnlyFrameJobs() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            for retry in [false, true] {
                let fixture = try makeFixture(layout, pid: pid_t(834_221 + index * 2 + (retry ? 1 : 0)))
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                let token = fixture.tokens[0]
                let start = try fixture.frame(token)
                let target = start.offsetBy(dx: 0, dy: -20)
                if retry {
                    fixture.controller.axManager.scheduleFrameRetry(AXFrameRetryRequest(
                        requestId: 1, pid: token.pid, windowId: token.windowId,
                        expectedWindow: try XCTUnwrap(fixture.entry(token).axRef),
                        frame: target, currentFrameHint: start
                    ))
                } else {
                    XCTAssertNotNil(try fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                        pid: token.pid, window: XCTUnwrap(fixture.entry(token).axRef), frame: target
                    )))
                }
                let reported = ReportedFrame(start)
                fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))

                fixture.handler.receiveAnnotatedNativeMouseDragged(
                    at: nativeDragLocation(from: start),
                    windowIdUnderPointer: token.windowId
                )

                XCTAssertFalse(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
                XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame, start)
                let observed = grown(start, right: 160)
                reported.frame = observed
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                fixture.handler.receiveTapMouseUp(at: observed.center)

                XCTAssertEqual(
                    try fixture.frame(token).width,
                    observed.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), retry=\(retry)"
                )
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            }
        }
    }

    func testReleasedFallbackClickDoesNotAdoptALaterProgrammaticResize() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_171 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let observed = grown(start, right: 140)
            fixture.handler.nativeWindowFrameProvider = { _ in start }
            fixture.handler.pressedMouseButtonsProvider = { 0 }
            XCTAssertFalse(fixture.handler.dispatchMouseDown(at: start.center, modifiers: []))
            fixture.handler.dispatchMouseUp(at: start.center)

            fixture.handler.nativeWindowFrameProvider = { _ in observed }
            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))

            XCTAssertEqual(
                try fixture.frame(token).width,
                start.width,
                accuracy: FrameTolerance.frameWrite,
                "\(layout)"
            )
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
        }
    }

    func testPendingFrameJobsAllowNativeResizeWhenTheConfirmedFrameIsStillVisible() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            for retry in [false, true] {
                let fixture = try makeFixture(layout, pid: pid_t(834_121 + index * 2 + (retry ? 1 : 0)))
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                let token = fixture.tokens[0]
                let start = try fixture.frame(token)
                let target = start.offsetBy(dx: 0, dy: -20)
                if retry {
                    fixture.controller.axManager.scheduleFrameRetry(AXFrameRetryRequest(
                        requestId: 1,
                        pid: token.pid,
                        windowId: token.windowId,
                        expectedWindow: try XCTUnwrap(fixture.entry(token).axRef),
                        frame: target,
                        currentFrameHint: start
                    ))
                } else {
                    XCTAssertNotNil(try fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                        pid: token.pid, window: XCTUnwrap(fixture.entry(token).axRef), frame: target
                    )))
                }
                XCTAssertTrue(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
                let reported = ReportedFrame(start)
                fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }

                try fixture.beginDrag(token)

                XCTAssertFalse(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
                XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame, start)
                let observed = grown(start, right: 160)
                reported.frame = observed
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                fixture.handler.dispatchMouseUp(at: observed.center)

                XCTAssertEqual(
                    try fixture.frame(token).width,
                    observed.width,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout), retry=\(retry)"
                )
            }
        }
    }

    func testFrameFallbackKeepsTheBaselineBeforeCancellingPendingFrameJobs() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            for released in [false, true] {
                for retry in [false, true] {
                    let pid = pid_t(834_161 + index * 4 + (released ? 2 : 0) + (retry ? 1 : 0))
                    let fixture = try makeFixture(layout, pid: pid)
                    let blocker = blockRefreshes(fixture)
                    defer { unblockRefreshes(fixture, blocker: blocker) }
                    let token = fixture.tokens[0]
                    let start = try fixture.frame(token)
                    let target = start.offsetBy(dx: 0, dy: -20)
                    if retry {
                        fixture.controller.axManager.scheduleFrameRetry(AXFrameRetryRequest(
                            requestId: 1, pid: token.pid, windowId: token.windowId,
                            expectedWindow: try XCTUnwrap(fixture.entry(token).axRef),
                            frame: target, currentFrameHint: start
                        ))
                    } else {
                        XCTAssertNotNil(try fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                            pid: token.pid, window: XCTUnwrap(fixture.entry(token).axRef), frame: target
                        )))
                    }
                    let reported = ReportedFrame(start)
                    fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                    fixture.handler
                        .pressedMouseButtonsProvider = { released ? 0 : MouseEventHandler.MouseButton.left.pressedMask }
                    XCTAssertFalse(fixture.handler.dispatchMouseDown(at: start.center, modifiers: []))
                    fixture.handler.dispatchMouseDragged(at: nativeDragLocation(from: start))
                    if released {
                        fixture.handler.dispatchMouseUp(at: start.center)
                    }

                    let observed = grown(start, right: 160)
                    reported.frame = observed
                    fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                    if !released { fixture.handler.dispatchMouseUp(at: observed.center) }

                    XCTAssertEqual(
                        try fixture.frame(token).width, observed.width, accuracy: FrameTolerance.frameWrite,
                        "\(layout), released=\(released), retry=\(retry)"
                    )
                    XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                }
            }
        }
    }

    func testAnInFlightWriteCannotBecomeANativeResizeAfterCancellation() async throws {
        let fixture = try makeFixture(.dwindle, pid: 834_151)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        let target = grown(start, right: 180)
        let createdContext = try await AppAXContextRegistry.getOrCreate(.current, pid: token.pid)
        let context = try XCTUnwrap(createdContext)
        defer { context.destroy() }
        let request = try XCTUnwrap(fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
            pid: token.pid, window: XCTUnwrap(fixture.entry(token).axRef), frame: target
        )))
        let drain = try XCTUnwrap(context.frameDelivery.enqueueFrames(
            [request], callbackGeneration: context.callbackGeneration, completion: { _ in }
        ).drain)
        defer {
            let outcome = context.frameDelivery.finishFrames(
                batchId: UUID(), drainId: drain.id,
                results: [WindowAdmissionTestSupport.successfulFrameResult(request: request)]
            )
            for delivery in outcome.deliveries { delivery.deliver() }
        }
        XCTAssertEqual(context.frameDelivery.runtimeMailboxDepths.ordinaryInFlight, 1)
        let reported = ReportedFrame(start)
        fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }

        try fixture.beginDrag(token)

        XCTAssertFalse(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
        XCTAssertEqual(context.frameDelivery.runtimeMailboxDepths.ordinaryInFlight, 1)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
        reported.frame = target
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
        fixture.handler.dispatchMouseUp(at: target.center)

        XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
    }

    func testAnAlreadyAppliedPendingSizeDoesNotBecomeANativeResize() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_131 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let target = grown(start, right: 180)
            XCTAssertNotNil(try fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                pid: token.pid, window: XCTUnwrap(fixture.entry(token).axRef), frame: target
            )))
            fixture.handler.nativeWindowFrameProvider = { _ in target }

            try fixture.beginDrag(token)

            XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
            fixture.handler.dispatchMouseUp(at: target.center)
            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
        }
    }

    func testChangingTheConfirmedFrameDuringADragStillDisablesAdoption() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_141 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            fixture.handler.nativeWindowFrameProvider = { _ in start }
            try fixture.beginDrag(token)
            fixture.controller.axManager.confirmFrameWrite(for: token.windowId, frame: start.offsetBy(dx: 20, dy: 0))

            let observed = grown(start, right: 200)
            fixture.handler.nativeWindowFrameProvider = { _ in observed }
            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
            fixture.handler.dispatchMouseUp(at: observed.center)

            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
        }
    }

    func testVerifiedAdoptedWritesLearnNothingWhileRefusedWritesStillLearn() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_051 + index))
            fixture.wireFrameApplyCallbacks()
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let (resized, neighbor) = (fixture.tokens[0], fixture.tokens[1])
            let start = try fixture.frame(resized)

            try fixture.release(resized, at: grown(start, right: 200))
            XCTAssertEqual(
                try fixture.frame(resized).width,
                start.width + 200,
                accuracy: FrameTolerance.frameWrite,
                "\(layout)"
            )
            try fixture.confirmWrite(of: resized)
            XCTAssertEqual(fixture.phase, .awaitingFrameChange, "\(layout)")
            fixture.controller.layoutRefreshController.stopScrollAnimation(for: fixture.monitor.displayId)

            let widened = try fixture.frame(resized)
            try fixture.release(resized, at: grown(widened, right: -300))
            XCTAssertEqual(
                try fixture.frame(resized).width,
                widened.width - 300,
                accuracy: FrameTolerance.frameWrite,
                "\(layout)"
            )
            try fixture.confirmWrite(of: resized)
            XCTAssertNil(fixture.manager.observedSizeEvidence(for: resized), "\(layout)")
            XCTAssertNil(fixture.manager.cachedConstraints(for: resized, maxAge: .greatestFiniteMagnitude), "\(layout)")

            let neighborTarget = try fixture.frame(neighbor)
            let refusedWidth = (neighborTarget.width + AXRecentFrameWriteFailure.maxAcceptedSizeSnap).nextUp
            try fixture.refuseWrite(of: neighbor, growingWidthBy: refusedWidth - neighborTarget.width)
            let neighborEvidence = try XCTUnwrap(fixture.manager.observedSizeEvidence(for: neighbor), "\(layout)")
            XCTAssertEqual(
                neighborEvidence.minSize.width,
                refusedWidth,
                accuracy: FrameTolerance.frameWrite,
                "\(layout)"
            )
            XCTAssertGreaterThan(neighborEvidence.minSize.width, ObservedSizeEvidence().minSize.width, "\(layout)")
            XCTAssertNil(fixture.manager.observedSizeEvidence(for: resized), "\(layout)")

            let resizedTarget = try fixture.frame(resized)
            let hintedWidth = resizedTarget.width + AXRecentFrameWriteFailure.maxAcceptedSizeSnap
            try fixture.refuseWrite(of: resized, growingWidthBy: hintedWidth - resizedTarget.width)
            let hinted = try XCTUnwrap(fixture.manager.observedSizeEvidence(for: resized), "\(layout)")
            XCTAssertEqual(hinted.minSize.width, ObservedSizeEvidence().minSize.width, "\(layout)")
            XCTAssertEqual(hinted.hints.width, ObservedAxisHint(requested: resizedTarget.width, observed: hintedWidth))
            XCTAssertFalse(hinted.hints.isEmpty, "\(layout)")
        }
    }

    func testSecondaryEdgesAdoptWhereverTheyRender() throws {
        let columns = try makeFixture(.niri, pid: 834_061)
        let columnsBlocker = blockRefreshes(columns)
        defer { unblockRefreshes(columns, blocker: columnsBlocker) }
        let columnStart = try columns.frame(columns.tokens[0])
        try columns.release(columns.tokens[0], at: grown(columnStart, bottom: -120))
        XCTAssertEqual(
            try columns.frame(columns.tokens[0]).height,
            columnStart.height - 120,
            accuracy: FrameTolerance.frameWrite
        )

        let portrait = try makeFixture(.niri, portrait: true, windowCount: 1, pid: 834_062)
        let portraitBlocker = blockRefreshes(portrait)
        defer { unblockRefreshes(portrait, blocker: portraitBlocker) }
        let portraitStart = try portrait.frame(portrait.tokens[0])
        try portrait.release(portrait.tokens[0], at: grown(portraitStart, right: -150))
        XCTAssertEqual(
            try portrait.frame(portrait.tokens[0]).width,
            portraitStart.width - 150,
            accuracy: FrameTolerance.frameWrite
        )

        let single = try makeFixture(.niri, windowCount: 1, pid: 834_063)
        let singleBlocker = blockRefreshes(single)
        defer { unblockRefreshes(single, blocker: singleBlocker) }
        let singleBefore = try single.frames()
        try single.release(single.tokens[0], at: grown(try single.frame(single.tokens[0]), bottom: -120))
        XCTAssertEqual(single.phase, .awaitingCorrection)
        XCTAssertEqual(try single.frames(), singleBefore)
    }

    func testAdoptedFrameIsTheFirstWriteForTheResizedWindow() async throws {
        let cases: [(LayoutType, Int, (CGRect) -> CGRect)] = [
            (.niri, 0, { self.grown($0, right: 200) }),
            (.niri, 1, { self.grown($0, left: 150) }),
            (.dwindle, 0, { self.grown($0, right: 150) })
        ]
        for (index, (layout, tokenIndex, change)) in cases.enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_071 + index))
            let token = fixture.tokens[tokenIndex]
            let observed = change(try fixture.frame(token))
            FrameApplyTrace.shared.beginCapture()
            defer { FrameApplyTrace.shared.endCapture() }

            try fixture.release(token, at: observed)
            fixture.controller.niriLayoutHandler.tickScrollAnimation(
                targetTime: fixture.controller.animationClock.now(),
                displayId: fixture.monitor.displayId
            )
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

            let target = try XCTUnwrap(firstWriteTarget(for: token), "\(layout) \(tokenIndex)")
            XCTAssertEqual(target.width, observed.width, accuracy: FrameTolerance.frameWrite, "\(layout) \(tokenIndex)")
            if tokenIndex == 1 {
                XCTAssertEqual(
                    target.maxX,
                    observed.maxX,
                    accuracy: FrameTolerance.frameWrite,
                    "\(layout) \(tokenIndex)"
                )
            }
        }
    }

    private func frameDecisions(for token: WindowToken) -> [Substring] {
        FrameApplyTrace.shared.dump().split(separator: "\n").filter {
            $0.contains(" win=\(token.windowId) ") && $0.contains(" event=ledger-")
        }
    }

    private func firstWriteTarget(for token: WindowToken) -> CGRect? {
        let line = FrameApplyTrace.shared.dump().split(separator: "\n").first { line in
            line.contains(" win=\(token.windowId) ") && !line.contains("cancelled") && line.contains(" target=(")
        }
        guard let line,
              let range = line.range(of: " target=(")
        else { return nil }
        let rest = line[range.upperBound...]
        guard let close = rest.firstIndex(of: ")") else { return nil }
        let numbers = rest[..<close]
            .replacingOccurrences(of: "x", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private func grown(
        _ frame: CGRect,
        left: CGFloat = 0,
        right: CGFloat = 0,
        bottom: CGFloat = 0,
        top: CGFloat = 0
    ) -> CGRect {
        CGRect(
            x: frame.minX - left,
            y: frame.minY - bottom,
            width: frame.width + left + right,
            height: frame.height + bottom + top
        )
    }

    private func stackedTopAndBottom(_ fixture: Fixture) throws -> (WindowToken, WindowToken) {
        let (first, second) = (fixture.tokens[0], fixture.tokens[1])
        return try fixture.frame(first).midY > fixture.frame(second).midY ? (first, second) : (second, first)
    }

    private func stackedLeftAndRight(_ fixture: Fixture) throws -> (WindowToken, WindowToken) {
        let (first, second) = (fixture.tokens[0], fixture.tokens[1])
        return try fixture.frame(first).midX < fixture.frame(second).midX ? (first, second) : (second, first)
    }

    private func succeeded(
        _ fixture: Fixture,
        token: WindowToken,
        frame: CGRect,
        requestId: AXFrameRequestId
    ) throws -> AXFrameApplyResult {
        let reference = try XCTUnwrap(fixture.entry(token).axRef)
        return AXFrameApplyResult(
            requestId: requestId,
            pid: token.pid,
            windowId: token.windowId,
            expectedWindow: reference,
            targetFrame: frame,
            currentFrameHint: nil,
            writeResult: AXFrameWriteResult(
                observedFrame: frame,
                writeOrder: .sizeThenPosition,
                sizeError: .success,
                positionError: .success,
                failureReason: nil
            )
        )
    }

    private struct RefreshBlocker {
        let task: Task<Void, Never>
        let completion: AsyncStream<Void>.Continuation
    }

    private func blockRefreshes(_ fixture: Fixture) -> RefreshBlocker {
        let (events, completion) = AsyncStream<Void>.makeStream()
        let blocker = Task { @MainActor in
            var iterator = events.makeAsyncIterator()
            _ = await iterator.next()
        }
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [fixture.workspaceId]
        )
        return RefreshBlocker(task: blocker, completion: completion)
    }

    private func unblockRefreshes(_ fixture: Fixture, blocker: RefreshBlocker) {
        blocker.completion.finish()
        blocker.task.cancel()
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = nil
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = nil
        fixture.controller.layoutRefreshController.layoutState.pendingRefresh = nil
    }

    private func makeFixture(
        _ layout: LayoutType,
        stacked: Bool = false,
        portrait: Bool = false,
        windowCount: Int = 2,
        pid: pid_t
    ) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "NativeResizeAdoptionTests")
        addTeardownBlock { @MainActor [controller] in
            controller.hasStartedServices = false
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
        }
        let frame = portrait ? CGRect(x: 0, y: 0, width: 900, height: 1600) : workingFrame
        let monitor = Monitor(
            id: .init(displayId: 83_401),
            displayId: 83_401,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Native Resize Adoption"
        )
        controller.settings.gestures.adoptNativeResize = true
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: layout
            )
        ]
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let tokens = (0 ..< windowCount).map { WindowToken(pid: pid, windowId: Int(pid) + 100 + $0) }
        for token in tokens {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        if layout == .niri {
            controller.enableNiriLayout()
            let engine = try XCTUnwrap(controller.niriEngine)
            let first = engine.addWindow(token: tokens[0], to: workspaceId, afterSelection: nil)
            if stacked, tokens.count > 1 {
                controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                    engine.attachTransferredWindow(
                        NiriWindow(token: tokens[1]),
                        stackedWith: first,
                        after: true,
                        in: workspaceId,
                        state: &state
                    )
                }
            } else if tokens.count > 1 {
                _ = engine.addWindow(token: tokens[1], to: workspaceId, afterSelection: first.id)
            }
        } else {
            controller.enableDwindleLayout()
            let engine = try XCTUnwrap(controller.dwindleEngine)
            controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
                for (index, token) in tokens.enumerated() {
                    if stacked, index == 2 {
                        engine.setSelectedNode(engine.findNode(for: tokens[0], in: workspaceId), in: workspaceId)
                        _ = engine.setPreselection(.up, in: workspaceId)
                    } else {
                        _ = engine.setPreselection(.right, in: workspaceId)
                    }
                    _ = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
                }
            }
        }
        let nativeFrames = Dictionary(uniqueKeysWithValues: tokens.map { ($0.windowId, ReportedFrame(nil)) })
        let fixture = Fixture(
            controller: controller,
            workspaceId: workspaceId,
            monitor: monitor,
            tokens: tokens,
            nativeFrames: nativeFrames
        )
        if layout == .dwindle {
            controller.dwindleEngine?.cancelAnimations(in: workspaceId)
        }
        let frames = try fixture.frames()
        try fixture.confirmLayout()
        controller.mouseEventHandler.nativeWindowFrameProvider = { nativeFrames[$0.windowId]?.frame }
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard let token = tokens.first(where: { $0.windowId == Int(windowId) }) else { return nil }
            return WindowServerInfo(id: windowId, pid: token.pid, level: 0, frame: frames[token] ?? .zero)
        }
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        controller.hasStartedServices = true
        return fixture
    }
}
