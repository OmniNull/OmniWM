// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Synchronization

final class ShellCaptureRequest: Sendable {
    enum Action: Equatable, Sendable {
        case begin(joined: Bool)
        case end(retired: Bool)

        var isBegin: Bool {
            if case .begin = self { return true }
            return false
        }
    }

    private struct State {
        var result: Bool?
        var waiters: [CheckedContinuation<Bool, Never>] = []
    }

    let context: ShellFrameTraceContext
    let action: Action
    let serviceGeneration: UInt64
    private let state = Mutex(State())

    init(context: ShellFrameTraceContext, action: Action, serviceGeneration: UInt64) {
        self.context = context
        self.action = action
        self.serviceGeneration = serviceGeneration
    }

    var result: Bool? {
        state.withLock { $0.result }
    }

    func wait() async -> Bool {
        await withCheckedContinuation { waiter in
            let result = state.withLock { state -> Bool? in
                if let result = state.result { return result }
                state.waiters.append(waiter)
                return nil
            }
            if let result { waiter.resume(returning: result) }
        }
    }

    func finish(_ result: Bool) {
        let waiters: [CheckedContinuation<Bool, Never>]? = state.withLock { state in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        guard let waiters else { return }
        if !result {
            ShellFrameTrace.shared.record(.init(
                event: .counters,
                context: context,
                status: 1,
                detail: "scope=package service_generation=\(serviceGeneration) available=false incomplete=true boundary=\(action.isBegin ? "begin" : "end")"
            ))
        }
        for waiter in waiters { waiter.resume(returning: result) }
    }
}

final class ShellCapturePort: Sendable {
    private struct State {
        var mailbox: AsyncStream<ShellWidgetMessage>.Continuation?
        var closed = false
        var begin: ShellCaptureRequest?
        var end: ShellCaptureRequest?
    }

    private let state = Mutex(State())
    private let serviceGeneration: UInt64

    init(serviceGeneration: UInt64) {
        self.serviceGeneration = serviceGeneration
    }

    var context: ShellFrameTraceContext? {
        state.withLock { state in
            guard !state.closed, state.end?.result == nil else { return nil }
            return state.begin?.context
        }
    }

    func attach(_ mailbox: AsyncStream<ShellWidgetMessage>.Continuation) {
        state.withLock { state in
            if !state.closed, state.mailbox == nil { state.mailbox = mailbox }
        }
    }

    func request(_ context: ShellFrameTraceContext, _ action: ShellCaptureRequest.Action) -> ShellCaptureRequest {
        let next = ShellCaptureRequest(context: context, action: action, serviceGeneration: serviceGeneration)
        let dispatch = state.withLock { state -> (ShellCaptureRequest, AsyncStream<ShellWidgetMessage>.Continuation?) in
            let existing = action.isBegin ? state.begin : state.end
            if let existing, existing.context.capture == context.capture { return (existing, nil) }
            guard !state.closed, let mailbox = state.mailbox else { return (next, nil) }
            if action.isBegin {
                guard state.begin == nil || state.end?.result != nil else { return (next, nil) }
                state.begin = next
                state.end = nil
            } else {
                guard state.begin?.context.capture == context.capture else { return (next, nil) }
                state.end = next
            }
            return (next, mailbox)
        }
        guard dispatch.0 === next else { return dispatch.0 }
        guard let mailbox = dispatch.1 else { next.finish(false)
            return next
        }
        switch mailbox.yield(.capture(next)) {
        case .enqueued: break
        case .terminated: next.finish(false)
        case let .dropped(message):
            if case let .capture(request) = message { request.finish(false) }
        @unknown default: next.finish(false)
        }
        return next
    }

    func close(completedCapture: UInt64) {
        let requests = state.withLock { state in
            state.closed = true
            state.mailbox = nil
            let requests = [state.begin, state.end].compactMap { $0 }
            state.begin = nil
            state.end = nil
            return requests
        }
        for request in requests { request.finish(completedCapture != 0 && request.context.capture == completedCapture) }
    }
}
