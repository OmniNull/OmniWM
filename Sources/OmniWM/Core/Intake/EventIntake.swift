// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import os

enum IntakeEvent: Sendable {
    case axWindow(AXWindowIntakeEvent)
    case application(ApplicationIntakeEvent)
    case activationFactsResolved(ActivationFacts)
    case focusedAdmissionRetryFactRequestSuperseded(AdmissionRetryExecution)
    case activeSpaceChanged
    case cgs(CGSWindowEvent)
    case display(DisplayConfigurationObserver.DisplayEvent)
    case hotkeyInvocation(HotkeyInvocation)
    case intentExpired(intentId: IntentID, deadlineGeneration: UInt64)
    case ipcCommand(IPCCommandIntake)
    case mouseDragged(button: MouseEventHandler.MouseButton, location: CGPoint)
    case mouseMoved(location: CGPoint, modifiersRawValue: UInt64, windowIdUnderPointer: Int?)
    case mouseScroll(MouseScrollIntake)
    case nativeFullscreenTransitionExpired(originalToken: WindowToken, generation: Int)
    case systemSleep
    case systemWake
    case windowConstraintsResolved(WindowConstraintsFact)
}

struct IPCCommandIntake: Sendable {
    let perform: @MainActor @Sendable (WMController) -> ExternalCommandResult
    let completion: @MainActor @Sendable (ExternalCommandResult) -> Void
}

struct MouseScrollIntake: Sendable {
    var location: CGPoint
    var deltaX: CGFloat
    var deltaY: CGFloat
    let momentumPhase: UInt32
    let phase: UInt32
    let modifiersRawValue: UInt64
    var isContinuous: Bool = false
    var senderId: UInt64?

    private static let axisEpsilon: CGFloat = 0.001

    var modifiers: CGEventFlags {
        CGEventFlags(rawValue: modifiersRawValue)
    }

    func matches(_ other: MouseScrollIntake) -> Bool {
        modifiersRawValue == other.modifiersRawValue
            && momentumPhase == other.momentumPhase
            && phase == other.phase
            && isContinuous == other.isContinuous
            && senderId == other.senderId
    }

    func canCoalesce(_ other: MouseScrollIntake) -> Bool {
        axisSignature == other.axisSignature
    }

    mutating func accumulate(_ other: MouseScrollIntake) {
        deltaX += other.deltaX
        deltaY += other.deltaY
        location = other.location
    }

    private var axisSignature: (Int, Int) {
        (Self.signedAxis(deltaX), Self.signedAxis(deltaY))
    }

    private static func signedAxis(_ delta: CGFloat) -> Int {
        guard abs(delta) > axisEpsilon else { return 0 }
        return delta > 0 ? 1 : -1
    }
}

struct StampedIntakeEvent: Sendable {
    let seq: UInt64
    let event: IntakeEvent
    let enqueuedUptimeNs: UInt64?

    init(
        seq: UInt64,
        event: IntakeEvent,
        enqueuedUptimeNs: UInt64? = EventIntakeTrace.shared.isActive ? DispatchTime.now().uptimeNanoseconds : nil
    ) {
        self.seq = seq
        self.event = event
        self.enqueuedUptimeNs = enqueuedUptimeNs
    }

    func replacingEvent(with event: IntakeEvent) -> StampedIntakeEvent {
        StampedIntakeEvent(seq: seq, event: event, enqueuedUptimeNs: enqueuedUptimeNs)
    }
}

@MainActor
protocol EventIntakeSink: AnyObject {
    func handleIntakeEvent(_ stamped: StampedIntakeEvent)
}

@MainActor
final class EventIntake {
    struct EventCategoryPerformanceSnapshot: Equatable, Sendable {
        let acceptedEvents: UInt64
        let coalescedEvents: UInt64
        let deliveredEvents: UInt64
    }

    struct PerformanceSnapshot: Equatable, Sendable {
        let acceptedEvents: UInt64
        let coalescedEvents: UInt64
        let deliveredEvents: UInt64
        let drainBatches: UInt64
        let currentQueueDepth: Int
        let maximumQueueDepth: Int
        let maximumBatchSize: Int
        let cgsCreatedEvents: EventCategoryPerformanceSnapshot
        let cgsDestroyedEvents: EventCategoryPerformanceSnapshot
        let cgsFrameChangedEvents: EventCategoryPerformanceSnapshot
        let cgsTitleChangedEvents: EventCategoryPerformanceSnapshot
        let axLifecycleEvents: EventCategoryPerformanceSnapshot
        let axFocusedWindowChangedEvents: EventCategoryPerformanceSnapshot
    }

    private struct Buffer {
        var isOpen = false
        var drainScheduled = false
        var nextSeq: UInt64 = 1
        var orderedEvents: [StampedIntakeEvent] = []
        var spareOrderedEvents: [StampedIntakeEvent] = []
        var pendingCGSFrameWindowIds: Set<UInt32> = []
        var openMouseMovedSeq: UInt64?
        var openLeftDraggedSeq: UInt64?
        var openRightDraggedSeq: UInt64?
        var openScrollSeq: UInt64?
        var performanceCounters: IntakePerformanceCounters?

        mutating func closeMouseCoalescingWindows() {
            openMouseMovedSeq = nil
            openLeftDraggedSeq = nil
            openRightDraggedSeq = nil
            openScrollSeq = nil
        }

        mutating func closeMouseCoalescingWindows(keeping kept: WritableKeyPath<Buffer, UInt64?>) {
            let keptSeq = self[keyPath: kept]
            closeMouseCoalescingWindows()
            self[keyPath: kept] = keptSeq
        }
    }

    private nonisolated let buffer = OSAllocatedUnfairLock(initialState: Buffer())
    private weak var sink: EventIntakeSink?

    nonisolated var lastSeq: UInt64 {
        buffer.withLock { $0.nextSeq - 1 }
    }

    nonisolated var hasPendingEvents: Bool {
        buffer.withLock { !$0.orderedEvents.isEmpty }
    }

    nonisolated func beginPerformanceCapture() {
        buffer.withLock { state in
            state.performanceCounters = IntakePerformanceCounters(
                maximumQueueDepth: state.orderedEvents.count
            )
        }
    }

    nonisolated func performanceSnapshot() -> PerformanceSnapshot? {
        buffer.withLock { state in
            state.performanceCounters?.snapshot(currentQueueDepth: state.orderedEvents.count)
        }
    }

    nonisolated func endPerformanceCapture() -> PerformanceSnapshot? {
        buffer.withLock { state in
            let snapshot = state.performanceCounters?.snapshot(
                currentQueueDepth: state.orderedEvents.count
            )
            state.performanceCounters = nil
            return snapshot
        }
    }

    @discardableResult
    nonisolated static func post(_ event: IntakeEvent) -> Bool {
        activeIntake.withLock { $0 }?.enqueue(event) ?? false
    }

    nonisolated static func currentSeq() -> UInt64 {
        activeIntake.withLock { $0 }?.lastSeq ?? 0
    }

    func open(sink: EventIntakeSink) {
        self.sink = sink
        buffer.withLock { $0.isOpen = true }
        activeIntake.withLock { $0 = self }
    }

    func close() {
        activeIntake.withLock { active in
            if active === self {
                active = nil
            }
        }
        let dropped = buffer.withLock { state -> [StampedIntakeEvent] in
            var dropped: [StampedIntakeEvent] = []
            swap(&dropped, &state.orderedEvents)
            state.isOpen = false
            state.drainScheduled = false
            state.orderedEvents.removeAll(keepingCapacity: false)
            state.spareOrderedEvents.removeAll(keepingCapacity: false)
            state.pendingCGSFrameWindowIds.removeAll(keepingCapacity: false)
            state.closeMouseCoalescingWindows()
            return dropped
        }
        sink = nil
        completeDroppedCommands(dropped)
    }

    @discardableResult
    nonisolated func enqueue(_ event: IntakeEvent) -> Bool {
        let (didEnqueue, shouldScheduleDrain) = buffer.withLock { state -> (Bool, Bool) in
            guard state.isOpen else { return (false, false) }
            if state.performanceCounters == nil {
                stampAndCoalesce(event, into: &state)
            } else {
                let sequenceBefore = state.nextSeq
                stampAndCoalesce(event, into: &state)
                let wasCoalesced = state.nextSeq == sequenceBefore
                let queueDepth = state.orderedEvents.count
                state.performanceCounters?.recordAccepted(
                    event,
                    coalesced: wasCoalesced,
                    queueDepth: queueDepth
                )
            }
            guard !state.drainScheduled else { return (true, false) }
            state.drainScheduled = true
            return (true, true)
        }
        if shouldScheduleDrain {
            scheduleDrain()
        }
        return didEnqueue
    }

    func drainNow() {
        drainPendingEventsOnMainRunLoop()
    }

    private func completeDroppedCommands(_ dropped: [StampedIntakeEvent]) {
        for stamped in dropped {
            if case let .ipcCommand(intake) = stamped.event {
                intake.completion(.ignoredDisabled)
            }
        }
    }

    private nonisolated func stampAndCoalesce(_ event: IntakeEvent, into state: inout Buffer) {
        switch event {
        case let .cgs(.frameChanged(windowId)):
            state.closeMouseCoalescingWindows()
            guard state.pendingCGSFrameWindowIds.insert(windowId).inserted else { return }

        case let .cgs(.closed(windowId)),
             let .cgs(.destroyed(windowId, _)):
            removePendingCGSFrameEvents(windowId: windowId, state: &state)
            state.closeMouseCoalescingWindows()

        case let .mouseDragged(button, _):
            switch button {
            case .left:
                state.closeMouseCoalescingWindows(keeping: \.openLeftDraggedSeq)
                if updatePendingEvent(seq: state.openLeftDraggedSeq, in: &state, to: event) {
                    return
                }
                state.openLeftDraggedSeq = state.nextSeq
            case .right:
                state.closeMouseCoalescingWindows(keeping: \.openRightDraggedSeq)
                if updatePendingEvent(seq: state.openRightDraggedSeq, in: &state, to: event) {
                    return
                }
                state.openRightDraggedSeq = state.nextSeq
            }

        case .mouseMoved:
            state.closeMouseCoalescingWindows(keeping: \.openMouseMovedSeq)
            if updatePendingEvent(seq: state.openMouseMovedSeq, in: &state, to: event) {
                return
            }
            state.openMouseMovedSeq = state.nextSeq

        case let .mouseScroll(payload):
            state.closeMouseCoalescingWindows(keeping: \.openScrollSeq)
            if let openSeq = state.openScrollSeq,
               let index = state.orderedEvents.lastIndex(where: { $0.seq == openSeq }),
               case let .mouseScroll(existing) = state.orderedEvents[index].event
            {
                if existing.matches(payload), existing.canCoalesce(payload) {
                    var merged = existing
                    merged.accumulate(payload)
                    state.orderedEvents[index] = state.orderedEvents[index].replacingEvent(with: .mouseScroll(merged))
                    return
                }
                state.closeMouseCoalescingWindows()
            }
            state.openScrollSeq = state.nextSeq

        default:
            state.closeMouseCoalescingWindows()
        }

        state.orderedEvents.append(StampedIntakeEvent(seq: state.nextSeq, event: event))
        state.nextSeq += 1
    }

    private nonisolated func updatePendingEvent(
        seq: UInt64?,
        in state: inout Buffer,
        to event: IntakeEvent
    ) -> Bool {
        guard let seq, let index = state.orderedEvents.lastIndex(where: { $0.seq == seq }) else { return false }
        state.orderedEvents[index] = state.orderedEvents[index].replacingEvent(with: event)
        return true
    }

    nonisolated func removePendingMouseEvents() {
        buffer.withLock { state in
            state.closeMouseCoalescingWindows()
            state.orderedEvents.removeAll { stamped in
                switch stamped.event {
                case .mouseDragged,
                     .mouseMoved,
                     .mouseScroll:
                    return true
                default:
                    return false
                }
            }
        }
    }

    private nonisolated func removePendingCGSFrameEvents(windowId: UInt32, state: inout Buffer) {
        guard state.pendingCGSFrameWindowIds.remove(windowId) != nil else { return }
        state.orderedEvents.removeAll { stamped in
            if case let .cgs(.frameChanged(pendingWindowId)) = stamped.event {
                return pendingWindowId == windowId
            }
            return false
        }
    }

    private nonisolated func scheduleDrain() {
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                self.drainPendingEventsOnMainRunLoop()
            }
        }
        CFRunLoopWakeUp(mainRunLoop)
    }

    private func drainPendingEventsOnMainRunLoop() {
        var events = buffer.withLock { state -> [StampedIntakeEvent] in
            var events: [StampedIntakeEvent] = []
            swap(&events, &state.spareOrderedEvents)
            events.removeAll(keepingCapacity: true)
            swap(&events, &state.orderedEvents)
            state.pendingCGSFrameWindowIds.removeAll(keepingCapacity: true)
            state.closeMouseCoalescingWindows()
            state.drainScheduled = false
            state.performanceCounters?.recordDrain(events)
            return events
        }
        defer {
            events.removeAll(keepingCapacity: true)
            recycleDrainedEvents(events)
        }
        guard let sink else { return }
        for stamped in events {
            EventIntakeTrace.measure(stamped) {
                sink.handleIntakeEvent(stamped)
            }
        }
    }

    private nonisolated func recycleDrainedEvents(_ events: [StampedIntakeEvent]) {
        buffer.withLock { state in
            guard state.isOpen,
                  events.capacity > state.spareOrderedEvents.capacity
            else { return }
            state.spareOrderedEvents = events
        }
    }
}

private let activeIntake = OSAllocatedUnfairLock<EventIntake?>(initialState: nil)
