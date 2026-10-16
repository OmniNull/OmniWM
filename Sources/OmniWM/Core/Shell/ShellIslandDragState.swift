// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Synchronization

struct ShellIslandDragState: Equatable, Sendable {
    var active = false
    var types: ShellDropTypes = []

    func write(to writer: inout ShellValueWriter) {
        writer.map(2)
        writer.key("active")
        writer.bool(active)
        writer.key("types")
        let names: [(ShellDropTypes, String)] = [(.file, "file"), (.url, "url"), (.text, "text"), (.image, "image")]
        writer.array(names.reduce(0) { $0 + (types.contains($1.0) ? 1 : 0) })
        for (type, name) in names where types.contains(type) { writer.string(name) }
    }
}

struct ShellIslandDragReducer {
    private(set) var state = ShellIslandDragState()
    private(set) var changeCount: Int
    private var baseline: Int
    private var offered: ShellDropTypes = []

    init(changeCount: Int) {
        self.changeCount = changeCount
        baseline = changeCount
    }

    mutating func reset(changeCount: Int) {
        self.changeCount = changeCount
        baseline = changeCount
        offered = []
        state = ShellIslandDragState()
    }

    mutating func drag(changeCount: Int, types: () -> ShellDropTypes) {
        guard changeCount != baseline else { return }
        if self.changeCount != changeCount {
            self.changeCount = changeCount
            offered = types()
        }
        state = ShellIslandDragState(active: !offered.isEmpty, types: offered)
    }
}

final class ShellIslandDragInbox: Sendable {
    enum Event: Sendable {
        case dragged
        case began
        case ended
    }

    struct Batch: Equatable, Sendable {
        var began = false
        var ended = false
        var dragged = false
    }

    private struct State {
        var pending: Batch?
        var waking = false
        var closed = false
    }

    private let storage = Mutex(State())
    private let wake: @Sendable (ShellIslandDragInbox) -> Void

    init(wake: @escaping @Sendable (ShellIslandDragInbox) -> Void) {
        self.wake = wake
    }

    func post(_ event: Event) {
        let notify = storage.withLock { state in
            guard !state.closed else { return false }
            var batch = state.pending ?? Batch()
            switch event {
            case .dragged: batch.dragged = true
            case .began: batch.began = true
                batch.dragged = false
            case .ended: batch.ended = true
                batch.dragged = false
            }
            state.pending = batch
            guard !state.waking else { return false }
            state.waking = true
            return true
        }
        if notify { wake(self) }
    }

    func take() -> Batch? {
        storage.withLock { state in
            let batch = state.pending
            state.pending = nil
            return batch
        }
    }

    func finish() {
        let notify = storage.withLock { state in
            guard !state.closed, state.pending != nil else { state.waking = false
                return false
            }
            return true
        }
        if notify { wake(self) }
    }

    func close() {
        storage.withLock { state in
            state.closed = true
            state.pending = nil
        }
    }
}
