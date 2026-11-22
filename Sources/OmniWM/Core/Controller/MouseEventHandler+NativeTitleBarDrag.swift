// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func nativeTitleBarDragCandidate(
        windowIdUnderPointer: Int?
    ) -> (token: WindowToken, workspaceId: WorkspaceDescriptor.ID)? {
        guard let windowIdUnderPointer,
              let entry = controller?.workspaceManager.entry(forWindowId: windowIdUnderPointer),
              entry.mode == .tiling, entry.axRef != nil
        else { return nil }
        return (entry.token, entry.workspaceId)
    }

    func geometricFocusIntentCandidate(at location: CGPoint, in strip: PressedStrip) -> WindowToken? {
        guard let controller else { return nil }
        let token: WindowToken?
        switch strip.layoutKind {
        case .dwindle:
            if case let .dwindle(hit) = strip.doubleClick {
                token = hit?.token
            } else {
                token = controller.dwindleEngine?.hitTestFocusableWindow(
                    point: location,
                    in: strip.workspaceId,
                    at: controller.animationClock.now()
                )
            }
        case .niri:
            token = controller.niriEngine?.hitTestFocusableWindow(
                point: location,
                in: strip.workspaceId
            )?.token
        }
        guard let token,
              controller.workspaceManager.entry(for: token)?.mode == .tiling
        else { return nil }
        return token
    }

    func confirmNativeMouseDrag(at location: CGPoint, button: MouseButton) {
        guard button == .left else { return }
        state.nativeCrossDisplayMove?.wasDragged = true
        if !state.leftPressWasDragged, let press = state.leftPressLocation,
           abs(location.x - press.x) > FrameTolerance.frameWrite
           || abs(location.y - press.y) > FrameTolerance.frameWrite
        {
            state.leftPressWasDragged = true
        }
        if let start = state.nativeResizeStart, !start.wasDragged,
           abs(location.x - start.location.x) <= FrameTolerance.frameWrite,
           abs(location.y - start.location.y) <= FrameTolerance.frameWrite
        {
            return
        }
        state.nativeResizeStart?.wasDragged = true
        let deferredToken = state.nativeResizeStart.flatMap { $0.hasDeferredFrameChange ? $0.token : nil }
        if state.moveTap == nil {
            finishNiriSlideBeforeUnannotatedDrag()
        }
        beginNativeTitleBarDragIfNeeded(button: button)
        handleDeferredNativeTitleBarFrameIfNeeded(for: deferredToken)
    }

    private func finishNiriSlideBeforeUnannotatedDrag() {
        guard state.nativeTitleBarDrag == nil,
              state.awaitsNativeTitleBarDragTarget,
              let token = state.nativeTitleBarDragFallbackToken,
              let controller,
              let pressed = controller.workspaceManager.entry(for: token),
              pressed.mode == .tiling
        else { return }
        finishNiriSlideBeforeDrag(in: pressed.workspaceId, controller: controller)
    }

    func recheckUnannotatedDragAfterSlide(in workspaceId: WorkspaceDescriptor.ID) {
        guard state.nativeTitleBarDrag == nil,
              let token = state.nativeTitleBarDragFallbackToken,
              let pressed = controller?.workspaceManager.entry(for: token),
              pressed.workspaceId == workspaceId
        else { return }
        _ = handleNativeTitleBarDragFrameChanged(for: pressed)
    }

    private func handleDeferredNativeTitleBarFrameIfNeeded(for token: WindowToken? = nil) {
        let deferredToken = token ?? state.nativeResizeStart.flatMap { $0.hasDeferredFrameChange ? $0.token : nil }
        guard let deferredToken,
              let entry = controller?.workspaceManager.entry(for: deferredToken)
        else { return }
        if let drag = state.nativeTitleBarDrag {
            guard drag.token == deferredToken, drag.phase == .dragging else { return }
        } else {
            guard state.awaitsNativeTitleBarDragTarget,
                  state.nativeTitleBarDragFallbackToken == deferredToken
            else { return }
        }
        _ = handleNativeTitleBarDragFrameChanged(for: entry)
    }

    func correctDeferredNativeResizeFrameIfNeeded(excluding token: WindowToken? = nil) {
        guard let start = state.nativeResizeStart,
              start.hasDeferredFrameChange,
              start.token != token
        else { return }
        state.nativeResizeStart = nil
        guard let controller,
              controller.hasStartedServices,
              let entry = controller.workspaceManager.entry(for: start.token),
              entry.mode == .tiling,
              entry.hiddenState == nil
        else { return }
        requestNativeTitleBarDragCorrection(for: entry)
    }

    func rejectNativeTitleBarDragTarget() {
        let fallbackToken = state.nativeTitleBarDragFallbackToken
        let releasedToken = state.nativeTitleBarDrag == nil && state.nativeTitleBarDragFallbackReleased
            ? fallbackToken : nil
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        state.nativeCrossDisplayMove = nil
        guard let releasedToken, let controller, controller.hasStartedServices,
              let entry = controller.workspaceManager.entry(for: releasedToken),
              entry.mode == .tiling, entry.hiddenState == nil
        else {
            correctDeferredNativeResizeFrameIfNeeded()
            state.nativeResizeStart = nil
            if let fallbackToken { recheckRetainedNativeResizeCorrection(for: fallbackToken) }
            return
        }
        state.nativeResizeStart = nil
        state.nativeTitleBarDrag = .init(token: releasedToken, phase: .awaitingFrameChange, targetWasRejected: true)
        _ = handleNativeTitleBarDragFrameChanged(for: entry)
    }

    var nativeTitleBarDragBlocksOverview: Bool {
        guard let drag = state.nativeTitleBarDrag else { return false }
        guard drag.targetWasRejected, drag.phase == .awaitingFrameChange,
              let controller,
              controller.axManager.pendingFrameWrite(for: drag.token.windowId) == nil,
              let entry = controller.workspaceManager.entry(for: drag.token),
              let observedFrame = fastNativeWindowFrame(for: entry),
              nativeWindowFrameMatchesManagedTarget(observedFrame, entry: entry)
        else { return true }
        return false
    }

    func retainNativeResizeCorrection(for token: WindowToken) {
        guard let controller, controller.hasStartedServices,
              let entry = controller.workspaceManager.entry(for: token),
              entry.mode == .tiling, entry.hiddenState == nil, entry.axRef != nil
        else { return }
        if state.nativeResizeCorrectionsByWindowId[token.windowId]?.token != token {
            state.nativeResizeCorrectionsByWindowId[token.windowId] = .init(token: token)
        }
    }

    func handleRetainedNativeResizeCorrection(for entry: WindowState) -> Bool {
        guard var correction = state.nativeResizeCorrectionsByWindowId[entry.windowId] else { return false }
        guard correction.token == entry.token, let controller, controller.hasStartedServices,
              entry.mode == .tiling, entry.hiddenState == nil, entry.axRef != nil
        else {
            state.nativeResizeCorrectionsByWindowId[entry.windowId] = nil
            return false
        }
        if controller.axManager.pendingFrameWrite(for: entry.windowId) != nil {
            correction.needsFrameWriteRecheck = true
            state.nativeResizeCorrectionsByWindowId[entry.windowId] = correction
            return true
        }
        correction.needsFrameWriteRecheck = false
        if let observedFrame = fastNativeWindowFrame(for: entry) {
            correction.issuedUnreadableCorrection = false
            state.nativeResizeCorrectionsByWindowId[entry.windowId] = correction
            if nativeWindowFrameMatchesManagedTarget(observedFrame, entry: entry) { return true }
        } else {
            guard !correction.issuedUnreadableCorrection else {
                state.nativeResizeCorrectionsByWindowId[entry.windowId] = correction
                controller.axManager.invalidateAppliedFrame(for: entry.windowId)
                return true
            }
            correction.issuedUnreadableCorrection = true
            state.nativeResizeCorrectionsByWindowId[entry.windowId] = correction
        }
        requestNativeTitleBarDragCorrection(for: entry)
        return true
    }

    func beginNativeTitleBarDragIfNeeded(button: MouseButton) {
        guard button == .left,
              var drag = state.nativeTitleBarDrag,
              drag.phase == .armed,
              let controller,
              let dragged = controller.workspaceManager.entry(for: drag.token),
              dragged.mode == .tiling
        else { return }
        finishNiriSlideBeforeDrag(in: dragged.workspaceId, controller: controller)
        state.nativeResizeCorrectionsByWindowId[drag.token.windowId] = nil
        let hadUnsettledFrameWrite = controller.axManager.isAwaitingFrameWrite(drag.token.windowId)
            || controller.axManager.hasInFlightFrameWrite(for: drag.token)
        let startFrame = state.nativeResizeStart.flatMap { $0.token == drag.token ? $0.frame : nil }
        let rejection = state.nativeResizeStartRejections[drag.token]
        state.nativeResizeStart = nil
        clearNativeResizeStartRejections()
        drag.phase = .dragging
        let pendingFrameChangesSize = recordNativeDragStartFrames(
            &drag,
            from: (startFrame, rejection),
            awaitingWrite: hadUnsettledFrameWrite,
            in: dragged.workspaceId,
            controller: controller
        )
        MouseTrace.record(
            "title-bar drag dragging token=\(TraceFormat.token(drag.token)) "
                + "awaitingWrite=\(hadUnsettledFrameWrite) "
                + "start=\(TraceFormat.rect(drag.adoptionStartFrame)) pending=\(TraceFormat.rect(drag.pendingWriteStartFrame)) "
                + "live-start=\(TraceFormat.rect(drag.liveStartFrame))"
        )
        state.nativeTitleBarDrag = drag
        controller.axManager.beginNativeTitleBarDrag(for: drag.token)

        guard hadUnsettledFrameWrite,
              !pendingFrameChangesSize,
              let startFrame,
              let entry = controller.workspaceManager.entry(for: drag.token),
              !controller.axManager.hasInFlightFrameWrite(for: drag.token),
              !controller.axManager.isAwaitingFrameWrite(entry.windowId),
              controller.axManager.lastAppliedFrame(for: entry.windowId)?.approximatelyEqual(
                  to: startFrame, tolerance: FrameTolerance.frameWrite
              ) == true,
              var currentDrag = state.nativeTitleBarDrag,
              currentDrag.token == drag.token,
              currentDrag.phase == .dragging
        else { return }
        currentDrag.adoptionStartFrame = startFrame
        state.nativeTitleBarDrag = currentDrag
    }

    private func recordNativeDragStartFrames(
        _ drag: inout MouseInputState.NativeTitleBarDrag,
        from start: (frame: CGRect?, rejection: MouseInputState.NativeResizeStartRejection?),
        awaitingWrite hadUnsettledFrameWrite: Bool,
        in workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> Bool {
        let (startFrame, rejection) = start
        let onNiriStrip = controller.isNiriStrip(workspaceId)
        let onLandscapeStrip = onNiriStrip && controller.isOnLandscapeDisplay(workspaceId)
        let layoutStartFrame = controller.axManager.lastAppliedFrame(for: drag.token.windowId)
        let pending = hadUnsettledFrameWrite ? controller.axManager.awaitedFrameWrite(for: drag.token.windowId) : nil
        let pendingChangesSize = hadUnsettledFrameWrite
            ? (startFrame ?? (onLandscapeStrip ? nil : layoutStartFrame)).map {
                controller.axManager.hasPendingFrameSizeChange(for: drag.token.windowId, comparedTo: $0.size)
            } ?? true : false
        let hasResizePress = onLandscapeStrip || isPortraitResizePress(in: pending ?? layoutStartFrame)
        drag.canStartLiveNiriDrag = onNiriStrip && (onLandscapeStrip || !hasResizePress)
        let resizeFallbackFrame = onNiriStrip || rejection == nil ? layoutStartFrame : nil
        drag
            .adoptionStartFrame = hadUnsettledFrameWrite ? nil : startFrame ??
            (hasResizePress ? resizeFallbackFrame : nil)
        drag.pendingWriteStartFrame = hadUnsettledFrameWrite && hasResizePress
            && (onNiriStrip || rejection != .sizeWrite)
            && (onLandscapeStrip || !pendingChangesSize) ? pending ?? layoutStartFrame : nil
        if !onNiriStrip {
            let frame = startFrame ?? layoutStartFrame
            if !isPortraitResizePress(in: frame) {
                drag.liveStartFrame = frame
                drag.canStartLiveDwindleDrag = true
            }
        }
        if drag.canStartLiveNiriDrag {
            let entry = controller.workspaceManager.entry(for: drag.token)
            drag.liveStartFrame = entry.flatMap(fastNativeWindowFrame) ?? layoutStartFrame ?? startFrame
                ?? entry.flatMap { entry in
                    guard let window = controller.niriEngine?.findNode(for: drag.token, in: entry.workspaceId)
                    else { return nil }
                    return onLandscapeStrip ? window.frame : window.renderedFrame
                }
        }
        return pendingChangesSize
    }

    private func isPortraitResizePress(in frame: CGRect?) -> Bool {
        guard let frame, let press = state.leftPressLocation else { return false }
        return Self.isNativeResizePress(at: press, in: frame)
    }

    static func isNativeResizePress(at point: CGPoint, in frame: CGRect) -> Bool {
        let outset = NiriLayoutEngine.doubleClickEdgeOutset
        let inset = NiriLayoutEngine.doubleClickEdgeInset
        return frame.insetBy(dx: -outset, dy: -outset).contains(point)
            && (point.x < frame.minX + inset || point.x >= frame.maxX - inset
                || point.y < frame.minY + inset || point.y >= frame.maxY - inset)
    }

    private func finishNiriSlideBeforeDrag(in workspaceId: WorkspaceDescriptor.ID, controller: WMController) {
        guard controller.isNiriStrip(workspaceId),
              let engine = controller.niriEngine,
              !engine.isLiveColumnMoveActive(in: workspaceId),
              !engine.isLiveStackDropPending(in: workspaceId),
              hasPendingNiriAnimationWork(
                  state: controller.workspaceManager.niriViewportState(for: workspaceId),
                  driver: controller.workspaceManager.animationDriver,
                  engine: engine,
                  workspaceId: workspaceId
              )
        else { return }
        controller.niriLayoutHandler.cancelAnimationMotion(for: workspaceId)
        refreshLiveColumnLayout(in: workspaceId, engine: engine)
        MouseTrace.record("drag finished the running slide ws=\(workspaceId)")
    }

    private func prepareNativeTitleBarDragForSettlement(button: MouseButton) -> MouseInputState.NativeTitleBarDrag? {
        if state.moveTap != nil, state.nativeTitleBarDrag == nil, state.nativeResizeStart?.wasDragged != true {
            correctDeferredNativeResizeFrameIfNeeded()
        }
        markNativeTitleBarDragFallbackReleased(button: button)
        if state.nativeTitleBarDrag == nil,
           state.nativeTitleBarDragFallbackReleased
        {
            handleDeferredNativeTitleBarFrameIfNeeded()
            return nil
        }
        state.awaitsNativeTitleBarDragTarget = false
        state.nativeTitleBarDragFallbackToken = nil
        state.nativeTitleBarDragFallbackReleased = false
        return state.nativeTitleBarDrag
    }

    func finishNativeTitleBarDragIfNeeded(button: MouseButton) {
        guard button == .left, var drag = prepareNativeTitleBarDragForSettlement(button: button) else { return }
        switch drag.phase {
        case .armed,
             .dragging:
            break
        case .awaitingFrameChange,
             .awaitingFrameWrite,
             .awaitingCorrection:
            return
        }
        drag.pointerWasDragged = state.leftPressWasDragged
        drag.pressLocation = state.leftPressLocation
        drag.releaseLocation = state.leftReleaseLocation
        completeNativeTitleBarRelease(drag)
    }

    private func completeNativeTitleBarRelease(_ drag: MouseInputState.NativeTitleBarDrag) {
        var drag = drag
        guard let controller else {
            discardNativeTitleBarDragState()
            return
        }
        let excludedFrameWrite = controller.axManager.endNativeTitleBarDrag(for: drag.token)
        MouseTrace.record(
            "title-bar drag released token=\(TraceFormat.token(drag.token)) phase=\(drag.phase) "
                + "live=\(drag.liveDrag) declined=\(drag.liveDragDeclined) frameChange=\(drag.receivedFrameChange)"
        )
        guard drag.phase == .dragging,
              controller.hasStartedServices,
              let entry = controller.workspaceManager.entry(for: drag.token),
              entry.mode == .tiling
        else {
            discardNativeTitleBarDragState()
            return
        }
        let finishedLiveDrag = if liveCrossDisplayMove != nil {
            finishLiveCrossDisplayMove(token: drag.token)
        } else if drag.dwindleLiveDrag {
            finishLiveDwindleDrag(token: drag.token, at: drag.releaseLocation)
        } else {
            drag.liveDrag && finishLiveColumnDrag(token: drag.token, startSize: drag.adoptionStartFrame?.size)
        }
        drag.liveDrag = false
        drag.dwindleLiveDrag = false
        drag.canStartLiveDwindleDrag = false
        drag.pendingExcludedCorrection = excludedFrameWrite
        state.nativeTitleBarDrag = drag
        let observedFrame = terminalNativeWindowFrame(for: entry)
        let lastAppliedFrame = controller.axManager.lastAppliedFrame(for: entry.windowId)
        let observedDisplacement = Self.nativeTitleBarWasDisplaced(
            observedFrame: observedFrame, lastAppliedFrame: lastAppliedFrame,
            receivedFrameChange: drag.receivedFrameChange
        )
        settleReleasedNativeTitleBarDrag(
            drag,
            entry: entry,
            observedFrame: observedFrame,
            needsCorrection: finishedLiveDrag || excludedFrameWrite || observedDisplacement
        )
    }

    private func settleReleasedNativeTitleBarDrag(
        _ drag: MouseInputState.NativeTitleBarDrag,
        entry: WindowState,
        observedFrame: CGRect?,
        needsCorrection: Bool
    ) {
        var drag = drag
        if settleNativeCrossDisplayMoveIfNeeded(entry, observedFrame: observedFrame) { return }
        guard needsCorrection || drag.dwindleResizeWorkspaceId != nil else {
            if drag.receivedFrameChange {
                state.nativeTitleBarDrag = nil
            } else {
                drag.phase = .awaitingFrameChange
                state.nativeTitleBarDrag = drag
            }
            return
        }

        if adoptNativeResizeIfEligible(&drag, entry: entry, observedFrame: observedFrame) {
            state.nativeTitleBarDrag = drag
            return
        }
        drag.phase = .awaitingCorrection
        state.nativeTitleBarDrag = drag
        requestNativeTitleBarDragCorrection(for: entry)
    }

    private static func nativeTitleBarWasDisplaced(
        observedFrame: CGRect?, lastAppliedFrame: CGRect?, receivedFrameChange: Bool
    ) -> Bool {
        if let observedFrame, let lastAppliedFrame {
            return !observedFrame.approximatelyEqual(
                to: lastAppliedFrame,
                tolerance: FrameTolerance.frameWrite
            )
        } else if observedFrame != nil {
            return true
        } else {
            return receivedFrameChange
        }
    }
}
