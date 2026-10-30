// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Metal
import QuartzCore
import Synchronization

final class ShellGroupEffectTiming: Sendable {
    struct Sample: Sendable {
        var start: CFTimeInterval = 0
        var end: CFTimeInterval = 0
        var failure: String?
    }

    private struct State {
        var pending = 2
        var sample = Sample()
        var completion: (@Sendable (Sample) -> Void)?
    }

    private let state = Mutex(State())
    private let lease: ShellGroupEffectBudget.Lease

    init(lease: ShellGroupEffectBudget.Lease) {
        self.lease = lease
    }

    func record(_ buffer: any MTLCommandBuffer, start: Bool) {
        let finished = state.withLock { value -> ((@Sendable (Sample) -> Void), Sample)? in
            if start { value.sample.start = buffer.gpuStartTime }
            else { value.sample.end = buffer.gpuEndTime }
            if buffer.status == .error {
                value.sample.failure = buffer.error?.localizedDescription ?? "the GPU reported an error"
            }
            value.pending -= 1
            guard value.pending == 0, let completion = value.completion else { return nil }
            value.completion = nil
            return (completion, value.sample)
        }
        if let (completion, sample) = finished { completion(sample) }
    }

    func finish(_ completion: @escaping @Sendable (Sample) -> Void) {
        let sample = state.withLock { value -> Sample? in
            guard value.pending > 0 else { return value.sample }
            value.completion = completion
            return nil
        }
        if let sample { completion(sample) }
    }
}
