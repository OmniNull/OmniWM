// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
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

        func column(_ token: WindowToken) throws -> NiriContainer {
            try XCTUnwrap(controller.niriEngine?.findColumn(containing: niriNode(token), in: workspaceId))
        }

        func target(_ token: WindowToken) throws -> NiriLayoutHandler.WindowTarget {
            try .window(XCTUnwrap(manager.handle(for: token)))
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

        func beginDrag(_ token: WindowToken, at press: CGPoint? = nil, draggedTo: CGPoint? = nil) throws {
            handler.retireNativeTitleBarDragAtInputBoundary()
            handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            let start = try frame(token)
            XCTAssertFalse(handler.dispatchMouseDown(
                at: press ?? start.center,
                modifiers: [],
                windowIdUnderPointer: token.windowId
            ))
            handler.dispatchMouseDragged(at: draggedTo ?? nativeDragLocation(from: start))
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

        func release(_ token: WindowToken, at observed: CGRect, press: CGPoint? = nil) throws {
            let reported = ReportedFrame(controller.axManager.lastAppliedFrame(for: token.windowId))
            handler.nativeWindowFrameProvider = { _ in reported.frame }
            try beginDrag(token, at: press)
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

    func testDwindleNativeResizeSchedulesCorrectionAfterAdoptingTheSplit() throws {
        let fixture = try makeFixture(.dwindle, pid: 834_002)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let before = try fixture.frames()
        let worldSeq = fixture.manager.worldSeq
        let start = try fixture.frame(fixture.tokens[0])
        let growth = start.width / 4

        try fixture.release(
            fixture.tokens[0], at: grown(start, right: growth),
            press: CGPoint(x: start.maxX - FrameTolerance.frameWrite, y: start.midY)
        )

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertEqual(fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.affectedWorkspaceIds, [])
        var expected = before
        expected[fixture.tokens[0]]?.size.width += growth
        expected[fixture.tokens[1]]?.origin.x += growth
        expected[fixture.tokens[1]]?.size.width -= growth
        XCTAssertEqual(try fixture.frames(), expected)
        XCTAssertGreaterThan(fixture.manager.worldSeq, worldSeq)
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

    func testPortraitPrimaryEdgesAdopt() throws {
        for (index, top) in [false, true].enumerated() {
            let fixture = try makeFixture(.niri, portrait: true, pid: pid_t(836_401 + index))
            fixture.controller.motionPolicy.animationsEnabled = false
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[1]
            let before = try fixture.frames()
            let start = try XCTUnwrap(before[token])
            let growth = start.height / 4
            let direction: CGFloat = top ? 1 : -1
            let press = CGPoint(
                x: start.midX,
                y: top ? start.maxY - FrameTolerance.frameWrite : start.minY + FrameTolerance.frameWrite
            )
            let drag = try beginEdgeDrag(
                fixture, of: token, at: press,
                draggedTo: CGPoint(
                    x: press.x,
                    y: top ? (press.y + FrameTolerance.frameWrite).nextUp : (press.y - FrameTolerance.frameWrite)
                        .nextDown
                )
            )
            let observed = top ? grown(start, top: growth) : grown(start, bottom: growth)
            XCTAssertTrue(try report(observed, for: drag, in: fixture))
            XCTAssertEqual(try fixture.frames(), before)

            fixture.handler.dispatchMouseUp(at: CGPoint(x: press.x, y: press.y + direction * growth))

            let adopted = try fixture.frame(token)
            XCTAssertEqual(adopted.height, start.height + growth, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(adopted.width, start.width, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(
                top ? adopted.minY : adopted.maxY,
                top ? start.minY : start.maxY,
                accuracy: FrameTolerance.frameWrite
            )
            XCTAssertEqual(try fixture.frame(fixture.tokens[0]).size, try XCTUnwrap(before[fixture.tokens[0]]).size)
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
            XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
            XCTAssertEqual(fixture.controller.axManager.lastAppliedFrame(for: token.windowId), start)
        }
    }

    func testPortraitCentredPrimaryResizesGrowAndShrinkAroundTheirCentre() throws {
        for (index, direction) in [CGFloat(-1), 1].enumerated() {
            let fixture = try makeFixture(.niri, portrait: true, pid: pid_t(836_411 + index))
            fixture.controller.motionPolicy.animationsEnabled = false
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let engine = try XCTUnwrap(fixture.controller.niriEngine)
            fixture.manager.withNiriViewportState(for: fixture.workspaceId) { _ in
                for column in engine.columns(in: fixture.workspaceId) {
                    column.height = .proportion(1.0 / 3.0)
                    column.cachedHeight = 0
                }
            }
            try fixture.confirmLayout()
            let token = fixture.tokens[1]
            let start = try fixture.frame(token)
            let travel = direction * start.height / 8
            let press = CGPoint(x: start.midX, y: start.maxY - FrameTolerance.frameWrite)
            let drag = try beginEdgeDrag(
                fixture, of: token, at: press,
                draggedTo: CGPoint(
                    x: press.x,
                    y: direction > 0
                        ? (press.y + FrameTolerance.frameWrite).nextUp
                        : (press.y - FrameTolerance.frameWrite).nextDown
                )
            )
            let observed = grown(start, bottom: travel, top: travel)
            XCTAssertTrue(try report(observed, for: drag, in: fixture))

            fixture.handler.dispatchMouseUp(at: CGPoint(x: press.x, y: press.y + travel))

            let adopted = try fixture.frame(token)
            XCTAssertEqual(adopted.height, start.height + 2 * travel, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(adopted.midY, start.midY, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(adopted.width, start.width, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
        }
    }

    func testPortraitPartialAndLateReportsCompleteAtTheReleaseAndUndoOnce() throws {
        for (index, reportBeforeRelease) in [false, true].enumerated() {
            let fixture = try makeFixture(.niri, portrait: true, pid: pid_t(836_421 + index))
            fixture.controller.motionPolicy.animationsEnabled = false
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let before = try fixture.frames()
            let start = try XCTUnwrap(before[token])
            let asked = start.height / 4
            let arrived = AXRecentFrameWriteFailure.maxAcceptedSizeSnap
            XCTAssertGreaterThan(asked - arrived, AXRecentFrameWriteFailure.maxAcceptedSizeSnap)
            let press = CGPoint(x: start.midX, y: start.maxY - FrameTolerance.frameWrite)
            let drag = try beginEdgeDrag(
                fixture, of: token, at: press,
                draggedTo: CGPoint(x: press.x, y: (press.y + FrameTolerance.frameWrite).nextUp)
            )
            let shown = grown(start, top: arrived)
            if reportBeforeRelease {
                XCTAssertTrue(try report(shown, for: drag, in: fixture))
            }

            fixture.handler.dispatchMouseUp(at: CGPoint(x: press.x, y: press.y + asked))

            if !reportBeforeRelease {
                XCTAssertEqual(fixture.phase, .awaitingFrameChange)
                let reference = try XCTUnwrap(fixture.entry(token).axRef)
                fixture.controller.axManager.applyFramesParallel([
                    AXFrameApplicationTarget(
                        pid: token.pid, window: reference, frame: start.offsetBy(dx: 0, dy: arrived)
                    )
                ])
                XCTAssertTrue(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
                XCTAssertTrue(try report(shown, for: drag, in: fixture))
            }
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
            let finished = try fixture.frames()
            XCTAssertEqual(
                try XCTUnwrap(finished[token]).height,
                start.height + asked,
                accuracy: FrameTolerance.frameWrite
            )
            XCTAssertEqual(try XCTUnwrap(finished[token]).width, start.width, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(fixture.controller.axManager.lastAppliedFrame(for: token.windowId), start)
            XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.liveStartFrame)
            XCTAssertNil(fixture.manager.cachedConstraints(for: token, maxAge: .greatestFiniteMagnitude))
            for later in [arrived + (asked - arrived) / 2, asked] {
                XCTAssertTrue(try report(grown(start, top: later), for: drag, in: fixture))
                XCTAssertEqual(try fixture.frames(), finished)
            }
            XCTAssertTrue(undo(fixture))
            XCTAssertEqual(try fixture.frames(), before)
            XCTAssertFalse(undo(fixture))
        }
    }

    func testPortraitMixedCornerResizesAdopt() throws {
        let fixture = try makeFixture(.niri, stacked: true, portrait: true, pid: 836_431)
        fixture.controller.motionPolicy.animationsEnabled = false
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (left, right) = try stackedLeftAndRight(fixture)
        let before = try fixture.frames()
        let start = try XCTUnwrap(before[left])
        let widthGrowth = start.width / 8
        let heightGrowth = start.height / 8

        let press = CGPoint(x: start.maxX - FrameTolerance.frameWrite, y: start.maxY - FrameTolerance.frameWrite)
        let drag = try beginEdgeDrag(
            fixture, of: left, at: press,
            draggedTo: CGPoint(
                x: (press.x + FrameTolerance.frameWrite).nextUp,
                y: (press.y + FrameTolerance.frameWrite).nextUp
            )
        )
        XCTAssertTrue(try report(grown(start, right: widthGrowth, top: heightGrowth), for: drag, in: fixture))
        XCTAssertEqual(try fixture.frames(), before)
        fixture.handler.dispatchMouseUp(at: CGPoint(x: press.x + widthGrowth, y: press.y + heightGrowth))

        XCTAssertEqual(
            try fixture.frame(left).width,
            start.width + widthGrowth,
            accuracy: FrameTolerance.frameWrite
        )
        XCTAssertEqual(
            try fixture.frame(left).height,
            start.height + heightGrowth,
            accuracy: FrameTolerance.frameWrite
        )
        XCTAssertEqual(try fixture.frame(left).minY, start.minY, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(
            try fixture.frame(right).width,
            try XCTUnwrap(before[right]).width - widthGrowth,
            accuracy: FrameTolerance.frameWrite
        )
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        fixture.handler.retireNativeTitleBarDragAtInputBoundary()
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.jumpOffset(to: state.viewOffset - 2 * heightGrowth)
        }
        let beforeCentred = try fixture.frames()
        try fixture.confirmLayout()
        let centredStart = try XCTUnwrap(beforeCentred[left])
        let workingFrame = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let gap = fixture.controller.innerGap(for: fixture.monitor)
        XCTAssertGreaterThanOrEqual(centredStart.minY - heightGrowth, workingFrame.minY + gap)
        XCTAssertLessThanOrEqual(centredStart.maxY + heightGrowth, workingFrame.maxY - gap)
        let centredPress = CGPoint(
            x: centredStart.maxX - FrameTolerance.frameWrite,
            y: centredStart.maxY - FrameTolerance.frameWrite
        )
        let centredDrag = try beginEdgeDrag(
            fixture, of: left, at: centredPress,
            draggedTo: CGPoint(
                x: (centredPress.x + FrameTolerance.frameWrite).nextUp,
                y: (centredPress.y + FrameTolerance.frameWrite).nextUp
            )
        )
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame, centredStart)
        XCTAssertTrue(try report(
            centredStart.insetBy(dx: -widthGrowth, dy: -heightGrowth), for: centredDrag, in: fixture
        ))
        fixture.handler.dispatchMouseUp(at: CGPoint(
            x: centredPress.x + widthGrowth, y: centredPress.y + heightGrowth
        ))

        XCTAssertEqual(
            try fixture.frame(left).width, centredStart.width + widthGrowth, accuracy: FrameTolerance.frameWrite
        )
        XCTAssertEqual(
            try fixture.frame(left).height, centredStart.height + 2 * heightGrowth,
            accuracy: FrameTolerance.frameWrite
        )
        XCTAssertEqual(try fixture.frame(left).midY, centredStart.midY, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(
            try fixture.frame(right).width,
            try XCTUnwrap(beforeCentred[right]).width - widthGrowth,
            accuracy: FrameTolerance.frameWrite
        )
    }

    func testPortraitSecondaryEdgesAdoptAndPreserveTheirOuterEdges() throws {
        for (index, leading) in [false, true].enumerated() {
            let fixture = try makeFixture(.niri, stacked: true, portrait: true, pid: pid_t(836_451 + index))
            fixture.controller.motionPolicy.animationsEnabled = false
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let (left, right) = try stackedLeftAndRight(fixture)
            let token = leading ? right : left
            let mate = leading ? left : right
            let before = try fixture.frames()
            let start = try XCTUnwrap(before[token])
            let mateStart = try XCTUnwrap(before[mate])
            let growth = min(start.width, mateStart.width) / 8
            let direction: CGFloat = leading ? -1 : 1
            let press = CGPoint(
                x: leading ? start.minX + FrameTolerance.frameWrite : start.maxX - FrameTolerance.frameWrite,
                y: start.midY
            )
            let drag = try beginEdgeDrag(
                fixture, of: token, at: press,
                draggedTo: CGPoint(
                    x: leading ? (press.x - FrameTolerance.frameWrite).nextDown
                        : (press.x + FrameTolerance.frameWrite).nextUp,
                    y: press.y
                )
            )
            let observed = leading ? grown(start, left: growth) : grown(start, right: growth)
            XCTAssertTrue(try report(observed, for: drag, in: fixture))
            XCTAssertEqual(try fixture.frames(), before)

            fixture.handler.dispatchMouseUp(at: CGPoint(x: press.x + direction * growth, y: press.y))

            let adopted = try fixture.frame(token)
            let neighbor = try fixture.frame(mate)
            XCTAssertEqual(adopted.width, start.width + growth, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(neighbor.width, mateStart.width - growth, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(
                leading ? adopted.maxX : adopted.minX,
                leading ? start.maxX : start.minX,
                accuracy: FrameTolerance.frameWrite
            )
            XCTAssertEqual(
                leading ? neighbor.minX : neighbor.maxX,
                leading ? mateStart.minX : mateStart.maxX,
                accuracy: FrameTolerance.frameWrite
            )
            XCTAssertEqual(adopted.height, start.height, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
            XCTAssertEqual(fixture.controller.axManager.lastAppliedFrame(for: token.windowId), start)
        }
    }

    func testPortraitSecondaryPartialAndLateReportsCompleteAtReleaseAndUndoBothWidths() throws {
        for (index, reportBeforeRelease) in [false, true].enumerated() {
            let fixture = try makeFixture(.niri, stacked: true, portrait: true, pid: pid_t(836_461 + index))
            fixture.controller.motionPolicy.animationsEnabled = false
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let (token, mate) = try stackedLeftAndRight(fixture)
            let before = try fixture.frames()
            let start = try XCTUnwrap(before[token])
            let mateStart = try XCTUnwrap(before[mate])
            let oldWidth = try fixture.niriNode(token).windowWidth
            let oldMateWidth = try fixture.niriNode(mate).windowWidth
            let asked = min(start.width, mateStart.width) / 4
            let arrived = AXRecentFrameWriteFailure.maxAcceptedSizeSnap
            XCTAssertGreaterThan(asked - arrived, AXRecentFrameWriteFailure.maxAcceptedSizeSnap)
            let press = CGPoint(x: start.maxX - FrameTolerance.frameWrite, y: start.midY)
            let drag = try beginEdgeDrag(
                fixture, of: token, at: press,
                draggedTo: CGPoint(x: (press.x + FrameTolerance.frameWrite).nextUp, y: press.y)
            )
            let shown = grown(start, right: arrived)
            if reportBeforeRelease {
                XCTAssertTrue(try report(shown, for: drag, in: fixture))
                XCTAssertEqual(try fixture.frames(), before)
            }
            fixture.handler.dispatchMouseUp(at: CGPoint(x: press.x + asked, y: press.y))
            if !reportBeforeRelease {
                XCTAssertEqual(fixture.phase, .awaitingFrameChange)
                fixture.controller.axManager.applyFramesParallel([
                    AXFrameApplicationTarget(
                        pid: token.pid, window: try XCTUnwrap(fixture.entry(token).axRef),
                        frame: start.offsetBy(dx: arrived, dy: 0)
                    )
                ])
                XCTAssertTrue(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
                XCTAssertTrue(try report(shown, for: drag, in: fixture))
            }
            let finished = try fixture.frames()
            XCTAssertEqual(
                try XCTUnwrap(finished[token]).width,
                start.width + asked,
                accuracy: FrameTolerance.frameWrite
            )
            XCTAssertEqual(
                try XCTUnwrap(finished[mate]).width,
                mateStart.width - asked,
                accuracy: FrameTolerance.frameWrite
            )
            XCTAssertEqual(try XCTUnwrap(finished[token]).height, start.height, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
            XCTAssertEqual(fixture.controller.axManager.lastAppliedFrame(for: token.windowId), start)
            for later in [arrived + (asked - arrived) / 2, asked] {
                XCTAssertTrue(try report(grown(start, right: later), for: drag, in: fixture))
                XCTAssertEqual(try fixture.frames(), finished)
            }
            XCTAssertTrue(undo(fixture))
            XCTAssertEqual(try fixture.frames(), before)
            XCTAssertEqual(try fixture.niriNode(token).windowWidth, oldWidth)
            XCTAssertEqual(try fixture.niriNode(mate).windowWidth, oldMateWidth)
            XCTAssertFalse(undo(fixture))
        }
    }

    func testAResizeReleasedWhileTheWindowIsBehindEndsAtThePointersSize() throws {
        let fixture = try makeFixture(.niri, pid: 834_013)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let drag = try beginEdgeDrag(fixture, of: fixture.tokens[0])
        let asked: CGFloat = 240
        let arrived: CGFloat = 20
        XCTAssertGreaterThan(asked - arrived, AXRecentFrameWriteFailure.maxAcceptedSizeSnap)
        let shown = grown(drag.start, right: arrived)
        XCTAssertTrue(try report(shown, for: drag, in: fixture))

        letGo(fixture, of: drag, afterMovingRight: asked)

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertEqual(try fixture.frame(drag.token).width, drag.start.width + asked)
        XCTAssertEqual(fixture.controller.axManager.lastAppliedFrame(for: drag.token.windowId), shown)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.liveStartFrame)
        XCTAssertNil(fixture.manager.cachedConstraints(for: drag.token, maxAge: .greatestFiniteMagnitude))
    }

    func testTheAppsLaterReportsOfAFinishedResizeChangeNothing() throws {
        let fixture = try makeFixture(.niri, pid: 834_014)
        fixture.controller.motionPolicy.animationsEnabled = false
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let before = try fixture.frames()
        let drag = try beginEdgeDrag(fixture, of: fixture.tokens[0])
        let asked: CGFloat = 240
        let arrived: CGFloat = 20
        XCTAssertGreaterThan(asked - arrived, AXRecentFrameWriteFailure.maxAcceptedSizeSnap)
        XCTAssertTrue(try report(grown(drag.start, right: arrived), for: drag, in: fixture))
        letGo(fixture, of: drag, afterMovingRight: asked)
        let finished = try fixture.frames()
        XCTAssertNotEqual(finished, before)

        for later in [arrived + (asked - arrived) / 2, asked] {
            XCTAssertTrue(try report(grown(drag.start, right: later), for: drag, in: fixture))
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
            XCTAssertEqual(try fixture.frames(), finished)
        }

        XCTAssertTrue(undo(fixture))
        XCTAssertEqual(try fixture.frames(), before)
        XCTAssertFalse(undo(fixture))
    }

    func testAWindowAlreadyAtThePointersSizeKeepsItsOwnSize() throws {
        let fixture = try makeFixture(.niri, pid: 834_016)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let drag = try beginEdgeDrag(fixture, of: fixture.tokens[0])
        let asked: CGFloat = 180
        let shown = grown(drag.start, right: asked - AXRecentFrameWriteFailure.maxAcceptedSizeSnap)
        XCTAssertTrue(try report(shown, for: drag, in: fixture))

        letGo(fixture, of: drag, afterMovingRight: asked)

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertEqual(try fixture.frame(drag.token).width, shown.width)
    }

    func testAWindowThatMovedFurtherThanThePointerKeepsItsOwnSize() throws {
        let moved: CGFloat = 200
        for (index, travel) in [0, moved / 2, -moved].enumerated() {
            let fixture = try makeFixture(.niri, pid: pid_t(834_101 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let drag = try beginEdgeDrag(fixture, of: fixture.tokens[0])
            let shown = grown(drag.start, right: moved)
            XCTAssertTrue(try report(shown, for: drag, in: fixture), "\(travel)")

            letGo(fixture, of: drag, afterMovingRight: travel)

            XCTAssertEqual(fixture.phase, .awaitingCorrection, "\(travel)")
            XCTAssertEqual(try fixture.frame(drag.token).width, shown.width, "\(travel)")
        }
    }

    func testAResizeReleasedPastAMinimumOmniWMHoldsEndsAtTheMinimum() throws {
        let room: CGFloat = 100
        let arrived: CGFloat = 20
        XCTAssertGreaterThan(room - arrived, AXRecentFrameWriteFailure.maxAcceptedSizeSnap)
        for (index, learned) in [true, false].enumerated() {
            let fixture = try makeFixture(.niri, pid: pid_t(834_121 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let minimum = try fixture.frame(token).width - room
            if learned {
                var evidence = ObservedSizeEvidence()
                evidence.minSize.width = minimum
                XCTAssertTrue(fixture.manager.setObservedSizeEvidence(evidence, for: token))
            } else {
                var limits = WindowSizeConstraints.unconstrained
                limits.minSize.width = minimum
                fixture.manager.setCachedConstraints(limits, for: token)
            }
            let drag = try beginEdgeDrag(fixture, of: token)
            XCTAssertTrue(try report(grown(drag.start, right: -arrived), for: drag, in: fixture), "\(learned)")

            letGo(fixture, of: drag, afterMovingRight: -(room + room))

            XCTAssertEqual(fixture.phase, .awaitingCorrection, "\(learned)")
            XCTAssertEqual(try fixture.frame(token).width, minimum, "\(learned)")
        }
    }

    func testAResizeFirstShownAfterTheReleaseIsTakenAtOnceOverAPendingLayoutWrite() throws {
        let asked: CGFloat = 240
        let arrived: CGFloat = 20
        XCTAssertGreaterThan(asked - arrived, AXRecentFrameWriteFailure.maxAcceptedSizeSnap)
        for (index, firstShown) in [arrived, asked].enumerated() {
            let fixture = try makeFixture(.niri, pid: pid_t(834_111 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let drag = try beginEdgeDrag(fixture, of: fixture.tokens[0])
            letGo(fixture, of: drag, afterMovingRight: asked)
            XCTAssertEqual(fixture.phase, .awaitingFrameChange, "\(firstShown)")
            let reference = try XCTUnwrap(fixture.entry(drag.token).axRef)
            fixture.controller.axManager.applyFramesParallel([
                AXFrameApplicationTarget(
                    pid: drag.token.pid,
                    window: reference,
                    frame: drag.start.offsetBy(dx: arrived, dy: 0)
                )
            ])
            XCTAssertTrue(fixture.controller.axManager.isAwaitingFrameWrite(drag.token.windowId), "\(firstShown)")

            XCTAssertTrue(try report(grown(drag.start, right: firstShown), for: drag, in: fixture), "\(firstShown)")

            XCTAssertEqual(fixture.phase, .awaitingCorrection, "\(firstShown)")
            XCTAssertEqual(try fixture.frame(drag.token).width, drag.start.width + asked, "\(firstShown)")
        }
    }

    func testALateResizeIsSizedByItsOwnDragAfterAPressOnAnOmniWMSurface() throws {
        let fixture = try makeFixture(.niri, pid: 834_018)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let drag = try beginEdgeDrag(fixture, of: fixture.tokens[0])
        let asked: CGFloat = 240
        let arrived: CGFloat = 20
        XCTAssertGreaterThan(asked - arrived, AXRecentFrameWriteFailure.maxAcceptedSizeSnap)
        letGo(fixture, of: drag, afterMovingRight: asked)
        XCTAssertEqual(fixture.phase, .awaitingFrameChange)

        let surface = fixture.monitor.frame.offsetBy(dx: -fixture.monitor.frame.width, dy: 0)
        let surfaceId = "press-after-release-\(drag.token.windowId)"
        fixture.controller.ownedWindowRegistry.registerWindowNumber(
            surfaceId: surfaceId,
            policy: SurfacePolicy(
                kind: .utility,
                hitTestPolicy: .interactive,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: true
            ),
            windowNumber: drag.token.windowId + fixture.tokens.count,
            frameProvider: { surface },
            visibilityProvider: { true }
        )
        defer { fixture.controller.ownedWindowRegistry.unregister(surfaceId: surfaceId) }
        XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: surface.center, modifiers: []))
        XCTAssertEqual(fixture.handler.state.leftPressLocation, surface.center)
        XCTAssertEqual(fixture.phase, .awaitingFrameChange)

        XCTAssertTrue(try report(grown(drag.start, right: arrived), for: drag, in: fixture))

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertEqual(try fixture.frame(drag.token).width, drag.start.width + asked)
    }

    func testAReportAfterAFinishedResizeWasWrittenDoesNotResizeAgain() throws {
        let fixture = try makeFixture(.niri, pid: 834_019)
        fixture.wireFrameApplyCallbacks()
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let drag = try beginEdgeDrag(fixture, of: fixture.tokens[0])
        let asked: CGFloat = 200
        let fallenBack = asked - (AXRecentFrameWriteFailure.maxAcceptedSizeSnap + FrameTolerance.frameWrite).nextUp
        XCTAssertTrue(try report(grown(drag.start, right: asked), for: drag, in: fixture))
        letGo(fixture, of: drag, afterMovingRight: asked)
        let finished = try fixture.frame(drag.token)
        XCTAssertEqual(finished.width, drag.start.width + asked)
        drag.reported.frame = finished
        fixture.controller.axManager.forceApplyNextFrame(for: drag.token.windowId)
        try fixture.confirmWrite(of: drag.token)
        XCTAssertEqual(fixture.phase, .awaitingFrameChange)
        fixture.controller.layoutRefreshController.stopScrollAnimation(for: fixture.monitor.displayId)

        XCTAssertTrue(try report(grown(drag.start, right: fallenBack), for: drag, in: fixture))
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertEqual(try fixture.frame(drag.token), finished)

        fixture.handler.retireNativeTitleBarDragAtInputBoundary()

        XCTAssertNil(fixture.phase)
        XCTAssertEqual(try fixture.frame(drag.token), finished)
    }

    func testAnAppThatWillNotGrowAsFarAsAskedLeavesTheColumnAtTheAskedWidth() throws {
        let fixture = try makeFixture(.niri, pid: 834_020)
        fixture.controller.serviceLifecycleManager.connectAXFrameCallbacks(fixture.controller)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let drag = try beginEdgeDrag(fixture, of: fixture.tokens[0])
        let asked: CGFloat = 240
        let arrived: CGFloat = 20
        XCTAssertGreaterThan(asked - arrived, AXRecentFrameWriteFailure.maxAcceptedSizeSnap)
        XCTAssertTrue(try report(grown(drag.start, right: arrived), for: drag, in: fixture))
        letGo(fixture, of: drag, afterMovingRight: asked)
        let finished = try fixture.frame(drag.token)

        try fixture.refuseWrite(of: drag.token, growingWidthBy: arrived - asked)

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertNotNil(fixture.handler.state.nativeTitleBarDrag?.terminalFailureRetryRequestId)
        XCTAssertEqual(try fixture.frame(drag.token), finished)

        try fixture.refuseWrite(of: drag.token, growingWidthBy: arrived - asked)

        XCTAssertNil(fixture.phase)
        XCTAssertEqual(try fixture.frame(drag.token), finished)
        let unlearned = ObservedSizeEvidence().minSize.width
        XCTAssertEqual(fixture.manager.observedSizeEvidence(for: drag.token)?.minSize.width ?? unlearned, unlearned)
    }

    func testAResizeIsCompletedOnAnAxisOnlyWhereTheWindowIsBehindThePointer() {
        let start: CGFloat = 800
        let snap = AXRecentFrameWriteFailure.maxAcceptedSizeSnap
        func completed(observed: CGFloat, asked: CGFloat) -> CGFloat {
            MouseEventHandler.completedNativeResizeLength(from: start, observed: observed, asked: asked)
        }
        for direction: CGFloat in [1, -1] {
            let asked = start + direction * 10 * snap
            let behind = start + direction * snap
            XCTAssertEqual(completed(observed: behind, asked: asked), asked, "\(direction)")
            let within = asked - direction * snap
            XCTAssertEqual(completed(observed: within, asked: asked), within, "\(direction)")
            let justBehind = direction > 0 ? within.nextDown : within.nextUp
            XCTAssertEqual(completed(observed: justBehind, asked: asked), asked, "\(direction)")
            let beyond = asked + direction * 2 * snap
            XCTAssertEqual(completed(observed: beyond, asked: asked), beyond, "\(direction)")
            let opposite = start - direction * 2 * snap
            XCTAssertEqual(completed(observed: opposite, asked: asked), opposite, "\(direction)")
            XCTAssertEqual(completed(observed: start, asked: asked), start, "\(direction)")
            XCTAssertEqual(completed(observed: behind, asked: start), behind, "\(direction)")
        }
    }

    func testACompletedFrameKeepsTheEdgesThatDidNotMove() {
        let observed = CGRect(x: 100, y: 50, width: 400, height: 300)
        let size = CGSize(width: 520, height: 360)
        func frame(_ edges: ResizeEdge) -> CGRect {
            MouseEventHandler.nativeResizeFrame(observed, edges: edges, size: size)
        }
        XCTAssertEqual(frame(.right).minX, observed.minX)
        XCTAssertEqual(frame(.left).maxX, observed.maxX)
        XCTAssertEqual(frame([.left, .right]).midX, observed.midX)
        XCTAssertEqual(frame(.top).minY, observed.minY)
        XCTAssertEqual(frame(.bottom).maxY, observed.maxY)
        XCTAssertEqual(frame([.bottom, .top]).midY, observed.midY)
        for edges: ResizeEdge in [.right, .left, [.left, .right], .top, .bottom, [.bottom, .top], [.left, .top]] {
            XCTAssertEqual(frame(edges).size, size)
        }
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

    func testOnAPortraitStripAStackedEdgeSetsTheExactWidth() throws {
        let fixture = try makeFixture(.niri, stacked: true, portrait: true, pid: 834_013)
        fixture.controller.motionPolicy.animationsEnabled = false
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (left, right) = try stackedLeftAndRight(fixture)
        let leftStart = try fixture.frame(left)
        let rightStart = try fixture.frame(right)

        try fixture.release(left, at: grown(leftStart, right: 100))

        XCTAssertEqual(try fixture.frame(left).width, leftStart.width + 100, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(try fixture.frame(right).width, rightStart.width - 100, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(try fixture.frame(left).height, leftStart.height, accuracy: FrameTolerance.frameWrite)
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

    func testDwindleSplitEdgeMovesTheSharedSplitWithExplicitAndInferredEdges() throws {
        for usesExplicitEdge in [true, false] {
            let fixture = try makeFixture(.dwindle, pid: 834_021)
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let (left, right) = (fixture.tokens[0], fixture.tokens[1])
            let leftStart = try fixture.frame(left)
            let rightStart = try fixture.frame(right)
            XCTAssertLessThan(leftStart.maxX, rightStart.minX + 1)
            let growth = leftStart.width / 4

            try fixture.release(
                left, at: grown(leftStart, right: growth),
                press: usesExplicitEdge ? CGPoint(x: leftStart.maxX - FrameTolerance.frameWrite, y: leftStart.midY) :
                    nil
            )

            XCTAssertEqual(try fixture.frame(left).width, leftStart.width + growth, accuracy: FrameTolerance.frameWrite)
            XCTAssertEqual(
                try fixture.frame(right).width,
                rightStart.width - growth,
                accuracy: FrameTolerance.frameWrite
            )
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
            XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        }
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

    func testDwindleNativeCenteredResizeCrossesNestedMinimumClampAndReturns() throws {
        let fixture = try makeNestedCenteredNativeResizeFixture(pid: 835_401)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let span = area.width / 2
        let initial = centeredNativeHorizontalFrames(
            fixture, rawWidths: [span, 7 * span / 64, 21 * span / 64, 9 * span / 16]
        )
        XCTAssertEqual(try fixture.frames(), initial)
        let token = fixture.tokens[1]
        let start = try XCTUnwrap(initial[token])
        let press = CGPoint(x: start.maxX - FrameTolerance.frameWrite, y: start.midY)
        let breakpointGrowth = span / 8
        let requestedGrowth = 3 * span / 16
        let breakpointFrame = start.insetBy(dx: -breakpointGrowth, dy: 0)
        let reported = try XCTUnwrap(fixture.nativeFrames[token.windowId])
        var nativeFrameReads = 0
        fixture.handler.nativeWindowFrameProvider = { _ in
            nativeFrameReads += 1
            return reported.frame
        }
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        MouseEventHandler._instance = fixture.handler
        fixture.handler.syncTapFilterSnapshot()
        let tap = fixture.handler.inputTapThread
        let intake = fixture.controller.eventIntake
        intake.open(sink: fixture.controller.eventInterpreter)
        defer { intake.close() }
        var baselineCollections = 0
        tap.evaluateLeftMouseDown(
            at: press, modifiers: .maskAlternate, timestamp: 0, snapshot: tap.filterSnapshot
        ) {
            baselineCollections += 1
            return [token: ScreenCoordinateSpace.toWindowServer(rect: start)]
        }
        reported.frame = breakpointFrame
        intake.drainNow()
        XCTAssertEqual(baselineCollections, 1)
        XCTAssertEqual(nativeFrameReads, 0)
        XCTAssertEqual(fixture.handler.state.nativeResizeStart?.frame, start)
        XCTAssertEqual(fixture.handler.state.nativeResizeStart?.location, press)
        XCTAssertEqual(fixture.handler.state.leftPressModifiers, .maskAlternate)
        XCTAssertFalse(fixture.handler.state.isMoving)

        fixture.handler.receiveAnnotatedNativeMouseDragged(
            at: CGPoint(x: press.x + breakpointGrowth, y: press.y), windowIdUnderPointer: token.windowId
        )
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
        XCTAssertEqual(try fixture.frames(), centeredNativeHorizontalFrames(
            fixture, rawWidths: [7 * span / 8, 23 * span / 64, 13 * span / 64, 9 * span / 16]
        ))
        XCTAssertNotNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertTrue(fixture.handler.isInteractiveGestureActive)

        reported.frame = start.insetBy(dx: -requestedGrowth, dy: 0)
        fixture.handler.dispatchMouseDragged(at: CGPoint(x: press.x + requestedGrowth, y: press.y))
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
        let expanded = try fixture.frames()
        XCTAssertEqual(expanded, centeredNativeHorizontalFrames(
            fixture, rawWidths: [13 * span / 16, 31 * span / 64, 7 * span / 64, 19 * span / 32]
        ))
        XCTAssertEqual(expanded[token]?.midX, start.midX)
        XCTAssertEqual(expanded[token]?.minY, start.minY)
        XCTAssertEqual(expanded[token]?.maxY, start.maxY)
        XCTAssertEqual(expanded[fixture.tokens[0]]?.minX, area.minX)
        XCTAssertEqual(expanded[fixture.tokens[3]]?.maxX, area.maxX)

        reported.frame = start
        fixture.handler.dispatchMouseDragged(at: press)
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
        XCTAssertEqual(try fixture.frames(), initial)
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.dispatchMouseUp(at: press)
        XCTAssertEqual(try fixture.frames(), initial)
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
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

    func testDwindleNativeResizeFollowsLeftTopAndBottomEdgesWithExplicitAndInferredEdges() throws {
        for usesExplicitEdge in [true, false] {
            let cases: [(Bool, Int, (CGRect) -> CGRect, (CGRect) -> CGPoint)] = [
                (false, 1, { self.grown($0, left: 80) }, {
                    CGPoint(x: $0.minX + FrameTolerance.frameWrite, y: $0.midY)
                }),
                (true, 0, { self.grown($0, top: 80) }, {
                    CGPoint(x: $0.midX, y: $0.maxY - FrameTolerance.frameWrite)
                }),
                (true, 2, { self.grown($0, bottom: 80) }, {
                    CGPoint(x: $0.midX, y: $0.minY + FrameTolerance.frameWrite)
                })
            ]
            for (index, (stacked, tokenIndex, change, edgePress)) in cases.enumerated() {
                let fixture = try makeFixture(
                    .dwindle, stacked: stacked, windowCount: stacked ? 3 : 2, pid: pid_t(834_096 + index)
                )
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                let token = fixture.tokens[tokenIndex]
                let start = try fixture.frame(token)
                let observed = change(start)
                try fixture.beginDrag(token, at: usesExplicitEdge ? edgePress(start) : nil)

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

    func testDwindleNativeCornerResizeCanDiscoverTheSecondAxisLaterWithExplicitAndInferredEdges() throws {
        for usesExplicitEdge in [true, false] {
            let fixture = try makeFixture(.dwindle, stacked: true, windowCount: 3, pid: 834_088)
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let aboveStart = try fixture.frame(fixture.tokens[2])
            try fixture.beginDrag(
                token, at: usesExplicitEdge ? CGPoint(
                    x: start.maxX - FrameTolerance.frameWrite,
                    y: start.maxY - FrameTolerance.frameWrite
                ) : nil
            )
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

    func testDwindleNativeResizeKeepsUpdatesActiveUntilRelease() throws {
        let fixture = try makeFixture(.dwindle, pid: 834_090)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        try fixture.beginDrag(token)
        fixture.updateDrag(token, at: grown(start, right: 100))
        fixture.updateDrag(token, at: grown(start, right: 180))

        XCTAssertNotNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertTrue(fixture.handler.isInteractiveGestureActive)
        XCTAssertEqual(try fixture.frame(token).width, start.width + 180, accuracy: FrameTolerance.frameWrite)
        fixture.handler.dispatchMouseUp(at: start.center)
        XCTAssertEqual(try fixture.frame(token).width, start.width + 180, accuracy: FrameTolerance.frameWrite)
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
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

    func testNativeResizeRequiresAMovableDwindleEdge() throws {
        let cases: [(LayoutType, Bool, ResizeEdge, (CGRect, CGFloat) -> CGRect)] = [
            (.niri, true, [], { self.grown($0, right: $1) }),
            (.dwindle, false, .right, { self.grown($0, right: $1) }),
            (.dwindle, true, .right, { $0.offsetBy(dx: $1, dy: 0) }),
            (.dwindle, true, .left, { self.grown($0, left: $1) })
        ]
        for (index, (layout, refuses, edge, change)) in cases.enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_091 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let before = try fixture.frames()
            let start = try fixture.frame(token)
            let press = edge.isEmpty ? nil : CGPoint(
                x: edge == .right ? start.maxX - FrameTolerance.frameWrite : start.minX + FrameTolerance.frameWrite,
                y: start.midY
            )
            try fixture.beginDrag(token, at: press)
            let worldSeq = fixture.manager.worldSeq
            let constraintRefreshEventCount: UInt64 = 1

            for delta: CGFloat in [20, 60, 100, 40] {
                fixture.updateDrag(token, at: change(start, delta))

                if layout == .dwindle, !refuses {
                    var expected = before
                    expected[token]?.size.width += delta
                    expected[fixture.tokens[1]]?.origin.x += delta
                    expected[fixture.tokens[1]]?.size.width -= delta
                    XCTAssertEqual(try fixture.frames(), expected)
                    XCTAssertNotNil(fixture.controller.dwindleEngine?.interactiveResize)
                    XCTAssertTrue(fixture.handler.isInteractiveGestureActive)
                    XCTAssertEqual(fixture.manager.worldSeq, worldSeq + constraintRefreshEventCount)
                } else {
                    XCTAssertEqual(try fixture.frames(), before)
                    XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
                    XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
                    XCTAssertEqual(fixture.manager.worldSeq, worldSeq, "case \(index), delta \(delta)")
                }
            }
            if layout == .dwindle, !refuses {
                fixture.handler.dispatchMouseUp(at: start.center)
                XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
                XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
                XCTAssertGreaterThan(fixture.manager.worldSeq, worldSeq)
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

    func testEdgeJitterAndTwoSidedResizesAreStillCorrected() throws {
        let changes: [(isMove: Bool, change: (CGRect) -> CGRect)] = [
            (true, { $0.offsetBy(dx: 40, dy: 0) }),
            (true, { $0.offsetBy(dx: 0, dy: -30) }),
            (false, { $0.insetBy(dx: -20, dy: 0) })
        ]
        var pid: pid_t = 834_031
        for layout in [LayoutType.niri, .dwindle] {
            for (isMove, change) in changes {
                let fixture = try makeFixture(layout, portrait: layout == .niri, pid: pid)
                pid += 1
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                let before = try fixture.frames()
                let worldSeq = fixture.manager.worldSeq

                let start = try fixture.frame(fixture.tokens[0])
                let press = isMove
                    ? CGPoint(x: start.maxX - FrameTolerance.frameWrite, y: start.midY)
                    : nil
                try fixture.release(fixture.tokens[0], at: change(start), press: press)

                if press != nil {
                    XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.canStartLiveNiriDrag, false)
                }
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
        let fixture = try makeFixture(.niri, portrait: true, pid: 834_042)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        try fixture.release(token, at: start.insetBy(dx: -20, dy: 0))
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

    func testAnEdgeDragDuringAPendingWriteStartsFromThePendingFrame() throws {
        let fixture = try makeFixture(.niri, pid: 834_047)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        let reference = try XCTUnwrap(fixture.entry(token).axRef)
        let pending = start.offsetBy(dx: -30, dy: 0)
        fixture.controller.axManager.applyFramesParallel([
            AXFrameApplicationTarget(pid: token.pid, window: reference, frame: pending)
        ])
        XCTAssertTrue(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
        let grownFrame = grown(pending, right: 200)
        fixture.handler.nativeWindowFrameProvider = { _ in grownFrame }

        try fixture.beginDrag(token)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.pendingWriteStartFrame, pending)
        fixture.handler.dispatchMouseUp(at: grownFrame.center)

        XCTAssertEqual(try fixture.frame(token).width, grownFrame.width, accuracy: FrameTolerance.frameWrite)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.pendingWriteStartFrame)
    }

    func testOnAPortraitStripAnEdgeDragDuringAPendingWriteIsPutBack() throws {
        let fixture = try makeFixture(.niri, portrait: true, pid: 834_048)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        let reference = try XCTUnwrap(fixture.entry(token).axRef)
        let pending = start.offsetBy(dx: -30, dy: 0)
        fixture.controller.axManager.applyFramesParallel([
            AXFrameApplicationTarget(pid: token.pid, window: reference, frame: pending)
        ])
        XCTAssertTrue(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
        let grownFrame = grown(pending, right: 200)
        fixture.handler.nativeWindowFrameProvider = { _ in grownFrame }

        try fixture.beginDrag(token)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.pendingWriteStartFrame)
        fixture.handler.dispatchMouseUp(at: grownFrame.center)

        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
    }

    func testPortraitPrimaryResizeDuringAPendingPositionWriteUsesThatBaseline() throws {
        let fixture = try makeFixture(.niri, portrait: true, pid: 836_441)
        fixture.controller.motionPolicy.animationsEnabled = false
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[1]
        let start = try fixture.frame(token)
        let reference = try XCTUnwrap(fixture.entry(token).axRef)
        let pending = start.offsetBy(dx: 0, dy: -start.height / 16)
        fixture.controller.axManager.applyFramesParallel([
            AXFrameApplicationTarget(pid: token.pid, window: reference, frame: pending)
        ])
        XCTAssertTrue(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
        let growth = start.height / 4
        let observed = grown(pending, top: growth)
        fixture.handler.nativeWindowFrameProvider = { _ in observed }
        let press = CGPoint(x: pending.midX, y: pending.maxY - FrameTolerance.frameWrite)

        try fixture.beginDrag(
            token, at: press,
            draggedTo: CGPoint(x: press.x, y: (press.y + FrameTolerance.frameWrite).nextUp)
        )
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.pendingWriteStartFrame, pending)
        fixture.handler.dispatchMouseUp(at: CGPoint(x: press.x, y: press.y + growth))

        XCTAssertEqual(try fixture.frame(token).height, observed.height, accuracy: FrameTolerance.frameWrite)
        XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.pendingWriteStartFrame)
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
    }

    func testPortraitSecondaryPendingPositionBaselineDoesNotAdoptAPendingSizeChange() throws {
        for (index, changesSize) in [false, true].enumerated() {
            let fixture = try makeFixture(.niri, stacked: true, portrait: true, pid: pid_t(836_471 + index))
            fixture.controller.motionPolicy.animationsEnabled = false
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let (token, _) = try stackedLeftAndRight(fixture)
            let before = try fixture.frames()
            let start = try XCTUnwrap(before[token])
            let displacement = start.width / 16
            let growth = start.width / 8
            let travel = 2 * growth
            var pending = start.offsetBy(dx: -displacement, dy: 0)
            if changesSize { pending.size.width -= growth }
            fixture.controller.axManager.applyFramesParallel([
                AXFrameApplicationTarget(
                    pid: token.pid, window: try XCTUnwrap(fixture.entry(token).axRef), frame: pending
                )
            ])
            XCTAssertTrue(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
            let observed = grown(pending, right: travel)
            fixture.handler.nativeWindowFrameProvider = { _ in observed }
            let press = CGPoint(x: pending.maxX - FrameTolerance.frameWrite, y: pending.midY)
            XCTAssertEqual(
                NiriLayoutEngine.fusionDoubleClickZone(
                    at: press, in: pending, gap: fixture.controller.innerGap(for: fixture.monitor),
                    bounds: fixture.monitor.visibleFrame
                ),
                .edge(.right)
            )

            try fixture.beginDrag(
                token, at: press,
                draggedTo: CGPoint(x: (press.x + FrameTolerance.frameWrite).nextUp, y: press.y)
            )
            XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
            XCTAssertEqual(
                fixture.handler.state.nativeTitleBarDrag?.pendingWriteStartFrame,
                changesSize ? nil : pending
            )
            fixture.handler.dispatchMouseUp(at: CGPoint(x: press.x + travel, y: press.y))

            if changesSize {
                XCTAssertEqual(try fixture.frames(), before)
            } else {
                XCTAssertEqual(try fixture.frame(token).width, observed.width, accuracy: FrameTolerance.frameWrite)
                XCTAssertEqual(try fixture.frame(token).height, start.height, accuracy: FrameTolerance.frameWrite)
            }
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
            XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.pendingWriteStartFrame)
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

    func testAnUnannotatedDragBegunDuringASlideEndsTheSlideAndItsResizeIsAdopted() async throws {
        let fixture = try makeFixture(.niri, pid: 834_109)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let token = fixture.tokens[0]
        let pressedFrame = try fixture.frame(token)
        let reported = ReportedFrame(fixture.controller.axManager.lastAppliedFrame(for: token.windowId))
        fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.animateToOffset(state.viewOffset + 120, motion: .enabled, scale: 2)
        }
        fixture.controller.niriLayoutHandler.startScrollAnimationIfNeeded(
            for: fixture.workspaceId,
            state: fixture.manager.niriViewportState(for: fixture.workspaceId),
            engine: engine
        )

        XCTAssertFalse(fixture.handler.dispatchMouseDown(at: pressedFrame.center, modifiers: []))

        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDragFallbackToken, token)
        XCTAssertTrue(fixture.manager.animationDriver.hasMotion(in: fixture.workspaceId))

        fixture.handler.dispatchMouseDragged(at: nativeDragLocation(from: pressedFrame))

        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertFalse(fixture.manager.animationDriver.hasMotion(in: fixture.workspaceId))

        fixture.controller.niriLayoutHandler.tickScrollAnimation(
            targetTime: fixture.controller.animationClock.now(),
            displayId: fixture.monitor.displayId
        )
        let observed = grown(try fixture.frame(token), right: 120)
        reported.frame = observed
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))

        XCTAssertEqual(fixture.phase, .dragging)

        fixture.handler.dispatchMouseUp(at: observed.center)
        fixture.controller.niriLayoutHandler.tickScrollAnimation(
            targetTime: fixture.controller.animationClock.now(),
            displayId: fixture.monitor.displayId
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try fixture.frame(token).width, observed.width, accuracy: FrameTolerance.frameWrite)
    }

    func testAResizeReportedBeforeTheSlideSettlesIsAdoptedWhenItDoes() async throws {
        let fixture = try makeFixture(.niri, pid: 834_110)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let token = fixture.tokens[0]
        let pressedFrame = try fixture.frame(token)
        let reported = ReportedFrame(fixture.controller.axManager.lastAppliedFrame(for: token.windowId))
        fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.animateToOffset(state.viewOffset + 120, motion: .enabled, scale: 2)
        }
        fixture.controller.niriLayoutHandler.startScrollAnimationIfNeeded(
            for: fixture.workspaceId,
            state: fixture.manager.niriViewportState(for: fixture.workspaceId),
            engine: engine
        )
        XCTAssertFalse(fixture.handler.dispatchMouseDown(at: pressedFrame.center, modifiers: []))
        fixture.handler.dispatchMouseDragged(at: nativeDragLocation(from: pressedFrame))
        XCTAssertTrue(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.workspaceId))

        let observed = grown(try fixture.frame(token), right: 120)
        reported.frame = observed
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.dispatchMouseUp(at: observed.center)

        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDragFallbackToken, token)

        fixture.controller.niriLayoutHandler.tickScrollAnimation(
            targetTime: fixture.controller.animationClock.now(),
            displayId: fixture.monitor.displayId
        )
        fixture.controller.niriLayoutHandler.tickScrollAnimation(
            targetTime: fixture.controller.animationClock.now(),
            displayId: fixture.monitor.displayId
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try fixture.frame(token).width, observed.width, accuracy: FrameTolerance.frameWrite)
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
                let fixture = try makeFixture(layout, portrait: layout == .niri, pid: pid_t(835_001 + scenario))
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

    func testAnUnannotatedPrimaryEdgeDragIsKeptInBothLayouts() throws {
        let strips: [(layout: LayoutType, portrait: Bool, pid: pid_t)] = [
            (.niri, false, 835_301), (.niri, true, 835_302), (.dwindle, false, 835_303)
        ]
        for strip in strips {
            let fixture = try makeFixture(strip.layout, portrait: strip.portrait, pid: strip.pid)
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let alongTheStrip: KeyPath<CGRect, CGFloat> = strip.portrait ? \.height : \.width
            let observed = strip.portrait ? grown(start, top: 100) : grown(start, right: 100)
            let reported = ReportedFrame(start)
            fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            let press: CGPoint
            if strip.layout == .dwindle {
                press = CGPoint(x: start.maxX - FrameTolerance.frameWrite, y: start.midY)
            } else {
                press = strip.portrait
                    ? CGPoint(x: start.midX, y: start.maxY - FrameTolerance.frameWrite) : start.center
            }
            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: press, modifiers: []))
            let resizeStart = try XCTUnwrap(fixture.handler.state.nativeResizeStart)
            XCTAssertEqual(resizeStart.token, token)
            XCTAssertEqual(resizeStart.frame, start)
            XCTAssertEqual(resizeStart.location, press)
            XCTAssertFalse(resizeStart.wasDragged)
            XCTAssertEqual(fixture.handler.state.nativeTitleBarDragFallbackToken, token, "\(strip)")
            let dragLocation = strip.portrait
                ? CGPoint(x: press.x, y: (press.y + FrameTolerance.frameWrite).nextUp)
                : nativeDragLocation(from: start)
            fixture.handler.dispatchQueuedMouseDragged(at: dragLocation, button: .left)

            reported.frame = observed
            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
            fixture.handler.pressedMouseButtonsProvider = { 0 }
            let release = strip.portrait
                ? CGPoint(x: press.x, y: press.y + observed.height - start.height) : observed.center
            fixture.handler.receiveTapMouseUp(at: release)

            XCTAssertEqual(
                try fixture.frame(token)[keyPath: alongTheStrip],
                observed[keyPath: alongTheStrip],
                accuracy: FrameTolerance.frameWrite,
                "\(strip)"
            )
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token), "\(strip)")
        }
    }

    func testADwindleEdgeDragPressedInTheGapBesideTheTileIsKept() throws {
        let fixture = try makeFixture(.dwindle, pid: 835_304)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (resized, neighbor) = (fixture.tokens[0], fixture.tokens[1])
        let start = try fixture.frame(resized)
        let gap = try fixture.frame(neighbor).minX - start.maxX
        XCTAssertGreaterThan(gap, 0)
        let press = CGPoint(x: start.maxX + min(2, gap / 2), y: start.midY)
        let observed = grown(start, right: 100)
        let reported = ReportedFrame(start)
        fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }

        XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: press, modifiers: []))
        XCTAssertNil(fixture.handler.state.nativeResizeStart)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDragFallbackToken)
        let drag = CGPoint(x: press.x + 100, y: press.y)
        fixture.handler.receiveAnnotatedNativeMouseDragged(at: drag, windowIdUnderPointer: resized.windowId)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame, start)

        reported.frame = observed
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(resized.windowId))
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.receiveTapMouseUp(at: drag)

        XCTAssertEqual(try fixture.frame(resized).width, observed.width, accuracy: FrameTolerance.frameWrite)
    }

    func testADwindleEdgeDragOnATileThatAlreadyChangedSizeIsPutBack() throws {
        let fixture = try makeFixture(.dwindle, pid: 835_307)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        let reported = ReportedFrame(grown(start, right: 100))
        fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        XCTAssertFalse(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
        let press = CGPoint(x: start.maxX - FrameTolerance.frameWrite, y: start.midY)

        XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: press, modifiers: []))
        XCTAssertNil(fixture.handler.state.nativeResizeStart)
        let drag = CGPoint(x: press.x + 40, y: press.y)
        fixture.handler.receiveAnnotatedNativeMouseDragged(at: drag, windowIdUnderPointer: token.windowId)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)

        reported.frame = grown(start, right: 140)
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
        fixture.handler.pressedMouseButtonsProvider = { 0 }
        fixture.handler.receiveTapMouseUp(at: drag)

        XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
    }

    func testADwindleEdgePressDuringAnInFlightSizeWriteIsPutBackAfterTheWriteLands() async throws {
        try await assertDwindleResizeRejectedAfterSizeWrite(pid: 835_308)
    }

    func testADwindleEdgePressDuringASizeWriteCannotUseALaterPendingPositionWrite() async throws {
        try await assertDwindleResizeRejectedAfterSizeWrite(pid: 835_309, leavesPositionWritePending: true)
    }

    func testAQueuedDwindlePressOutsideThePlannedTileStillRejectsAnInFlightSizeWrite() async throws {
        try await assertDwindleResizeRejectedAfterSizeWrite(pid: 835_310, queuedOutsidePlannedTile: true)
    }

    private func assertDwindleResizeRejectedAfterSizeWrite(
        pid: pid_t, leavesPositionWritePending: Bool = false, queuedOutsidePlannedTile: Bool = false
    ) async throws {
        let fixture = try makeFixture(.dwindle, pid: pid)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        let pressedFrame = queuedOutsidePlannedTile ? grown(start, right: 4) : start
        let target = queuedOutsidePlannedTile
            ? start : CGRect(x: start.minX, y: start.minY + 30, width: start.width, height: start.height - 30)
        let axManager = fixture.controller.axManager
        let reference = try XCTUnwrap(fixture.entry(token).axRef)
        axManager.confirmFrameWrite(for: token.windowId, frame: pressedFrame)
        let createdContext = try await AppAXContextRegistry.getOrCreate(.current, pid: token.pid)
        let context = try XCTUnwrap(createdContext)
        defer { context.destroy() }
        let request = try XCTUnwrap(axManager.stageFrameWrite(for: AXFrameApplicationTarget(
            pid: token.pid, window: reference, frame: target
        )))
        let drain = try XCTUnwrap(context.frameDelivery.enqueueFrames(
            [request], callbackGeneration: context.callbackGeneration, completion: { _ in }
        ).drain)
        XCTAssertTrue(fixture.controller.axManager.hasInFlightFrameWrite(for: token))
        let reported = ReportedFrame(pressedFrame)
        fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        let press = CGPoint(x: pressedFrame.maxX - 1, y: target.midY)

        if queuedOutsidePlannedTile {
            XCTAssertFalse(fixture.handler.receiveTapMouseDown(
                at: press, modifiers: [], queuedLeftPress: .init(
                    location: press, modifiers: [], timestamp: 1,
                    windowServerFrames: [token: ScreenCoordinateSpace.toWindowServer(rect: pressedFrame)]
                )
            ))
            XCTAssertNil(fixture.handler.state.nativeTitleBarDragFallbackToken)
        } else {
            XCTAssertFalse(fixture.handler.dispatchMouseDown(
                at: press, modifiers: [], windowIdUnderPointer: token.windowId
            ))
        }
        XCTAssertNil(fixture.handler.state.nativeResizeStart)
        let result = WindowAdmissionTestSupport.successfulFrameResult(request: request)
        let outcome = context.frameDelivery.finishFrames(batchId: UUID(), drainId: drain.id, results: [result])
        for delivery in outcome.deliveries { delivery.deliver() }
        axManager.handleFrameApplyResults([result])
        let baseline = leavesPositionWritePending ? target.offsetBy(dx: 0, dy: 20) : target
        if leavesPositionWritePending {
            _ = try XCTUnwrap(axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                pid: token.pid, window: reference, frame: baseline, components: .position
            )))
        }
        reported.frame = baseline
        XCTAssertFalse(axManager.hasInFlightFrameWrite(for: token))
        XCTAssertEqual(axManager.isAwaitingFrameWrite(token.windowId), leavesPositionWritePending)
        let drag = CGPoint(x: press.x + 40, y: press.y)
        if queuedOutsidePlannedTile {
            fixture.handler.dispatchAnnotatedLeftMouseDragged(at: drag, windowIdUnderPointer: token.windowId)
        } else {
            fixture.handler.dispatchMouseDragged(at: drag)
        }

        reported.frame = grown(baseline, right: 100)
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
        fixture.handler.dispatchMouseUp(at: drag)

        XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
    }

    func testADwindleResizeSurvivesAQueuedSizeWriteSupersededDuringAPositionWrite() async throws {
        let fixture = try makeFixture(.dwindle, pid: 835_313)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        let reference = try XCTUnwrap(fixture.entry(token).axRef)
        let createdContext = try await AppAXContextRegistry.getOrCreate(.current, pid: token.pid)
        let context = try XCTUnwrap(createdContext)
        defer { context.destroy() }
        let axManager = fixture.controller.axManager
        func enqueue(_ frame: CGRect, components: AXFrameComponents) throws -> (
            request: AXFrameApplicationRequest, outcome: AppAXFrameMailbox.Outcome
        ) {
            let request = try XCTUnwrap(axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                pid: token.pid, window: reference, frame: frame, components: components
            )))
            let outcome = context.frameDelivery.enqueueFrames(
                [request], callbackGeneration: context.callbackGeneration,
                completion: { axManager.handleFrameApplyResults($0) }
            )
            for delivery in outcome.deliveries { delivery.deliver() }
            return (request, outcome)
        }
        let active = try enqueue(start.offsetBy(dx: 0, dy: 10), components: .position)
        let drain = try XCTUnwrap(active.outcome.drain)
        let queued = try enqueue(grown(start, right: -30), components: .all)
        XCTAssertNil(queued.outcome.drain)
        let reported = ReportedFrame(start)
        fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
        let press = CGPoint(x: start.maxX - 1, y: start.midY)
        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: press, modifiers: [], windowIdUnderPointer: token.windowId
        ))

        let baseline = start.offsetBy(dx: 0, dy: 20)
        let replacement = try enqueue(baseline, components: .position)
        let first = context.frameDelivery.finishFrames(
            batchId: UUID(), drainId: drain.id,
            results: [WindowAdmissionTestSupport.successfulFrameResult(request: active.request)]
        )
        for delivery in first.deliveries { delivery.deliver() }
        let next = try XCTUnwrap(first.drain)
        XCTAssertEqual(next.items.map { $0.request.requestId }, [replacement.request.requestId])
        let last = context.frameDelivery.finishFrames(
            batchId: UUID(), drainId: next.id,
            results: [WindowAdmissionTestSupport.successfulFrameResult(request: replacement.request)]
        )
        for delivery in last.deliveries { delivery.deliver() }
        reported.frame = baseline

        let drag = CGPoint(x: press.x + 100, y: press.y)
        fixture.handler.dispatchMouseDragged(at: drag)
        reported.frame = grown(baseline, right: 100)
        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
        fixture.handler.dispatchMouseUp(at: drag)

        XCTAssertEqual(try fixture.frame(token).width, start.width + 100, accuracy: FrameTolerance.frameWrite)
    }

    func testADwindleEdgeDragDuringAPendingPositionWriteStartsFromThePendingFrame() throws {
        let fixture = try makeFixture(.dwindle, pid: 835_305)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        let reference = try XCTUnwrap(fixture.entry(token).axRef)
        let pending = start.offsetBy(dx: 0, dy: -20)
        fixture.controller.axManager.applyFramesParallel([
            AXFrameApplicationTarget(pid: token.pid, window: reference, frame: pending)
        ])
        XCTAssertTrue(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
        let grownFrame = grown(pending, right: 100)
        fixture.handler.nativeWindowFrameProvider = { _ in grownFrame }

        try fixture.beginDrag(token, at: CGPoint(x: pending.maxX - FrameTolerance.frameWrite, y: pending.midY))
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
        XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.pendingWriteStartFrame, pending)
        fixture.handler.dispatchMouseUp(at: grownFrame.center)

        XCTAssertEqual(try fixture.frame(token).width, grownFrame.width, accuracy: FrameTolerance.frameWrite)
    }

    func testADwindleEdgeDragDuringAPendingSizeWriteIsPutBack() throws {
        let fixture = try makeFixture(.dwindle, pid: 835_306)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let start = try fixture.frame(token)
        let reference = try XCTUnwrap(fixture.entry(token).axRef)
        let pending = grown(start, right: -30)
        fixture.controller.axManager.applyFramesParallel([
            AXFrameApplicationTarget(pid: token.pid, window: reference, frame: pending)
        ])
        XCTAssertTrue(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
        let grownFrame = grown(pending, right: 100)
        fixture.handler.nativeWindowFrameProvider = { _ in grownFrame }

        try fixture.beginDrag(token, at: CGPoint(x: pending.maxX - FrameTolerance.frameWrite, y: pending.midY))
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.pendingWriteStartFrame)
        fixture.handler.dispatchMouseUp(at: grownFrame.center)

        XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite)
    }

    func testOnALandscapeStripAClickNeverKeepsASizeChangeItDidNotDrag() throws {
        enum Click: CaseIterable {
            case heldInPlace
            case releasedInPlace
            case releasedAfterJitter
        }
        for (index, click) in Click.allCases.enumerated() {
            let fixture = try makeFixture(.niri, pid: pid_t(835_311 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            let changed = start.insetBy(dx: -70, dy: 0)
            let reported = ReportedFrame(start)
            fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
            var release = start.center
            switch click {
            case .heldInPlace:
                reported.frame = changed
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
            case .releasedInPlace:
                break
            case .releasedAfterJitter:
                release = CGPoint(x: start.midX + FrameTolerance.frameWrite, y: start.midY)
                fixture.handler.dispatchQueuedMouseDragged(at: release, button: .left)
            }
            fixture.handler.pressedMouseButtonsProvider = { 0 }
            fixture.handler.receiveTapMouseUp(at: release)
            XCTAssertFalse(fixture.handler.state.leftPressWasDragged, "\(click)")

            reported.frame = changed
            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))

            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: FrameTolerance.frameWrite, "\(click)")
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token), "\(click)")
        }
    }

    func testSizeChangingPendingFrameJobsDoNotRebaseTheNativeResize() throws {
        var scenario = 0
        let pendingHeightReduction: CGFloat = 100
        for edgePress in [false, true] {
            for retry in [false, true] {
                for annotated in [false, true] {
                    for queuedBeforeMouseDown in [false, true] {
                        let fixture = try makeFixture(.niri, portrait: true, pid: pid_t(834_201 + scenario))
                        scenario += 1
                        let blocker = blockRefreshes(fixture)
                        defer { unblockRefreshes(fixture, blocker: blocker) }
                        let token = fixture.tokens[0]
                        let start = try fixture.frame(token)
                        let reported = ReportedFrame(start)
                        fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                        if !edgePress, !queuedBeforeMouseDown {
                            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                        }
                        let engine = try XCTUnwrap(fixture.controller.niriEngine)
                        let column = try XCTUnwrap(engine.findColumn(
                            containing: fixture.niriNode(token), in: fixture.workspaceId
                        ))
                        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
                            engine.setContainerPrimarySpan(
                                column,
                                change: .setFixed(start.height - pendingHeightReduction),
                                context: .init(
                                    workspaceId: fixture.workspaceId,
                                    motion: .disabled,
                                    workingFrame: fixture.controller.insetWorkingFrame(for: fixture.monitor),
                                    gaps: fixture.controller.innerGap(for: fixture.monitor),
                                    orientation: .vertical
                                ),
                                state: &state
                            )
                        }
                        let target = try fixture.frame(token)
                        XCTAssertEqual(
                            target.height,
                            start.height - pendingHeightReduction,
                            accuracy: FrameTolerance.frameWrite
                        )
                        let press = edgePress
                            ? CGPoint(x: target.midX, y: target.maxY - FrameTolerance.frameWrite)
                            : start.center
                        if edgePress {
                            XCTAssertEqual(
                                NiriLayoutEngine.fusionDoubleClickZone(
                                    at: press,
                                    in: target,
                                    gap: fixture.controller.innerGap(for: fixture.monitor),
                                    bounds: fixture.monitor.visibleFrame
                                ),
                                .edge(.top)
                            )
                            if !queuedBeforeMouseDown {
                                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: press, modifiers: []))
                            }
                        }
                        if retry {
                            fixture.controller.axManager.scheduleFrameRetry(AXFrameRetryRequest(
                                requestId: 1, pid: token.pid, windowId: token.windowId,
                                expectedWindow: try XCTUnwrap(fixture.entry(token).axRef),
                                frame: target, currentFrameHint: start
                            ))
                        } else {
                            XCTAssertNotNil(try fixture.controller.axManager
                                .stageFrameWrite(for: AXFrameApplicationTarget(
                                    pid: token.pid,
                                    window: XCTUnwrap(fixture.entry(token).axRef),
                                    frame: target
                                )))
                        }
                        if queuedBeforeMouseDown {
                            XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: press, modifiers: []))
                        }
                        let dragLocation = edgePress
                            ? CGPoint(x: press.x, y: (press.y + FrameTolerance.frameWrite).nextUp)
                            : nativeDragLocation(from: start)
                        if annotated {
                            fixture.handler.receiveAnnotatedNativeMouseDragged(
                                at: dragLocation,
                                windowIdUnderPointer: token.windowId
                            )
                        } else {
                            fixture.handler.dispatchMouseDragged(at: dragLocation)
                        }

                        let observed = grown(start, top: 60)
                        reported.frame = observed
                        fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
                        let release = edgePress
                            ? CGPoint(x: press.x, y: press.y + observed.maxY - start.maxY)
                            : observed.center
                        fixture.handler.receiveTapMouseUp(at: release)

                        XCTAssertEqual(
                            try fixture.frame(token).height, target.height, accuracy: FrameTolerance.frameWrite,
                            "edgePress=\(edgePress), retry=\(retry), annotated=\(annotated), queuedBeforeMouseDown=\(queuedBeforeMouseDown)"
                        )
                        XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                    }
                }
            }
        }
    }

    func testCompletedSizeWriteBetweenMouseDownAndDragDoesNotRebaseTheNativeResize() throws {
        let layouts: [(layout: LayoutType, portrait: Bool)] = [(.niri, false), (.dwindle, false), (.niri, true)]
        for (index, setup) in layouts.enumerated() {
            for annotated in [false, true] {
                let fixture = try makeFixture(
                    setup.layout, portrait: setup.portrait, pid: pid_t(834_231 + index * 2 + (annotated ? 1 : 0))
                )
                let blocker = blockRefreshes(fixture)
                defer { unblockRefreshes(fixture, blocker: blocker) }
                let token = fixture.tokens[0]
                let start = try fixture.frame(token)
                let reported = ReportedFrame(start)
                fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))

                switch setup.layout {
                case .niri,
                     .defaultLayout:
                    let engine = try XCTUnwrap(fixture.controller.niriEngine)
                    let column = try XCTUnwrap(engine.findColumn(
                        containing: fixture.niriNode(token), in: fixture.workspaceId
                    ))
                    fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
                        engine.setContainerPrimarySpan(
                            column,
                            change: .setFixed((setup.portrait ? start.height : start.width) - 100),
                            context: .init(
                                workspaceId: fixture.workspaceId,
                                motion: .disabled,
                                workingFrame: fixture.controller.insetWorkingFrame(for: fixture.monitor),
                                gaps: fixture.controller.innerGap(for: fixture.monitor),
                                orientation: setup.portrait ? .vertical : .horizontal
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
                let primary: KeyPath<CGRect, CGFloat> = setup.portrait ? \.height : \.width
                XCTAssertGreaterThan(abs(target[keyPath: primary] - start[keyPath: primary]), FrameTolerance.frameWrite)
                try fixture.confirmWrite(of: token)
                reported.frame = target
                XCTAssertFalse(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
                let dragLocation = setup.portrait
                    ? CGPoint(x: start.midX, y: (start.midY + FrameTolerance.frameWrite).nextUp)
                    : nativeDragLocation(from: start)
                if annotated {
                    fixture.handler.receiveAnnotatedNativeMouseDragged(
                        at: dragLocation,
                        windowIdUnderPointer: token.windowId
                    )
                } else {
                    fixture.handler.dispatchQueuedMouseDragged(
                        at: dragLocation,
                        button: .left
                    )
                }

                let observed = setup.portrait ? grown(target, top: 60) : grown(target, right: 60)
                reported.frame = observed
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                fixture.handler.receiveTapMouseUp(at: observed.center)

                XCTAssertEqual(
                    try fixture.frame(token)[keyPath: primary],
                    target[keyPath: primary],
                    accuracy: FrameTolerance.frameWrite,
                    "\(setup), annotated=\(annotated)"
                )
                XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            }
        }
    }

    func testAnnotatedDragWithoutAMouseDownBaselineDoesNotAdoptTheResize() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, portrait: layout == .niri, pid: pid_t(834_241 + index))
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
                let fixture = try makeFixture(
                    layout,
                    portrait: layout == .niri,
                    pid: pid_t(834_271 + index * 5 + boundaryIndex)
                )
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
            let fixture = try makeFixture(layout, portrait: layout == .niri, pid: pid_t(834_051 + index))
            fixture.wireFrameApplyCallbacks()
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let (resized, neighbor) = (fixture.tokens[0], fixture.tokens[1])
            let start = try fixture.frame(resized)
            let span: KeyPath<CGRect, CGFloat> = layout == .niri ? \.height : \.width
            func grownAlongTheStrip(_ frame: CGRect, by delta: CGFloat) -> CGRect {
                layout == .niri ? grown(frame, top: delta) : grown(frame, right: delta)
            }

            try fixture.release(resized, at: grownAlongTheStrip(start, by: 200))
            XCTAssertEqual(
                try fixture.frame(resized)[keyPath: span],
                start[keyPath: span] + 200,
                accuracy: FrameTolerance.frameWrite,
                "\(layout)"
            )
            try fixture.confirmWrite(of: resized)
            XCTAssertEqual(fixture.phase, .awaitingFrameChange, "\(layout)")
            fixture.controller.layoutRefreshController.stopScrollAnimation(for: fixture.monitor.displayId)

            let widened = try fixture.frame(resized)
            try fixture.release(resized, at: grownAlongTheStrip(widened, by: -300))
            XCTAssertEqual(
                try fixture.frame(resized)[keyPath: span],
                widened[keyPath: span] - 300,
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

    func testUndoGivesALoneFilledWindowItsFillFrameBack() throws {
        let fixture = try makeFixture(.niri, windowCount: 1, pid: 834_082)
        fixture.controller.motionPolicy.animationsEnabled = false
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let before = try fixture.frames()
        try fixture.release(token, at: grown(try fixture.frame(token), right: -300))
        XCTAssertNotEqual(try fixture.frames(), before)

        XCTAssertTrue(undo(fixture))

        XCTAssertFalse(try fixture.column(token).hasManualSingleWindowWidthOverride)
        XCTAssertEqual(try fixture.frames(), before)
        XCTAssertFalse(undo(fixture))
    }

    func testUndoAndRedoAreRegisteredAndKeepTheirBindings() throws {
        let fixture = try makeFixture(.niri, pid: 834_090)
        let controller = fixture.controller
        let registered = { (id: String) in controller.hotkeys.configuration.bindings.contains { $0.id == id } }
        for id in ["undo", "redo"] {
            XCTAssertNotNil(controller.settings.hotkeyBindings.first { $0.id == id }, id)
        }

        let undo = try XCTUnwrap(controller.settings.hotkeyBindings.first { $0.id == "undo" })

        controller.updateHotkeyBindings(controller.settings.hotkeyBindings)
        XCTAssertTrue(controller.settings.isCommandFeatureEnabled(.sizing(.undo)))
        XCTAssertTrue(controller.settings.isCommandFeatureEnabled(.sizing(.redo)))
        XCTAssertEqual(
            controller.settings.findConflicts(for: undo.binding, excluding: "other").map(\.id),
            ["undo"]
        )
        XCTAssertTrue(registered("undo"))
        XCTAssertTrue(registered("redo"))
    }

    func testCapturedChordsKeepTheirModifierSideAndSidesCanBeSet() throws {
        let fixture = try makeFixture(.niri, pid: 834_091)
        let settings = fixture.controller.settings
        let chord = KeyBinding(keyCode: 6, modifiers: UInt32(optionKey | cmdKey))
        settings.updateTrigger(for: "undo", newTrigger: .chord(chord.settingSide(.right)))

        let replacement = KeyBinding(keyCode: 7, modifiers: UInt32(optionKey | cmdKey))
        let kept = HotkeyBindingEditor.triggerKeepingSide(.chord(replacement), for: "undo", settings: settings)
        XCTAssertEqual(kept.chordBinding, replacement.settingSide(.right))
        XCTAssertEqual(
            HotkeyBindingEditor.trigger(for: "undo", side: .left, settings: settings)?.chordBinding,
            chord.settingSide(.left)
        )
    }

    func testUndoTakesBackTheLastResizeThenTheOneBeforeAndRedoPutsThemBack() throws {
        let fixture = try makeFixture(.niri, pid: 834_084)
        fixture.controller.motionPolicy.animationsEnabled = false
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (first, second) = (fixture.tokens[0], fixture.tokens[1])
        let firstSpec = try fixture.column(first).width
        let secondSpec = try fixture.column(second).width
        try fixture.release(first, at: grown(try fixture.frame(first), right: 200))
        try fixture.confirmLayout()
        let firstResized = try fixture.column(first).width
        try fixture.release(second, at: grown(try fixture.frame(second), right: -100))
        let secondResized = try fixture.column(second).width

        XCTAssertTrue(undo(fixture))
        XCTAssertEqual(try fixture.column(second).width, secondSpec)
        XCTAssertEqual(try fixture.column(first).width, firstResized)
        XCTAssertTrue(undo(fixture))
        XCTAssertEqual(try fixture.column(first).width, firstSpec)

        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.redo))
        XCTAssertEqual(try fixture.column(first).width, firstResized)
        XCTAssertTrue(fixture.controller.niriLayoutHandler.stepLayoutHistory(.redo))
        XCTAssertEqual(try fixture.column(second).width, secondResized)
        XCTAssertFalse(fixture.controller.niriLayoutHandler.stepLayoutHistory(.redo))
    }

    func testUndoGivesAStackBothHeightsBack() throws {
        let fixture = try makeFixture(.niri, stacked: true, pid: 834_085)
        fixture.controller.motionPolicy.animationsEnabled = false
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (top, bottom) = try stackedTopAndBottom(fixture)
        let before = try fixture.frames()
        try fixture.release(top, at: grown(try fixture.frame(top), bottom: 100))
        XCTAssertNotEqual(try fixture.frame(bottom).height, before[bottom]?.height)

        XCTAssertTrue(undo(fixture))

        XCTAssertEqual(try fixture.frames(), before)
    }

    func testUndoTakesBackAKeyboardSizeChangeBeforeTheResizeBeforeIt() throws {
        let fixture = try makeFixture(.niri, pid: 834_086)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let token = fixture.tokens[0]
        let spec = try fixture.column(token).width
        try fixture.release(token, at: grown(try fixture.frame(token), right: 200))
        let resized = try fixture.column(token).width
        let node = try fixture.niriNode(token)
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { $0.selectedNodeId = node.id }
        _ = fixture.controller.commandHandler.performCommand(.sizing(.toggleContainerFullPrimarySpan))
        XCTAssertTrue(try fixture.column(token).isFullWidth)

        XCTAssertTrue(undo(fixture))
        XCTAssertFalse(try fixture.column(token).isFullWidth)
        XCTAssertEqual(try fixture.column(token).width, resized)
        XCTAssertTrue(undo(fixture))
        XCTAssertEqual(try fixture.column(token).width, spec)
    }

    func testUndoAnimatesTheWidthBackAndTheNeighbourRidesAlong() throws {
        let fixture = try makeFixture(.niri, pid: 834_087)
        fixture.controller.motionPolicy.animationsEnabled = true
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (first, second) = (fixture.tokens[0], fixture.tokens[1])
        try fixture.release(first, at: grown(try fixture.frame(first), right: 200))
        try fixture.confirmLayout()
        for token in [first, second] {
            let node = try fixture.niriNode(token)
            node.stopMoveAnimations()
            node.renderedFrame = node.frame
        }

        XCTAssertTrue(undo(fixture))

        XCTAssertNotNil(try fixture.column(first).widthAnimation)
        XCTAssertFalse(try fixture.niriNode(second).hasMoveAnimationsRunning)
    }

    func testUndoBringsTheWindowItRestoresToTheFront() throws {
        let fixture = try makeFixture(.niri, pid: 834_088)
        fixture.controller.motionPolicy.animationsEnabled = false
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (first, second) = (fixture.tokens[0], fixture.tokens[1])
        let firstNode = try fixture.niriNode(first)
        let secondNode = try fixture.niriNode(second)
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { $0.selectedNodeId = firstNode.id }
        try fixture.release(first, at: grown(try fixture.frame(first), right: 200))
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { $0.selectedNodeId = secondNode.id }

        XCTAssertTrue(undo(fixture))

        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, first)
    }

    private func undo(_ fixture: Fixture) -> Bool {
        fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo)
    }

    func testAKeptResizeSendsTheWindowNoFrameItAlreadyHas() async throws {
        let fixture = try makeFixture(.niri, pid: 834_078)
        let token = fixture.tokens[0]
        let observed = grown(try fixture.frame(token), right: 200)
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }

        try fixture.release(token, at: observed)
        fixture.controller.niriLayoutHandler.tickScrollAnimation(
            targetTime: fixture.controller.animationClock.now(),
            displayId: fixture.monitor.displayId
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        if let target = firstWriteTarget(for: token) {
            XCTAssertFalse(target.approximatelyEqual(to: observed, tolerance: FrameTolerance.frameWrite))
        }
        XCTAssertEqual(try fixture.frame(token).width, observed.width, accuracy: FrameTolerance.frameWrite)
    }

    func testAPressLeavesTheStripsSlideRunningAndTheFirstDragMovementEndsIt() throws {
        let fixture = try makeFixture(.niri, pid: 834_079)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let token = fixture.tokens[1]
        fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.animateToOffset(state.viewOffset + 300, motion: .enabled, scale: 2)
        }
        fixture.controller.niriLayoutHandler.startScrollAnimationIfNeeded(
            for: fixture.workspaceId,
            state: fixture.manager.niriViewportState(for: fixture.workspaceId),
            engine: engine
        )
        XCTAssertTrue(hasPendingNiriAnimationWork(
            state: fixture.manager.niriViewportState(for: fixture.workspaceId),
            driver: fixture.manager.animationDriver,
            engine: engine,
            workspaceId: fixture.workspaceId
        ))
        let start = try fixture.frame(token)
        fixture.handler.retireNativeTitleBarDragAtInputBoundary()
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }

        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: start.center,
            modifiers: [],
            windowIdUnderPointer: token.windowId
        ))

        XCTAssertTrue(fixture.manager.animationDriver.hasMotion(in: fixture.workspaceId))

        fixture.handler.dispatchMouseDragged(at: nativeDragLocation(from: start))

        XCTAssertEqual(fixture.phase, .dragging)
        XCTAssertFalse(fixture.manager.animationDriver.hasMotion(in: fixture.workspaceId))
    }

    func testAnEdgeResizePressedDuringASlideIsKeptWithTheFramesCapturedAtThePress() async throws {
        for (index, slides) in [false, true].enumerated() {
            let fixture = try makeFixture(.niri, pid: pid_t(835_262 + index))
            let engine = try XCTUnwrap(fixture.controller.niriEngine)
            let token = fixture.tokens[0]
            let pressedFrame = try fixture.frame(token)
            if slides {
                fixture.manager.withNiriViewportState(for: fixture.workspaceId) { state in
                    state.animateToOffset(state.viewOffset + 120, motion: .enabled, scale: 2)
                }
                fixture.controller.niriLayoutHandler.startScrollAnimationIfNeeded(
                    for: fixture.workspaceId,
                    state: fixture.manager.niriViewportState(for: fixture.workspaceId),
                    engine: engine
                )
            }
            let press = CGPoint(x: pressedFrame.maxX - FrameTolerance.frameWrite, y: pressedFrame.midY)
            fixture.handler.retireNativeTitleBarDragAtInputBoundary()
            fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            _ = fixture.handler.dispatchMouseDown(
                at: press,
                modifiers: [],
                windowIdUnderPointer: token.windowId,
                windowServerFramesAtMouseDown: [token: ScreenCoordinateSpace.toWindowServer(rect: pressedFrame)]
            )
            XCTAssertEqual(
                fixture.manager.animationDriver.hasMotion(in: fixture.workspaceId),
                slides,
                "slides: \(slides)"
            )

            let settled = try fixture.frame(token)
            let observed = grown(settled, right: 140)
            let reported = ReportedFrame(fixture.controller.axManager.lastAppliedFrame(for: token.windowId))
            fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
            fixture.handler.dispatchMouseDragged(at: nativeDragLocation(from: settled))
            XCTAssertFalse(fixture.manager.animationDriver.hasMotion(in: fixture.workspaceId), "slides: \(slides)")
            fixture.controller.niriLayoutHandler.tickScrollAnimation(
                targetTime: fixture.controller.animationClock.now(),
                displayId: fixture.monitor.displayId
            )
            reported.frame = observed
            XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: try fixture.entry(token)))
            fixture.handler.dispatchMouseUp(at: observed.center)
            fixture.controller.niriLayoutHandler.tickScrollAnimation(
                targetTime: fixture.controller.animationClock.now(),
                displayId: fixture.monitor.displayId
            )
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

            XCTAssertEqual(
                try fixture.frame(token).width,
                observed.width,
                accuracy: FrameTolerance.frameWrite,
                "slides: \(slides)"
            )
        }
    }

    func testAdoptedFrameIsTheFirstWriteForTheResizedWindow() async throws {
        let cases: [(LayoutType, Int, (CGRect) -> CGRect)] = [
            (.niri, 0, { self.grown($0, top: 200) }),
            (.niri, 1, { self.grown($0, bottom: 150) }),
            (.dwindle, 0, { self.grown($0, right: 150) })
        ]
        for (index, (layout, tokenIndex, change)) in cases.enumerated() {
            let fixture = try makeFixture(layout, portrait: layout == .niri, pid: pid_t(834_071 + index))
            let span: KeyPath<CGRect, CGFloat> = layout == .niri ? \.height : \.width
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
            XCTAssertEqual(
                target[keyPath: span],
                observed[keyPath: span],
                accuracy: FrameTolerance.frameWrite,
                "\(layout) \(tokenIndex)"
            )
            if tokenIndex == 1 {
                XCTAssertEqual(
                    target.maxY,
                    observed.maxY,
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

    private struct EdgeDrag {
        let token: WindowToken
        let start: CGRect
        let reported: ReportedFrame
    }

    private func beginEdgeDrag(
        _ fixture: Fixture,
        of token: WindowToken,
        at press: CGPoint? = nil,
        draggedTo: CGPoint? = nil
    ) throws -> EdgeDrag {
        let start = try fixture.frame(token)
        let reported = ReportedFrame(fixture.controller.axManager.lastAppliedFrame(for: token.windowId))
        fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
        try fixture.beginDrag(token, at: press, draggedTo: draggedTo)
        return EdgeDrag(token: token, start: start, reported: reported)
    }

    private func report(_ frame: CGRect, for drag: EdgeDrag, in fixture: Fixture) throws -> Bool {
        drag.reported.frame = frame
        return fixture.handler.handleNativeTitleBarDragFrameChanged(for: try fixture.entry(drag.token))
    }

    private func letGo(_ fixture: Fixture, of drag: EdgeDrag, afterMovingRight travel: CGFloat) {
        fixture.handler.dispatchMouseUp(at: CGPoint(x: drag.start.center.x + travel, y: drag.start.center.y))
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

    private func centeredNativeHorizontalFrames(
        _ fixture: Fixture,
        rawWidths: [CGFloat]
    ) -> [WindowToken: CGRect] {
        let area = fixture.controller.insetWorkingFrame(for: fixture.monitor)
        let gap = fixture.controller.resolvedDwindleSettings(for: fixture.monitor).innerGap
        XCTAssertEqual(rawWidths.count, fixture.tokens.count)
        XCTAssertEqual(rawWidths.reduce(0, +), area.width)
        var result: [WindowToken: CGRect] = [:]
        var x = area.minX
        for (index, width) in rawWidths.enumerated() {
            let leftInset = index == rawWidths.startIndex ? 0 : gap / 2
            let rightInset = index == rawWidths.index(before: rawWidths.endIndex) ? 0 : gap / 2
            result[fixture.tokens[index]] = CGRect(
                x: x + leftInset, y: area.minY, width: width - leftInset - rightInset, height: area.height
            )
            x += width
        }
        return result
    }

    private func makeNestedCenteredNativeResizeFixture(pid: pid_t) throws -> Fixture {
        let original = try makeFixture(.dwindle, windowCount: 4, pid: pid)
        let controller = original.controller
        let translatedFrame = original.monitor.frame.offsetBy(
            dx: original.monitor.frame.width / 8, dy: original.monitor.frame.height / 8
        )
        let monitor = Monitor(
            id: original.monitor.id,
            displayId: original.monitor.displayId,
            frame: translatedFrame,
            visibleFrame: translatedFrame,
            hasNotch: false,
            name: original.monitor.name
        )
        original.manager.applyMonitorConfigurationChange([monitor])
        original.manager.applySettings()
        let fixture = Fixture(
            controller: controller, workspaceId: original.workspaceId, monitor: monitor,
            tokens: original.tokens, nativeFrames: original.nativeFrames
        )
        let engine = try XCTUnwrap(controller.dwindleEngine)
        let settings = controller.resolvedDwindleSettings(for: monitor)
        controller.dwindleLayoutHandler.applyResolvedSettings(settings, to: engine)
        fixture.manager.withEngineMutationScope(in: fixture.workspaceId) {
            engine.removeLayout(for: fixture.workspaceId)
            for token in [fixture.tokens[0], fixture.tokens[1], fixture.tokens[3]] {
                _ = engine.setPreselection(.right, in: fixture.workspaceId)
                _ = engine.addWindow(token: token, to: fixture.workspaceId, activeWindowFrame: nil)
            }
            engine.setSelectedNode(
                engine.findNode(for: fixture.tokens[1], in: fixture.workspaceId), in: fixture.workspaceId
            )
            _ = engine.setPreselection(.right, in: fixture.workspaceId)
            _ = engine.addWindow(token: fixture.tokens[2], to: fixture.workspaceId, activeWindowFrame: nil)
        }
        let inner = try XCTUnwrap(engine.findNode(for: fixture.tokens[1], in: fixture.workspaceId)?.parent)
        fixture.manager.withEngineMutationScope(in: fixture.workspaceId) {
            inner.kind = .split(orientation: .horizontal, ratio: 1 / 2)
        }
        let span = controller.insetWorkingFrame(for: monitor).width / 2
        let farMinimum = 9 * span / 16 - settings.innerGap / 2
        fixture.manager.setCachedConstraints(
            WindowSizeConstraints(minSize: CGSize(width: farMinimum, height: 1), maxSize: .zero, isFixed: false),
            for: fixture.tokens[3]
        )
        controller.dwindleLayoutHandler.refreshEngineConstraints(workspaceId: fixture.workspaceId, monitor: monitor)
        engine.cancelAnimations(in: fixture.workspaceId)
        try fixture.confirmLayout()
        let initial = centeredNativeHorizontalFrames(
            fixture, rawWidths: [span, 7 * span / 64, 21 * span / 64, 9 * span / 16]
        )
        XCTAssertEqual(try fixture.frames(), initial)
        let tokens = fixture.tokens
        controller.axEventHandler.windowInfoProvider = { windowId in
            guard let token = tokens.first(where: { $0.windowId == Int(windowId) }) else { return nil }
            return WindowServerInfo(id: windowId, pid: token.pid, level: 0, frame: initial[token] ?? .zero)
        }
        controller.layoutRefreshController.resetState()
        return fixture
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
