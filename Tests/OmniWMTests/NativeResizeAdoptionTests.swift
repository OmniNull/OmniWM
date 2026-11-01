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

@MainActor
final class NativeResizeAdoptionTests: NiriInteractionTestCase {
    @MainActor
    private struct Fixture {
        let controller: WMController
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let tokens: [WindowToken]

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
                controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
            }
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
            handler.dispatchMouseDragged(at: CGPoint(x: start.center.x + 5, y: start.center.y))
            XCTAssertEqual(phase, .dragging)
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
            let request = try XCTUnwrap(controller.axManager.stageFrameWrite(
                for: AXFrameApplicationTarget(pid: token.pid, window: entry(token).axRef, frame: target)
            ))
            controller.axManager
                .handleFrameApplyResults([WindowAdmissionTestSupport.successfulFrameResult(request: request)])
            XCTAssertEqual(controller.axManager.lastAppliedFrame(for: token.windowId), target)
        }

        func refuseWrite(of token: WindowToken, growingWidthBy growth: CGFloat) throws {
            let target = try frame(token)
            let window = try entry(token).axRef
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

        XCTAssertEqual(try fixture.frame(resized).width, start.width + 200, accuracy: 1)
        XCTAssertEqual(try fixture.frame(neighbor).width, neighborWidth, accuracy: 1)
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
        XCTAssertEqual(adopted.width, start.width + 150, accuracy: 1)
        XCTAssertEqual(adopted.maxX, start.maxX, accuracy: 1)
    }

    func testNiriStackedEdgeSetsTheExactHeight() throws {
        let fixture = try makeFixture(.niri, stacked: true, pid: 834_013)
        let blocker = blockRefreshes(fixture)
        defer { unblockRefreshes(fixture, blocker: blocker) }
        let (top, bottom) = try stackedTopAndBottom(fixture)
        let topStart = try fixture.frame(top)
        let bottomStart = try fixture.frame(bottom)

        try fixture.release(top, at: grown(topStart, bottom: 100))

        XCTAssertEqual(try fixture.frame(top).height, topStart.height + 100, accuracy: 1)
        XCTAssertEqual(try fixture.frame(bottom).height, bottomStart.height - 100, accuracy: 1)
        XCTAssertEqual(try fixture.frame(top).width, topStart.width, accuracy: 1)
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
                accuracy: 1
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

        XCTAssertEqual(try fixture.frame(left).width, leftStart.width + 150, accuracy: 1)
        XCTAssertEqual(try fixture.frame(right).width, rightStart.width - 150, accuracy: 1)
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

            XCTAssertEqual(try fixture.frame(left).width, leftStart.width + delta, accuracy: 1)
            XCTAssertEqual(try fixture.frame(right).width, rightStart.width - delta, accuracy: 1)
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

        XCTAssertEqual(try fixture.frame(left).width, leftStart.width - 40, accuracy: 1)
        XCTAssertEqual(fixture.phase, .awaitingCorrection)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: left))
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

            XCTAssertTrue(try fixture.frame(token).approximatelyEqual(to: observed, tolerance: 1))
            XCTAssertEqual(fixture.phase, .dragging)
            fixture.handler.dispatchMouseUp(at: observed.center)
            XCTAssertTrue(try fixture.frame(token).approximatelyEqual(to: observed, tolerance: 1))
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

        XCTAssertEqual(try fixture.frame(token).width, start.width + 180, accuracy: 1)
        XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
        let worldSeq = fixture.manager.worldSeq
        fixture.updateDrag(token, at: grown(start, right: 200))
        XCTAssertEqual(try fixture.frame(token).width, start.width + 180, accuracy: 1)
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
        XCTAssertEqual(try fixture.frame(token).width, start.width + 100, accuracy: 1)
        FrameEffectTraceContext.beginCapture(generation: 1)
        FrameApplyTrace.shared.beginCapture()
        defer {
            FrameApplyTrace.shared.endCapture()
            FrameEffectTraceContext.endCapture()
        }

        fixture.handler.dispatchMouseUp(at: finalFrame.center)

        XCTAssertEqual(fallbackReads, 1)
        XCTAssertTrue(try fixture.frame(token).approximatelyEqual(to: finalFrame, tolerance: 1))
        for window in fixture.tokens {
            XCTAssertEqual(frameDecisions(for: window).count, 1, FrameApplyTrace.shared.dump())
            let target = try fixture.frame(window)
            XCTAssertTrue(firstWriteTarget(for: window)?.approximatelyEqual(to: target, tolerance: 1) == true)
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

            XCTAssertEqual(try fixture.frame(token).width, start.width + (finalDelta ?? 100), accuracy: 1)
            for window in fixture.tokens {
                XCTAssertEqual(frameDecisions(for: window).count, 1, "case \(index): \(FrameApplyTrace.shared.dump())")
                let target = try fixture.frame(window)
                XCTAssertTrue(firstWriteTarget(for: window)?.approximatelyEqual(to: target, tolerance: 1) == true)
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

        XCTAssertEqual(try fixture.frame(token).width, start.width + 150, accuracy: 1)
        XCTAssertEqual(try fixture.frame(token).height, start.height + 80, accuracy: 1)
        XCTAssertEqual(try fixture.frame(fixture.tokens[2]).height, aboveStart.height - 80, accuracy: 1)
        fixture.handler.dispatchMouseUp(at: start.center)
        XCTAssertEqual(try fixture.frame(token).width, start.width + 150, accuracy: 1)
        XCTAssertEqual(try fixture.frame(token).height, start.height + 80, accuracy: 1)
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
        XCTAssertEqual(try fixture.frame(token).width, start.width + 100, accuracy: 1)
        fixture.handler.dispatchMouseUp(at: start.center)
        XCTAssertEqual(try fixture.frame(token).width, start.width + 100, accuracy: 1)
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
        for _ in 0 ..< 20 where !fixture.controller.axEventHandler.frameObservations.byWindowId.isEmpty {
            await Task.yield()
        }

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
        XCTAssertEqual(adopted.width, start.width + 150, accuracy: 1)
        XCTAssertEqual(adopted.height, start.height, accuracy: 1)
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
            XCTAssertEqual(try fixture.frame(token).width, start.width + 200, accuracy: 1)
            let worldSeq = fixture.manager.worldSeq

            fixture.handler.nativeWindowFrameProvider = { _ in self.grown(start, right: 260) }
            XCTAssertTrue(fixture.handler.handleNativeTitleBarDragFrameChanged(for: try fixture.entry(token)))
            XCTAssertEqual(try fixture.frame(token).width, start.width + 200, accuracy: 1)
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
        XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: 1)
    }

    func testPendingWriteAtDragStartDisablesAdoption() throws {
        for (index, layout) in [LayoutType.niri, .dwindle].enumerated() {
            let fixture = try makeFixture(layout, pid: pid_t(834_043 + index))
            let blocker = blockRefreshes(fixture)
            defer { unblockRefreshes(fixture, blocker: blocker) }
            let token = fixture.tokens[0]
            let start = try fixture.frame(token)
            fixture.controller.axManager.applyFramesParallel([
                AXFrameApplicationTarget(
                    pid: token.pid,
                    window: try fixture.entry(token).axRef,
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
            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: 1)
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
            fixture.handler.dispatchMouseDragged(at: CGPoint(x: start.midX + 5, y: start.midY))
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
                accuracy: 1,
                "\(layout)"
            )

            fixture.handler.dispatchMouseUp(at: observed.center)

            XCTAssertEqual(try fixture.frame(token).width, observed.width, accuracy: 1, "\(layout)")
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
            XCTAssertEqual(fixture.phase, .awaitingCorrection)
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
            fixture.handler.dispatchMouseDragged(at: CGPoint(x: start.midX + 5, y: start.midY))
            fixture.handler.dispatchMouseUp(at: start.center)
            XCTAssertTrue(fixture.handler.state.nativeTitleBarDragFallbackReleased)

            fixture.handler.nativeWindowFrameProvider = { _ in observed }
            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))

            XCTAssertEqual(try fixture.frame(token).width, observed.width, accuracy: 1, "\(layout)")
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
            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: 1, "\(layout), before drag")
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            fixture.handler.dispatchQueuedMouseDragged(at: CGPoint(x: start.midX + 5, y: start.midY), button: .left)
            XCTAssertEqual(
                try fixture.frame(token).width,
                layout == .dwindle ? observed.width : start.width,
                accuracy: 1,
                "\(layout), confirmed drag"
            )
            fixture.handler.dispatchMouseUp(at: observed.center)

            XCTAssertEqual(try fixture.frame(token).width, observed.width, accuracy: 1, "\(layout)")
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

            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: 1, "\(layout), held")
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
            XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)

            fixture.handler.receiveTapMouseUp(at: observed.center)

            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: 1, "\(layout), released")
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
                    XCTAssertEqual(target.width, start.width - 100, accuracy: 1)
                    if retry {
                        fixture.controller.axManager.scheduleFrameRetry(AXFrameRetryRequest(
                            requestId: 1, pid: token.pid, windowId: token.windowId,
                            expectedWindow: try fixture.entry(token).axRef,
                            frame: target, currentFrameHint: start
                        ))
                    } else {
                        XCTAssertNotNil(try fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                            pid: token.pid, window: fixture.entry(token).axRef, frame: target
                        )))
                    }
                    if queuedBeforeMouseDown {
                        XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))
                    }
                    if annotated {
                        fixture.handler.receiveAnnotatedNativeMouseDragged(windowIdUnderPointer: token.windowId)
                    } else {
                        fixture.handler.dispatchMouseDragged(at: CGPoint(x: start.midX + 5, y: start.midY))
                    }

                    let observed = grown(start, right: 60)
                    reported.frame = observed
                    fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                    XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
                    fixture.handler.receiveTapMouseUp(at: observed.center)

                    XCTAssertEqual(
                        try fixture.frame(token).width, target.width, accuracy: 1,
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
                    fixture.handler.receiveAnnotatedNativeMouseDragged(windowIdUnderPointer: token.windowId)
                } else {
                    fixture.handler.dispatchQueuedMouseDragged(
                        at: CGPoint(x: start.midX + 5, y: start.midY),
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
                    accuracy: 1,
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

            fixture.handler.receiveAnnotatedNativeMouseDragged(windowIdUnderPointer: token.windowId)
            let observed = grown(start, right: 100)
            reported.frame = observed
            fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
            fixture.handler.receiveTapMouseUp(at: observed.center)

            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: 1, "\(layout)")
            XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
            XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
        }
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
                        at: CGPoint(x: start.midX + 5, y: start.midY),
                        button: .left
                    )
                }

                reported.frame = observed
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))

                XCTAssertEqual(fixture.controller.axManager.lastAppliedFrame(for: token.windowId), start)
                XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: 1, "\(layout), before annotation")
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                if queuedDragOrder == 2 {
                    fixture.handler.dispatchQueuedMouseDragged(
                        at: CGPoint(x: start.midX + 5, y: start.midY),
                        button: .left
                    )
                }
                fixture.handler.receiveAnnotatedNativeMouseDragged(windowIdUnderPointer: token.windowId)

                XCTAssertEqual(fixture.phase, .dragging)
                XCTAssertEqual(
                    try fixture.frame(token).width,
                    layout == .dwindle ? observed.width : start.width,
                    accuracy: 1,
                    "\(layout), queuedDragOrder=\(queuedDragOrder), confirmed drag"
                )
                fixture.handler.receiveTapMouseUp(at: observed.center)

                XCTAssertEqual(
                    try fixture.frame(token).width,
                    observed.width,
                    accuracy: 1,
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
                    fixture.handler.receiveAnnotatedNativeMouseDragged(windowIdUnderPointer: token.windowId + 10_000)
                case .otherTiledTarget:
                    fixture.handler.receiveAnnotatedNativeMouseDragged(windowIdUnderPointer: other.windowId)
                    XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.token, other)
                    XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
                }

                let correction = try XCTUnwrap(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
                XCTAssertEqual(correction.reason, .interactiveGesture, "\(layout), \(boundary)")
                XCTAssertTrue(correction.affectedWorkspaceIds.contains(fixture.workspaceId))
                XCTAssertNotEqual(fixture.handler.state.nativeResizeStart?.token, token)
                XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: 1, "\(layout), \(boundary)")
                XCTAssertEqual(try fixture.frame(other).width, otherFrame.width, accuracy: 1, "\(layout), \(boundary)")
                XCTAssertFalse(fixture.controller.axManager.isNativeTitleBarDragActive(for: token))
                XCTAssertNil(fixture.controller.dwindleEngine?.interactiveResize)
                XCTAssertNotNil(try fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                    pid: token.pid, window: fixture.entry(token).axRef, frame: start
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
                        expectedWindow: try fixture.entry(token).axRef,
                        frame: target, currentFrameHint: start
                    ))
                } else {
                    XCTAssertNotNil(try fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                        pid: token.pid, window: fixture.entry(token).axRef, frame: target
                    )))
                }
                let reported = ReportedFrame(start)
                fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
                XCTAssertFalse(fixture.handler.receiveTapMouseDown(at: start.center, modifiers: []))

                fixture.handler.receiveAnnotatedNativeMouseDragged(windowIdUnderPointer: token.windowId)

                XCTAssertFalse(fixture.controller.axManager.isAwaitingFrameWrite(token.windowId))
                XCTAssertEqual(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame, start)
                let observed = grown(start, right: 160)
                reported.frame = observed
                fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                fixture.handler.receiveTapMouseUp(at: observed.center)

                XCTAssertEqual(try fixture.frame(token).width, observed.width, accuracy: 1, "\(layout), retry=\(retry)")
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

            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: 1, "\(layout)")
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
                        expectedWindow: try fixture.entry(token).axRef,
                        frame: target,
                        currentFrameHint: start
                    ))
                } else {
                    XCTAssertNotNil(try fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                        pid: token.pid, window: fixture.entry(token).axRef, frame: target
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

                XCTAssertEqual(try fixture.frame(token).width, observed.width, accuracy: 1, "\(layout), retry=\(retry)")
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
                            expectedWindow: try fixture.entry(token).axRef,
                            frame: target, currentFrameHint: start
                        ))
                    } else {
                        XCTAssertNotNil(try fixture.controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
                            pid: token.pid, window: fixture.entry(token).axRef, frame: target
                        )))
                    }
                    let reported = ReportedFrame(start)
                    fixture.handler.nativeWindowFrameProvider = { _ in reported.frame }
                    fixture.handler
                        .pressedMouseButtonsProvider = { released ? 0 : MouseEventHandler.MouseButton.left.pressedMask }
                    XCTAssertFalse(fixture.handler.dispatchMouseDown(at: start.center, modifiers: []))
                    fixture.handler.dispatchMouseDragged(at: CGPoint(x: start.midX + 5, y: start.midY))
                    if released {
                        fixture.handler.dispatchMouseUp(at: start.center)
                    }

                    let observed = grown(start, right: 160)
                    reported.frame = observed
                    fixture.controller.axEventHandler.handleFrameChanged(windowId: UInt32(token.windowId))
                    if !released { fixture.handler.dispatchMouseUp(at: observed.center) }

                    XCTAssertEqual(
                        try fixture.frame(token).width, observed.width, accuracy: 1,
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
            pid: token.pid, window: fixture.entry(token).axRef, frame: target
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

        XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: 1)
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
                pid: token.pid, window: fixture.entry(token).axRef, frame: target
            )))
            fixture.handler.nativeWindowFrameProvider = { _ in target }

            try fixture.beginDrag(token)

            XCTAssertNil(fixture.handler.state.nativeTitleBarDrag?.adoptionStartFrame)
            fixture.handler.dispatchMouseUp(at: target.center)
            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: 1)
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

            XCTAssertEqual(try fixture.frame(token).width, start.width, accuracy: 1)
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
            XCTAssertEqual(try fixture.frame(resized).width, start.width + 200, accuracy: 1, "\(layout)")
            try fixture.confirmWrite(of: resized)
            XCTAssertEqual(fixture.phase, .awaitingFrameChange, "\(layout)")
            fixture.controller.layoutRefreshController.stopScrollAnimation(for: fixture.monitor.displayId)

            let widened = try fixture.frame(resized)
            try fixture.release(resized, at: grown(widened, right: -300))
            XCTAssertEqual(try fixture.frame(resized).width, widened.width - 300, accuracy: 1, "\(layout)")
            try fixture.confirmWrite(of: resized)
            XCTAssertNil(fixture.manager.observedSizeEvidence(for: resized), "\(layout)")
            XCTAssertNil(fixture.manager.cachedConstraints(for: resized, maxAge: .greatestFiniteMagnitude), "\(layout)")

            try fixture.refuseWrite(of: neighbor, growingWidthBy: 40)
            let neighborEvidence = try XCTUnwrap(fixture.manager.observedSizeEvidence(for: neighbor), "\(layout)")
            XCTAssertEqual(neighborEvidence.minSize.width, try fixture.frame(neighbor).width, accuracy: 41, "\(layout)")
            XCTAssertGreaterThan(neighborEvidence.minSize.width, 1, "\(layout)")
            XCTAssertNil(fixture.manager.observedSizeEvidence(for: resized), "\(layout)")

            try fixture.refuseWrite(of: resized, growingWidthBy: 10)
            let hinted = try XCTUnwrap(fixture.manager.observedSizeEvidence(for: resized), "\(layout)")
            XCTAssertLessThanOrEqual(hinted.minSize.width, 1, "\(layout)")
            XCTAssertFalse(hinted.hints.isEmpty, "\(layout)")
        }
    }

    func testSecondaryEdgesAdoptWhereverTheyRender() throws {
        let columns = try makeFixture(.niri, pid: 834_061)
        let columnsBlocker = blockRefreshes(columns)
        defer { unblockRefreshes(columns, blocker: columnsBlocker) }
        let columnStart = try columns.frame(columns.tokens[0])
        try columns.release(columns.tokens[0], at: grown(columnStart, bottom: -120))
        XCTAssertEqual(try columns.frame(columns.tokens[0]).height, columnStart.height - 120, accuracy: 1)

        let portrait = try makeFixture(.niri, portrait: true, windowCount: 1, pid: 834_062)
        let portraitBlocker = blockRefreshes(portrait)
        defer { unblockRefreshes(portrait, blocker: portraitBlocker) }
        let portraitStart = try portrait.frame(portrait.tokens[0])
        try portrait.release(portrait.tokens[0], at: grown(portraitStart, right: -150))
        XCTAssertEqual(try portrait.frame(portrait.tokens[0]).width, portraitStart.width - 150, accuracy: 1)

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
            for _ in 0 ..< 8 where fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.workspaceId) {
                fixture.controller.niriLayoutHandler.tickScrollAnimation(
                    targetTime: CACurrentMediaTime() + 10,
                    displayId: fixture.monitor.displayId
                )
            }
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

            let target = try XCTUnwrap(firstWriteTarget(for: token), "\(layout) \(tokenIndex)")
            XCTAssertEqual(target.width, observed.width, accuracy: 1, "\(layout) \(tokenIndex)")
            if tokenIndex == 1 {
                XCTAssertEqual(target.maxX, observed.maxX, accuracy: 1, "\(layout) \(tokenIndex)")
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
        try AXFrameApplyResult(
            requestId: requestId,
            pid: token.pid,
            windowId: token.windowId,
            expectedWindow: fixture.entry(token).axRef,
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

    private func blockRefreshes(_ fixture: Fixture) -> Task<Void, Never> {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .layoutCommand,
            affectedWorkspaceIds: [fixture.workspaceId]
        )
        return blocker
    }

    private func unblockRefreshes(_ fixture: Fixture, blocker: Task<Void, Never>) {
        blocker.cancel()
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
        let fixture = Fixture(controller: controller, workspaceId: workspaceId, monitor: monitor, tokens: tokens)
        if layout == .dwindle {
            controller.dwindleEngine?.cancelAnimations(in: workspaceId)
        }
        let frames = try fixture.frames()
        try fixture.confirmLayout()
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
