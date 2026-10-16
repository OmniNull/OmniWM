// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
final class MouseEventHandler {
    nonisolated(unsafe) weak static var _instance: MouseEventHandler?

    weak var controller: WMController?
    let inputTapThread = InputTapThread()
    var state = MouseInputState() {
        didSet {
            if oldValue.capturedInteractionButton != state.capturedInteractionButton
                || oldValue.capturedOtherMouseButton != state.capturedOtherMouseButton
                || oldValue.gesturePhase != state.gesturePhase
                || oldValue.consumeTrackpadScrollUntilAllTouchesLift != state.consumeTrackpadScrollUntilAllTouchesLift
                || oldValue.suppressTrackpadMomentumScroll != state.suppressTrackpadMomentumScroll
            {
                syncTapFilterSnapshot()
            }
        }
    }

    var isCapturingPerformance: Bool {
        performanceCounters != nil
    }

    private var multitouchSource: MultitouchGestureSource?
    private var performanceCounters: MousePerformanceCounters?
    var multitouchSourceFactory: @MainActor () -> MultitouchGestureSource = { MultitouchGestureSource() }
    var pressedMouseButtonsProvider: @MainActor () -> Int = { Int(NSEvent.pressedMouseButtons) }
    var nativeWindowFrameProvider: @MainActor (AXWindowRef) -> CGRect? = {
        AXWindowService.framePreferFast($0)
    }

    init(controller: WMController) {
        self.controller = controller
    }

    @discardableResult
    func installMultitouchSource(_ source: MultitouchGestureSource) -> Bool {
        let current = multitouchSource
        if let current, current !== source {
            guard current.shutdown() else { return false }
            accumulateRetiredMultitouchPerformance(from: current)
        }
        source.onSnapshot = { [weak self, weak source] snapshot in
            guard let self else { return }
            receiveTapGestureEvent(snapshot)
            source?.rawFrameMailbox.setSteadyFrameFloor(steadyTouchFrameFloor)
        }
        source.onContactSessions = { [weak self] contacts in
            self?.updateContactSessions(contacts)
        }
        source.onSourceWillReplace = { [weak self] in
            self?.resetForMultitouchSourceReplacement()
        }
        multitouchSource = source
        inputTapThread.touchCountProvider = { [weak mailbox = source.rawFrameMailbox] in
            mailbox?.activePhysicalFingerCount ?? 0
        }
        if performanceCounters != nil, current !== source {
            source.beginPerformanceCapture()
        }
        guard source.startLifecycle() else {
            accumulateRetiredMultitouchPerformance(from: source)
            multitouchSource = nil
            return false
        }
        return true
    }

    func cleanup() {
        state.latestFocusFollowsMouseSample = nil
        clearNativeTitleBarDrag()
        cancelActiveMouseInteraction()
        state.capturedInteractionButton = nil
        state.capturedOtherMouseButton = nil
        tearDownEventTaps()
        inputTapThread.touchCountProvider = nil
        inputTapThread.stop()
        let retiringMultitouchSource = multitouchSource
        if retiringMultitouchSource?.shutdown() != false {
            if let retiringMultitouchSource {
                accumulateRetiredMultitouchPerformance(from: retiringMultitouchSource)
            }
            multitouchSource = nil
        }
        MouseEventHandler._instance = nil
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "mouse.moveTap.removed")
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "mouse.tap.removed")
        controller?.eventIntake.removePendingMouseEvents()
        resetForMultitouchSourceReplacement()
    }

    func reconcileMultitouchSource() {
        guard let controller, controller.hasStartedServices else { return }
        let shouldRun = controller.settings.effectiveTrackpadGesturesEnabled
        if shouldRun {
            if let multitouchSource {
                if !multitouchSource.startLifecycle() {
                    FallbackFiringRecorder.shared.note(.input, "multitouchSourceCleanupBlocked")
                }
                return
            }
            if !installMultitouchSource(multitouchSourceFactory()) {
                FallbackFiringRecorder.shared.note(.input, "multitouchSourceCleanupBlocked")
            }
        } else {
            let retiringMultitouchSource = multitouchSource
            inputTapThread.touchCountProvider = nil
            if retiringMultitouchSource?.shutdown() != false {
                if let retiringMultitouchSource {
                    accumulateRetiredMultitouchPerformance(from: retiringMultitouchSource)
                }
                multitouchSource = nil
                resetForMultitouchSourceReplacement()
            } else {
                FallbackFiringRecorder.shared.note(.input, "multitouchSourceCleanupBlocked")
            }
        }
    }

    func beginPerformanceCapture() {
        performanceCounters = MousePerformanceCounters()
        multitouchSource?.beginPerformanceCapture()
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        guard let performanceCounters else { return nil }
        return performanceCounters.snapshot(multitouch: multitouchSource?.performanceSnapshot())
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        guard let performanceCounters else { return nil }
        let multitouch = multitouchSource?.endPerformanceCapture()
        let snapshot = performanceCounters.snapshot(multitouch: multitouch)
        self.performanceCounters = nil
        return snapshot
    }

    private func accumulateRetiredMultitouchPerformance(from source: MultitouchGestureSource) {
        guard var performanceCounters,
              let snapshot = source.endPerformanceCapture()
        else { return }
        performanceCounters.accumulateRetiredMultitouch(snapshot)
        self.performanceCounters = performanceCounters
    }

    func requestMultitouchRevalidation(_ reason: MultitouchGestureSource.RevalidationReason) {
        multitouchSource?.requestRevalidation(reason)
    }

    func clearGestureLatches() {
        state.suppressGestureStartUntilAllTouchesLift = false
        state.consumeTrackpadScrollUntilAllTouchesLift = false
    }

    func suspendMultitouchForSleep() {
        multitouchSource?.suspendForSleep()
    }

    var multitouchDiagnosticsSnapshot: MultitouchGestureSource.DiagnosticsSnapshot? {
        multitouchSource?.diagnosticsSnapshot()
    }

    func resetForMultitouchSourceReplacement() {
        controller?.layoutRefreshController.workspaceSwipe.cancel(reason: "source-replaced")
        resetGestureState()
        state.workspaceSwipeTracker.reset()
        clearGestureLatches()
        state.suppressTrackpadMomentumScroll = false
        state.contactSessions = MultitouchContactSessions()
        clearConsumedTrackpadSessions()
        inputTapThread.touchCountProvider = nil
    }

    func drainTrackpadFrames(for senderId: UInt64, at location: CGPoint) {
        guard let multitouchSource, multitouchSource.hasSender(senderId) else { return }
        multitouchSource.drainRawFrameMailbox(location: location)
    }

    func updateContactSessions(_ contacts: MultitouchContactSessions) {
        state.contactSessions = contacts
        state.consumedTrackpadSessions = state.consumedTrackpadSessions.filter {
            let keep = contacts.contains($0.value)
            if !keep { traceTrackpadOwnership(.retire, contact: $0.value) }
            return keep
        }
    }

    func retainConsumedTrackpadSession() {
        guard state.gesturePhase != .idle,
              let contact = state.lockedGestureContext?.contactSession,
              let senderId = contact.senderId, senderId != 0,
              state.contactSessions.contains(contact)
        else { return }
        state.consumedTrackpadSessions[senderId] = contact
        traceTrackpadOwnership(.retain, contact: contact)
    }

    func clearConsumedTrackpadSessions() {
        if TrackpadScrollTrace.shared.isActive {
            for contact in state.consumedTrackpadSessions.values {
                traceTrackpadOwnership(.clear, contact: contact)
            }
        }
        state.consumedTrackpadSessions.removeAll(keepingCapacity: true)
    }

    func recordTrackpadTraceSnapshot() {
        guard TrackpadScrollTrace.shared.isActive else { return }
        multitouchSource?.recordTraceSnapshot()
        for contact in state.consumedTrackpadSessions.values {
            traceTrackpadOwnership(.seed, contact: contact)
        }
    }

    func consumesTrackpadSession(senderId: UInt64) -> Bool {
        if state.gesturePhase != .idle,
           let contact = state.lockedGestureContext?.contactSession,
           contact.senderId == senderId,
           state.contactSessions.contains(contact)
        {
            return true
        }
        guard let contact = state.consumedTrackpadSessions[senderId] else { return false }
        return state.contactSessions.contains(contact)
    }

    func recordMouseWarpSample() {
        performanceCounters?.mouseWarpSamples &+= 1
    }

    func recordDroppedTrackpadScroll() {
        performanceCounters?.droppedTrackpadScrollEvents &+= 1
    }

    func recordCGEvent(_ type: CGEventType) {
        guard performanceCounters != nil else { return }
        performanceCounters?.cgEvents &+= 1
        switch type {
        case .mouseMoved:
            performanceCounters?.mouseMovedEvents &+= 1
        case .leftMouseDragged,
             .rightMouseDragged,
             .otherMouseDragged:
            performanceCounters?.mouseDraggedEvents &+= 1
        case .scrollWheel:
            performanceCounters?.scrollEvents &+= 1
        case .leftMouseDown,
             .leftMouseUp,
             .rightMouseDown,
             .rightMouseUp,
             .otherMouseDown,
             .otherMouseUp:
            performanceCounters?.buttonEvents &+= 1
        default:
            break
        }
    }

    func syncTapFilterSnapshot() {
        let capturedButton = state.capturedInteractionButton
        var resolvedOtherButtons = claimedOtherMouseButtons()
        if let capturedOther = state.capturedOtherMouseButton {
            resolvedOtherButtons.insert(capturedOther)
        }
        let otherButtons = resolvedOtherButtons
        let moveFlags = controller?.settings.gestures.mouseMoveModifierKey.cgEventFlags
        let resizeFlags = controller?.settings.gestures.mouseResizeModifierKey.cgEventFlag ?? []
        let scrollFlags = controller?.settings.gestures.scrollModifierKey.cgEventFlag ?? []
        let minFingers: Int
        if let controller, controller.settings.effectiveTrackpadGesturesEnabled {
            let minCount = trackpadGestureConfig?.minimumFingerCount ?? 3
            minFingers = minCount == 0 ? .max : minCount
        } else {
            minFingers = .max
        }
        let latched = state.gesturePhase != .idle
            || state.consumeTrackpadScrollUntilAllTouchesLift
            || state.suppressTrackpadMomentumScroll
        let inputSuppressed = isInputSuppressed

        inputTapThread.updateFilterSnapshot { snapshot in
            snapshot.activeCapture = capturedButton
            snapshot.claimedOtherButtons = otherButtons
            snapshot.moveModifier = moveFlags
            snapshot.resizeModifier = resizeFlags
            snapshot.scrollModifier = scrollFlags
            snapshot.minGestureFingers = minFingers
            snapshot.gestureActiveOrLatched = latched
            snapshot.isInputSuppressed = inputSuppressed
        }
    }

    private func claimedOtherMouseButtons() -> Set<Int64> {
        guard let controller else { return [] }
        var buttons = Set<Int64>()
        if controller.settings.overview.enabled,
           let overviewButton = controller.settings.overview.mouseButton,
           controller.settings.systemHyperTrigger.mouseButtonNumber != overviewButton
        {
            buttons.insert(overviewButton)
        }
        for binding in controller.settings.hotkeyBindings {
            if let button = binding.binding.mouseButtonBinding?.button {
                buttons.insert(button)
            }
        }
        return buttons
    }
}
