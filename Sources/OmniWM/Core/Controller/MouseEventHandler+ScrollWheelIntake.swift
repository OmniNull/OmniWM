// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension MouseEventHandler {
    func receiveTapScrollWheel(
        _ payload: MouseScrollIntake,
        traceMetadata: TrackpadScrollTrace.ScrollMetadata? = nil
    ) -> Bool {
        let traceSender = traceMetadata?.senderId ?? payload.senderId
        let before = TrackpadScrollTrace.shared.isActive ? trackpadTraceState(senderId: traceSender) : nil
        var decision = ScrollDecision.inputSuppressed
        defer {
            if let before {
                TrackpadScrollTrace.record(.scroll(.init(
                    payload: payload, metadata: traceMetadata, decision: decision,
                    before: before, after: trackpadTraceState(senderId: traceSender)
                )))
            }
        }
        guard !isInputSuppressed else {
            handleInputSuppressionBegan()
            return false
        }
        if payload.phase == 0, payload.momentumPhase == 0, payload.isContinuous,
           let senderId = payload.senderId, senderId != 0
        {
            drainTrackpadFrames(for: senderId, at: payload.location)
            if consumesTrackpadSession(senderId: senderId) {
                recordDroppedTrackpadScroll()
                decision = .ownedSession
                return true
            }
        }
        decision = scrollDecision(
            at: payload.location,
            momentumPhase: payload.momentumPhase,
            phase: payload.phase,
            modifiers: payload.modifiers
        )
        let suppress = decision.suppresses
        if suppress, MouseTrace.shared.isActive {
            MouseTrace.record("tap: scroll suppressed loc=\(TraceFormat.point(payload.location))")
        }
        if payload.momentumPhase == 0, payload.phase == 0 {
            EventIntake.post(.mouseScroll(payload))
        } else {
            recordDroppedTrackpadScroll()
        }
        return suppress
    }

    private func scrollDecision(
        at location: CGPoint,
        momentumPhase: UInt32,
        phase: UInt32,
        modifiers: CGEventFlags
    ) -> ScrollDecision {
        let isTrackpad = momentumPhase != 0 || phase != 0
        if isTrackpad { return trackpadScrollDecision(momentumPhase: momentumPhase, phase: phase) }

        guard let controller, controller.isEnabled,
              controller.settings.effectiveTrackpadGesturesEnabled
        else {
            return .wheelDisabled
        }
        if controller.isOverviewOpen() { return .overview }
        if shouldBlockOwnWindowGestureInput(at: location) { return .ownWindow }
        guard !state.isResizing, !state.isMoving, !isLiveColumnDragActive, liveDragSession?.carriedWindow == nil
        else { return .windowInteraction }
        guard controller.settings.gestures.scrollEnabled else { return .wheelDisabled }
        let requiredModifiers = controller.settings.gestures.scrollModifierKey.cgEventFlag
        guard Self.mouseWheelModifiersMatch(modifiers, required: requiredModifiers) else { return .modifierMismatch }
        return resolveScrollContext(at: location) != nil ? .wheelBinding : .wheelUnclaimed
    }

    private func trackpadScrollDecision(momentumPhase: UInt32, phase: UInt32) -> ScrollDecision {
        if isTrackpadSwipeSessionActive {
            if phase == CGScrollPhase.began.rawValue { tapInputs.suppressTrackpadMomentumScroll = false }
            return .activeGesture
        }
        if tapInputs.consumeTrackpadScrollUntilAllTouchesLift { return .liftLatch }
        if tapInputs.suppressTrackpadMomentumScroll {
            if momentumPhase != 0 { return .momentumTail }
            if phase == CGScrollPhase.ended.rawValue || phase == CGScrollPhase.cancelled.rawValue {
                return .terminalTail
            }
            guard phase == CGScrollPhase.began.rawValue else { return .momentumTail }
            tapInputs.suppressTrackpadMomentumScroll = false
            return .freshPhase
        }
        return .trackpadUnclaimed
    }
}
