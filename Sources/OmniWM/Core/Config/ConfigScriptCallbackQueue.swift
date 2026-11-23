// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

@MainActor
final class ConfigScriptCallbackQueue {
    static let capacity = 8
    static let edgeCapacity = Int(OMNI_CONFIG_COMMAND_LIMIT)
    static let windowStateCapacity = Int(OMNI_CONFIG_COMMAND_LIMIT)

    private struct WindowStateKey: Hashable {
        let kind: ConfigScriptEventKind
        let id: String
    }

    struct Declaration {
        let source: String
        let line: Int
        let reads: ConfigScriptReads
    }

    private struct EventReads {
        var all: ConfigScriptReads = []
        var readers: [(function: Int, reads: ConfigScriptReads)] = []

        func demand(excluding functions: Set<Int>) -> ConfigScriptReads {
            if functions.isEmpty { return all }
            var demand: ConfigScriptReads = []
            for reader in readers where !functions.contains(reader.function) { demand.formUnion(reader.reads) }
            return demand
        }
    }

    private enum Trigger {
        case function(Int, ConfigScriptCapture)
        case event(ConfigScriptEventKind, ConfigScriptEventPayload, excluding: Set<Int>, capture: ConfigScriptCapture?)
    }

    private struct Work {
        let trigger: Trigger
        var missed: UInt64 = 0
    }

    let generation: ConfigScriptGeneration
    let declarations: [Int: Declaration]
    private let listeners: [ConfigScriptEventKind: [Int]]
    private let eventReads: [ConfigScriptEventKind: EventReads]?
    private var work: [Work?]
    private var pendingEvents: [ConfigScriptEventKind: Int] = [:]
    private var pendingWindowStates: [WindowStateKey: Int] = [:]
    private var lastWindowStateSlot = 0
    private var missedWindowStates: UInt64 = 0
    private var feedback = ConfigScriptEventFeedback()
    private var head = 0
    private var pendingCount = 0
    private var pendingEdges = 0
    private var lastEdgeSlot = 0
    private var missedEdges: UInt64 = 0
    private var outstandingPresses = 0
    private(set) var worker: Task<Void, Never>?

    init(
        generation: ConfigScriptGeneration, bindings: [ConfigScriptBinding], commands: [ConfigScriptNamedCommand],
        events: [ConfigScriptEventListener]
    ) {
        self.generation = generation
        var sites: [Int: Declaration] = [:]
        for row in bindings {
            if case let .configFunction(function) = row.command {
                sites[function] = Declaration(source: row.source, line: row.line, reads: row.reads)
            }
        }
        for row in commands { sites[row.function] = Declaration(source: row.source, line: row.line, reads: row.reads) }
        declarations = sites
        var listeners: [ConfigScriptEventKind: [Int]] = [:]
        var demands: [ConfigScriptEventKind: EventReads] = [:]
        for row in events {
            listeners[row.kind, default: []].append(row.function)
            if !row.reads.isEmpty {
                demands[row.kind, default: EventReads()].all.formUnion(row.reads)
                demands[row.kind, default: EventReads()].readers.append((row.function, row.reads))
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

    var hasCapacity: Bool {
        outstandingPresses < Self.capacity
    }

    func enqueue(function: Int, reads: ConfigScriptReads, controller: WMController, owner: ConfigScriptController) {
        outstandingPresses += 1
        append(Work(trigger: .function(function, controller.configScriptCapture(reads: reads))))
        startWorker(controller: controller, owner: owner)
    }

    func enqueue(
        event: ConfigScriptEventKind, payload: ConfigScriptEventPayload,
        controller: WMController, owner: ConfigScriptController
    ) {
        var excluded = event == .windowClose
            ? feedback.closeExclusions(id: payload.id, controller: controller)
            : feedback.exclusions(for: event, controller: controller)
        if event == .windowFullscreen,
           let cause = controller.workspaceManager.scriptWindowFullscreenObserver?.windowStates.confirmingFullscreen
        {
            excluded.formUnion(cause.ancestors)
            excluded.insert(cause.function)
        }
        switch event.delivery {
        case .edge:
            if !excluded.isEmpty, let handlers = listeners[event], handlers.allSatisfy(excluded.contains) { return }
            guard pendingEdges < Self.edgeCapacity else {
                missedEdges += 1
                work[lastEdgeSlot]?.missed = missedEdges
                return
            }
            let capture = eventCapture(event, excluding: excluded, controller: controller)
            lastEdgeSlot = append(Work(
                trigger: .event(event, payload, excluding: excluded, capture: capture),
                missed: missedEdges
            ))
            pendingEdges += 1
        case .latest:
            let slot = pendingEvents[event]
            if slot == nil, !excluded.isEmpty, let handlers = listeners[event], handlers.allSatisfy(excluded.contains) {
                return
            }
            let next = Work(trigger: .event(event, payload, excluding: excluded, capture: nil))
            if let slot {
                work[slot] = next
            } else {
                pendingEvents[event] = append(next)
            }
        case .latestPerWindow:
            guard enqueueWindowState(event, payload: payload, excluded: excluded)
            else { return }
        }
        startWorker(controller: controller, owner: owner)
    }

    private func enqueueWindowState(
        _ kind: ConfigScriptEventKind, payload: ConfigScriptEventPayload, excluded: Set<Int>
    ) -> Bool {
        guard let id = payload.id else { return false }
        let key = WindowStateKey(kind: kind, id: id)
        let slot = pendingWindowStates[key]
        if slot == nil {
            if !excluded.isEmpty, let handlers = listeners[kind],
               handlers.allSatisfy(excluded.contains) { return false }
            guard pendingWindowStates.count < Self.windowStateCapacity else {
                missedWindowStates += 1
                work[lastWindowStateSlot]?.missed = missedWindowStates
                return false
            }
        }
        let next = Work(
            trigger: .event(kind, payload, excluding: excluded, capture: nil),
            missed: slot.flatMap { work[$0]?.missed } ?? missedWindowStates
        )
        if let slot {
            work[slot] = next
        } else {
            lastWindowStateSlot = append(next)
            pendingWindowStates[key] = lastWindowStateSlot
        }
        return true
    }

    private func eventCapture(
        _ kind: ConfigScriptEventKind, excluding functions: Set<Int>, controller: WMController
    ) -> ConfigScriptCapture {
        controller.configScriptCapture(reads: eventReads?[kind]?.demand(excluding: functions) ?? [])
    }

    @discardableResult
    private func append(_ next: consuming Work) -> Int {
        let slot = (head + pendingCount) % work.count
        work[slot] = next
        pendingCount += 1
        return slot
    }

    private func startWorker(controller: WMController, owner: ConfigScriptController) {
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptLatencyTrace.mark(.enqueued)
        #endif
        guard worker == nil else { return }
        worker = Task { [weak controller, weak owner] in
            defer { self.worker = nil }
            guard let controller, let owner else { return }
            await self.drain(controller: controller, owner: owner)
        }
    }

    func retire() {
        worker?.cancel()
        work.removeAll()
        pendingEvents.removeAll()
        pendingWindowStates.removeAll()
        feedback = ConfigScriptEventFeedback()
        pendingCount = 0
    }

    private func drain(controller: WMController, owner: ConfigScriptController) async {
        while pendingCount > 0, !Task.isCancelled, let next = work[head].take() {
            head = (head + 1) % work.count
            pendingCount -= 1
            switch next.trigger {
            case let .function(id, capture):
                await invoke(id, work: next, capture: capture, controller: controller, owner: owner)
                outstandingPresses -= 1
            case let .event(kind, payload, excluded, queuedCapture):
                switch kind.delivery {
                case .edge: pendingEdges -= 1
                case .latest: pendingEvents.removeValue(forKey: kind)
                case .latestPerWindow:
                    if let id = payload
                        .id { pendingWindowStates.removeValue(forKey: WindowStateKey(kind: kind, id: id)) }
                }
                guard let handlers = listeners[kind],
                      excluded.isEmpty || !handlers.allSatisfy(excluded.contains) else { continue }
                let capture = queuedCapture ?? eventCapture(kind, excluding: excluded, controller: controller)
                for id in handlers where !excluded.contains(id) {
                    guard !Task.isCancelled else { return }
                    await invoke(id, work: next, capture: capture, controller: controller, owner: owner)
                }
            }
        }
    }

    private func invoke(
        _ function: Int, work: Work, capture: ConfigScriptCapture, controller: WMController,
        owner: ConfigScriptController
    ) async {
        do throws(ConfigScriptError) {
            let cause: ConfigScriptEventCause?
            let result: ConfigScriptInvocation
            switch work.trigger {
            case .function:
                cause = nil
                result = try await generation.invoke(
                    function: function, target: capture.target, snapshot: capture.snapshot
                )
            case let .event(_, event, excluded, _):
                cause = ConfigScriptEventCause(function: function, ancestors: excluded)
                result = try await generation.invoke(
                    function: function, event: event, missed: work.missed, snapshot: capture.snapshot
                )
            }
            try await apply(result, target: capture.target, cause: cause, controller: controller, owner: owner)
        } catch {
            guard !Task.isCancelled, owner.callbackQueue === self else { return }
            owner.reportCallbackError(error)
        }
    }
}

extension ConfigScriptCallbackQueue {
    func applyTimer(
        _ result: Result<ConfigScriptInvocation, ConfigScriptError>, target: ConfigScriptTarget?,
        controller: WMController,
        owner: ConfigScriptController
    ) async {
        do throws(ConfigScriptError) {
            let invocation = try result.get()
            try await apply(
                invocation,
                target: target ?? controller.configScriptTarget(),
                cause: nil,
                controller: controller,
                owner: owner
            )
        } catch {
            guard !Task.isCancelled, owner.callbackQueue === self else { return }
            owner.reportCallbackError(error)
        }
    }

    private func apply(
        _ result: ConfigScriptInvocation, target: ConfigScriptTarget, cause: ConfigScriptEventCause?,
        controller: WMController, owner: ConfigScriptController
    ) async throws(ConfigScriptError) {
        for dispatch in result.commands {
            guard !Task.isCancelled, owner.callbackQueue === self else { return }
            if let cause { try feedback.checkLaunch(dispatch, from: cause.function) }
            let outcome: ExternalCommandResult
            if case let .native(.runProgram(arguments)) = dispatch.operation {
                do {
                    outcome = try await controller.startConfigScriptProgram(arguments, target: target)
                } catch {
                    throw ConfigScriptError(
                        line: dispatch.line, message: error.localizedDescription, source: dispatch.source
                    )
                }
            } else if let cause {
                outcome = performEventCommand(
                    dispatch.operation,
                    target: target,
                    cause: cause,
                    controller: controller
                )
            } else {
                outcome = controller.performConfigScriptDispatch(dispatch.operation, target: target)
            }
            guard outcome == .executed || outcome == .noChange else {
                throw ConfigScriptError(
                    line: dispatch.line, message: "\(dispatch.displayName): \(outcome).",
                    source: dispatch.source
                )
            }
        }
    }

    private func performEventCommand(
        _ operation: borrowing ConfigScriptDispatch.Operation, target: ConfigScriptTarget,
        cause: ConfigScriptEventCause, controller: WMController
    ) -> ExternalCommandResult {
        feedback.begin(cause, controller: controller)
        let manager = controller.workspaceManager
        let closing: WindowHandle? = if listeners[.windowClose] != nil {
            switch operation {
            case .native(.windowState(.close)): target.token.flatMap { manager.handle(for: $0) }
            case let .window(window) where window.request.name == .close: manager.handle(for: window.token)
            default: nil
            }
        } else { nil }
        let fullscreen: ConfigScriptEventObservers? = switch operation {
        case .native(.fullscreen(.native)): manager.scriptWindowFullscreenObserver
        default: nil
        }
        let priorGeneration = fullscreen.map { _ in manager.nativeFullscreenTransitionGenerationCounter }
        let outcome = controller.performConfigScriptDispatch(operation, target: target)
        if let fullscreen, let priorGeneration, outcome == .executed {
            fullscreen.recordFullscreenRequest(
                for: target.token, since: priorGeneration, cause: cause, manager: manager
            )
        }
        if let closing { feedback.recordClose(closing, outcome: outcome, controller: controller) }
        feedback.end(controller: controller)
        return outcome
    }
}
