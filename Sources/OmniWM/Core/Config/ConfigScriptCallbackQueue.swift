// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost
#if OMNIWM_SCRIPT_ARC_AUDIT
    import ScriptARCCounters
#endif

@MainActor
final class ConfigScriptCallbackQueue {
    static let capacity = 8

    private enum WorkerState {
        case starting
        case working
        case parked(UnsafeContinuation<Void, Never>)
        case retired
    }

    let generation: ConfigScriptGeneration
    let ruleApplyGeneration = ConfigScriptCallbackQueue.nextRuleApplyGeneration()
    let declarations: [Int: Declaration]
    private let listeners: [ConfigScriptEventKind: [Listener]]
    private let eventReads: [ConfigScriptEventKind: EventReads]?
    private var snapshotPool = ConfigScriptSnapshotPool()
    private var work: [Work?]
    private var pendingEvents: [ConfigScriptEventKind: Int] = [:]
    private var pendingWindowStates: [WindowStateKey: Int] = [:]
    private var lastWindowStateSlot = 0
    private var missedWindowStates: UInt64 = 0
    var feedback = ConfigScriptEventFeedback()
    private var head = 0
    private var pendingCount = 0
    private var pendingEdges = 0
    private var lastEdgeSlot = 0
    private var missedEdges: UInt64 = 0
    private var outstandingPresses = 0
    private weak var executionController: WMController?
    private var state = WorkerState.starting
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var worker: Task<Void, Never>?

    init(
        generation: ConfigScriptGeneration, bindings: [ConfigScriptBinding], commands: [ConfigScriptNamedCommand],
        events: [ConfigScriptEventListener], fullQueueDiagnostic: (String, Int) -> String
    ) {
        self.generation = generation
        var sites: [Int: Declaration] = [:]
        for row in bindings {
            if case let .configFunction(function) = row.command {
                sites[function] = Declaration(
                    fullQueueDiagnostic: fullQueueDiagnostic(row.source, row.line),
                    reads: row.reads
                )
            }
        }
        for row in commands {
            sites[row.function] = Declaration(
                fullQueueDiagnostic: fullQueueDiagnostic(row.source, row.line),
                reads: row.reads
            )
        }
        declarations = sites
        var listeners: [ConfigScriptEventKind: [Listener]] = [:]
        var demands: [ConfigScriptEventKind: EventReads] = [:]
        for (index, row) in events.enumerated() {
            listeners[row.kind, default: []].append(Listener(function: row.function, index: index))
            if !row.reads.isEmpty {
                demands[row.kind, default: EventReads()].all.formUnion(row.reads)
                demands[row.kind, default: EventReads()].readers.append((index, row.reads))
            }
        }
        self.listeners = listeners
        eventReads = demands.isEmpty ? nil : demands
        let stateCount = listeners.keys.count { $0.delivery == .latest }
        let edgeSlots = listeners.keys.contains { $0.delivery == .edge } ? Self.edgeCapacity : 0
        let windowSlots = listeners.keys.contains { $0.delivery == .latestPerWindow } ? Self.windowStateCapacity : 0
        work = [Work?](repeating: nil, count: Self.capacity + stateCount + edgeSlots + windowSlots)
        pendingEvents.reserveCapacity(stateCount)
        pendingWindowStates.reserveCapacity(windowSlots)
    }

    var hasCloseListener: Bool {
        listeners[.windowClose] != nil
    }

    var isRetired: Bool {
        if case .retired = state { return true }
        return false
    }

    var isParked: Bool {
        if case .parked = state { return true }
        return false
    }

    var hasPendingWork: Bool {
        pendingCount != 0
    }

    func waitUntilParked() async {
        guard worker != nil, !isParked else { return }
        await withCheckedContinuation { parkWaiters.append($0) }
    }

    private func notifyParkWaiters() {
        if !parkWaiters.isEmpty {
            for waiter in parkWaiters { waiter.resume() }
            parkWaiters.removeAll()
        }
    }

    var hasCapacity: Bool {
        outstandingPresses < Self.capacity
    }

    static func enqueue(
        _ function: Int, in queue: inout ConfigScriptCallbackQueue?, controller: WMController
    ) -> ExternalCommandResult {
        guard let queue, let reads = queue.declarations[function]?.reads else { return .notFound }
        guard queue.hasCapacity else { return .windowActionFailed }
        queue.outstandingPresses += 1
        queue.append(Work(trigger: .function(function, queue.capture(reads: reads, controller: controller))))
        queue.wake(controller)
        return .executed
    }

    static func publish(
        _ kind: ConfigScriptEventKind, _ event: consuming ConfigScriptNativeEvent,
        in queue: inout ConfigScriptCallbackQueue?, controller: WMController
    ) {
        queue?.enqueue(kind, argument: consume event, controller: controller)
    }

    func hasPendingMinimize(_ token: WindowToken, epoch: UInt64) -> Bool {
        pendingWindowStates[.window(.windowMinimize, token, epoch)] != nil
    }

    func recordMissedMinimizations(_ count: Int) {
        guard !allExcluded(.windowMinimize, by: feedback.currentExclusions) else { return }
        missedWindowStates += UInt64(count)
        if !pendingWindowStates.isEmpty { work[lastWindowStateSlot]?.missed = missedWindowStates }
    }

    func recordMissedEdges(_ count: Int, kind: ConfigScriptEventKind) {
        if !allExcluded(kind, by: feedback.currentExclusions) { recordMissedEdges(count) }
    }

    private func recordMissedEdges(_ count: Int) {
        missedEdges += UInt64(count)
        if pendingEdges > 0 { work[lastEdgeSlot]?.missed = missedEdges }
    }

    private func enqueue(
        _ kind: ConfigScriptEventKind, argument: consuming ConfigScriptNativeEvent, controller: WMController
    ) {
        if case .retired = state { return }
        let mask = exclusions(kind, argument: argument, controller: controller)
        if stage(kind, consume argument, excluding: mask, manager: controller.workspaceManager, capture: {
            eventCapture(kind, excluding: $0, controller: controller)
        }) { wake(controller) }
    }

    static func publish(
        _ kind: ConfigScriptEventKind, _ event: consuming ConfigScriptNativeEvent,
        in queue: inout ConfigScriptCallbackQueue?, manager: WorkspaceManager, observer: ConfigScriptEventObservers
    ) {
        guard let queue else { return }
        let confirmed = kind == .windowFullscreen ? observer.windowStates.confirmingFullscreen?.excludingSelf : nil
        queue.enqueue(kind, consume event, manager: manager, input: observer.nativeInput, confirmed: confirmed)
    }

    private func enqueue(
        _ kind: ConfigScriptEventKind, _ event: consuming ConfigScriptNativeEvent,
        manager: WorkspaceManager, input: ConfigScriptEventInput, confirmed: ConfigScriptListenerMask?
    ) {
        if case .retired = state { return }
        var mask = feedback.currentExclusions
        if kind == .windowClose, let token = event.windowToken {
            mask = feedback.closeExclusions(token: token)
        } else if let confirmed {
            mask = Self.combined(mask, confirmed)
        }
        if stage(kind, consume event, excluding: mask, manager: manager, capture: { excluded in
            if eventReads?[kind] != nil {
                guard let controller = executionController else { return nil }
                return eventCapture(kind, excluding: excluded, controller: controller)
            }
            return ConfigScriptCapture(
                target: manager.configScriptTarget(session: input.session.identity, apps: input.apps), snapshot: nil
            )
        }) { wake(nil) }
    }

    private func stage(
        _ kind: ConfigScriptEventKind, _ argument: consuming ConfigScriptNativeEvent,
        excluding excluded: ConfigScriptListenerMask?, manager: WorkspaceManager,
        capture: (ConfigScriptListenerMask?) -> ConfigScriptCapture?
    ) -> Bool {
        switch kind.delivery {
        case .edge:
            if allExcluded(kind, by: excluded) { return false }
            guard pendingEdges < Self.edgeCapacity else {
                recordMissedEdges(1)
                return false
            }
            guard let capture = capture(excluded) else { return false }
            lastEdgeSlot = append(Work(
                trigger: .event(kind, consume argument, excluding: excluded, capture: consume capture),
                missed: missedEdges
            ))
            pendingEdges += 1
        case .latest:
            let slot = pendingEvents[kind]
            if slot == nil, allExcluded(kind, by: excluded) { return false }
            let next = Work(
                trigger: .event(kind, consume argument, excluding: excluded, capture: nil),
                focus: manager.configScriptFocusBaseline
            )
            if let slot {
                work[slot] = consume next
            } else {
                pendingEvents[kind] = append(consume next)
            }
        case .latestPerWindow:
            guard let key = Self.windowKey(kind, argument),
                  storeWindowState(
                      .event(kind, consume argument, excluding: excluded, capture: nil),
                      key: key,
                      kind: kind,
                      excluding: excluded,
                      focus: manager.configScriptFocusBaseline
                  ) else { return false }
        }
        return true
    }

    private func allExcluded(_ kind: ConfigScriptEventKind, by mask: ConfigScriptListenerMask?) -> Bool {
        guard let mask, let index = listeners.index(forKey: kind) else { return false }
        let registered = listeners.values[index]
        for position in registered.indices where !mask.contains(registered[position].index) { return false }
        return true
    }

    private func exclusions(
        _ kind: ConfigScriptEventKind, argument: borrowing ConfigScriptNativeEvent, controller: WMController
    ) -> ConfigScriptListenerMask? {
        if kind == .windowClose, let token = argument.windowToken {
            return feedback.closeExclusions(token: token)
        }
        var mask = feedback.exclusions(for: kind, controller: controller)
        if kind == .windowFullscreen,
           let cause = controller.workspaceManager.scriptWindowFullscreenObserver?.windowStates.confirmingFullscreen
        {
            mask = Self.combined(mask, cause.excludingSelf)
        }
        return mask
    }

    static func publishTitle(
        _ title: consuming ConfigScriptWindowTitle, in queue: inout ConfigScriptCallbackQueue?, controller: WMController
    ) {
        queue?.enqueueTitle(consume title, controller: controller)
    }

    func enqueueTitle(_ title: consuming ConfigScriptWindowTitle, controller: WMController) {
        if case .retired = state { return }
        let key = WindowStateKey.window(.windowTitle, title.token, title.epoch)
        let excluded = feedback.currentExclusions
        let trigger: Trigger
        if let excluded {
            trigger = .causedTitle(consume title, excluding: excluded)
        } else {
            trigger = .title(consume title)
        }
        let focus = controller.workspaceManager.configScriptFocusBaseline
        if storeWindowState(consume trigger, key: key, kind: .windowTitle, excluding: excluded, focus: focus) {
            wake(controller)
        }
    }

    private func storeWindowState(
        _ trigger: consuming Trigger, key: WindowStateKey, kind: ConfigScriptEventKind,
        excluding: ConfigScriptListenerMask?, focus: ConfigScriptFocusBaseline
    ) -> Bool {
        if let slot = pendingWindowStates[key] {
            work[slot]!.trigger = trigger
            work[slot]!.focus = focus
            return true
        }
        if let excluding, allExcluded(kind, by: excluding) { return false }
        guard pendingWindowStates.count < Self.windowStateCapacity else {
            missedWindowStates += 1
            work[lastWindowStateSlot]?.missed = missedWindowStates
            return false
        }
        let slot = append(Work(trigger: trigger, missed: missedWindowStates, focus: focus))
        lastWindowStateSlot = slot
        pendingWindowStates[key] = slot
        return true
    }

    func capture(
        reads: ConfigScriptReads, controller: WMController, focus: ConfigScriptFocusBaseline? = nil
    ) -> ConfigScriptCapture {
        let target = controller.configScriptTarget(focus: focus)
        let snapshot = reads.isEmpty ? nil : controller.configScriptSnapshot(
            reads: reads, target: target, pool: &snapshotPool
        )
        return ConfigScriptCapture(target: target, snapshot: snapshot)
    }

    private func eventCapture(
        _ kind: ConfigScriptEventKind, excluding functions: ConfigScriptListenerMask?, controller: WMController,
        focus: ConfigScriptFocusBaseline? = nil
    ) -> ConfigScriptCapture {
        guard let demand = eventReads?[kind] else { return capture(reads: [], controller: controller, focus: focus) }
        let reads = if let functions { demand.demand(excluding: functions) } else { demand.all }
        return capture(reads: reads, controller: controller, focus: focus)
    }

    @discardableResult
    private func append(_ next: consuming Work) -> Int {
        let slot = (head + pendingCount) % work.count
        work[slot] = next
        pendingCount += 1
        return slot
    }
}

extension ConfigScriptCallbackQueue {
    private func wake(_ controller: WMController?) {
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptLatencyTrace.mark(.enqueued)
        #endif
        switch state {
        case .working,
             .retired: return
        case .starting:
            if let controller { executionController = controller }
            state = .working
        case let .parked(continuation):
            if let controller { executionController = controller }
            state = .working
            continuation.resume()
        }
    }

    func activate(owner: ConfigScriptController, controller: WMController?) {
        precondition(worker == nil)
        executionController = controller
        worker = Task { [weak owner] in
            defer {
                self.worker = nil
                self.notifyParkWaiters()
            }
            var slot = InFlight()
            while !self.isRetired {
                if self.pendingCount == 0 {
                    await withUnsafeContinuation { self.park($0) }
                    continue
                }
                guard let owner, let controller = self.executionController else {
                    self.retire()
                    return
                }
                repeat {
                    guard var function = self.dequeue(into: &slot, controller: controller) else { continue }
                    let isEvent = slot.event != nil
                    repeat {
                        do throws(ConfigScriptError) {
                            let result: ConfigScriptInvocation
                            if let event = slot.nextEventArgument() {
                                result = try await self.generation.invoke(
                                    function: function, queuedEvent: consume event, missed: slot.missed,
                                    snapshot: slot.capture?.snapshot
                                )
                            } else {
                                result = try await self.generation.invoke(
                                    function: function, target: slot.capture!.target, snapshot: slot.capture?.snapshot
                                )
                            }
                            if let commands = (consume result).batch {
                                let cause = isEvent ? slot.cause : nil
                                try await self.apply(
                                    commands, target: slot.capture!.target, cause: cause, controller: controller,
                                    owner: owner
                                )
                            }
                        } catch {
                            self.report(error, to: owner)
                        }
                        guard let next = slot.nextListener(), !Task.isCancelled else { break }
                        function = next
                    } while true
                    self.finish(&slot, isEvent: isEvent)
                } while self.pendingCount != 0 && !self.isRetired
            }
        }
    }

    private func park(_ continuation: UnsafeContinuation<Void, Never>) {
        guard pendingCount == 0, !isRetired else {
            continuation.resume()
            return
        }
        state = .parked(continuation)
        notifyParkWaiters()
    }

    private func finish(_ slot: inout InFlight, isEvent: Bool) {
        if !isEvent {
            outstandingPresses -= 1
            slot.capture = nil
        } else {
            slot.event = nil
            slot.capture = nil
            if slot.excluded != nil { slot.excluded = nil }
            if slot.listeners != nil { slot.listeners = nil }
        }
    }

    func retire() {
        if case .retired = state { return }
        let previous = state
        state = .retired
        worker?.cancel()
        if case let .parked(continuation) = previous { continuation.resume() }
        work.removeAll()
        snapshotPool = ConfigScriptSnapshotPool()
        pendingEvents.removeAll()
        pendingWindowStates.removeAll()
        feedback = ConfigScriptEventFeedback()
        pendingCount = 0
    }

    private func dequeue(into slot: inout InFlight, controller: WMController) -> Int? {
        #if OMNIWM_SCRIPT_ARC_AUDIT
            script_arc_check_dequeue()
        #endif
        let next = work[head].take()!
        head = (head + 1) % work.count
        pendingCount -= 1
        slot.missed = next.missed
        let focus = next.focus
        switch (consume next).trigger {
        case let .function(id, capture):
            slot.capture = consume capture
            return id
        case let .title(title):
            pendingWindowStates.removeValue(forKey: .window(.windowTitle, title.token, title.epoch))
            slot.event = .title(consume title)
            return prepareEvent(.windowTitle, capture: nil, focus: focus, into: &slot, controller: controller)
        case let .causedTitle(title, excluded):
            pendingWindowStates.removeValue(forKey: .window(.windowTitle, title.token, title.epoch))
            slot.event = .title(consume title)
            slot.excluded = excluded
            return prepareEvent(.windowTitle, capture: nil, focus: focus, into: &slot, controller: controller)
        case let .event(kind, payload, excluded, queuedCapture):
            switch kind.delivery {
            case .edge: pendingEdges -= 1
            case .latest: pendingEvents.removeValue(forKey: kind)
            case .latestPerWindow:
                if let key = Self.windowKey(kind, payload) { pendingWindowStates.removeValue(forKey: key) }
            }
            var payload = consume payload
            payload.attachCapturedSession(queuedCapture!.target.sessionID)
            slot.event = .native(consume payload)
            slot.excluded = excluded
            return prepareEvent(kind, capture: queuedCapture, focus: focus, into: &slot, controller: controller)
        }
    }

    private func prepareEvent(
        _ kind: ConfigScriptEventKind, capture: ConfigScriptCapture?, focus: ConfigScriptFocusBaseline?,
        into slot: inout InFlight, controller: WMController
    ) -> Int? {
        let function: Int
        if let handlers = listeners[kind] {
            var index = handlers.startIndex
            while index < handlers.endIndex, slot.excluded?.contains(handlers[index].index) == true {
                handlers.formIndex(after: &index)
            }
            guard index < handlers.endIndex else {
                slot = InFlight()
                return nil
            }
            function = handlers[index].function
            slot.listenerIndex = handlers[index].index
            handlers.formIndex(after: &index)
            if index < handlers.endIndex { slot.listeners = handlers[index...] }
        } else {
            slot = InFlight()
            return nil
        }
        slot.capture = capture ?? eventCapture(kind, excluding: slot.excluded, controller: controller, focus: focus)
        return function
    }
}
