// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

struct ConfigScriptTimer: Sendable {
    let bit: UInt32
    let reference: UInt32
    let interval: Duration
    let repeats: Bool
    var reads: ConfigScriptReads = []

    static func declarations(in resident: OpaquePointer, cancelled: UInt32) -> [Self] {
        var count = 0
        let items = omni_config_timers(resident, &count)
        return UnsafeBufferPointer(start: items, count: count).enumerated().compactMap { index, timer in
            let bit = UInt32(1) << index
            guard cancelled & bit == 0 else { return nil }
            return Self(
                bit: bit,
                reference: timer.callback_id,
                interval: .seconds(timer.seconds),
                repeats: timer.repeats, reads: ConfigScriptReads(rawValue: timer.reads)
            )
        }
    }
}

struct ConfigScriptTimerWorkers {
    var jobs: [(bit: UInt32, task: Task<Void, Never>)] = []
    var cancelled: UInt32 = 0
    var firing: UInt32 = 0

    mutating func cancel(mask: UInt32) {
        cancelled |= mask
        for job in jobs where mask & ~firing & job.bit != 0 { job.task.cancel() }
    }
}

typealias ConfigScriptTimerSleep = @Sendable (Duration) async throws -> Void
typealias ConfigScriptTimerCapture = @MainActor @Sendable (ConfigScriptReads) -> ConfigScriptCapture?
typealias ConfigScriptTimerDelivery = @MainActor @Sendable (
    Result<ConfigScriptInvocation, ConfigScriptError>, ConfigScriptTarget?
) async -> Void

extension ConfigScriptGeneration {
    func runTimers(
        _ declarations: [ConfigScriptTimer], sleep: @escaping ConfigScriptTimerSleep,
        capture: @escaping ConfigScriptTimerCapture = { _ in nil },
        deliver: @escaping ConfigScriptTimerDelivery
    ) async {
        guard !Task.isCancelled else { return }
        let jobs = declarations.map { timer in
            let task = Task { await runTimer(timer, sleep: sleep, capture: capture, deliver: deliver) }
            return (bit: timer.bit, task: task)
        }
        timerWorkers.jobs = jobs
        await withTaskCancellationHandler {
            for job in jobs { await job.task.value }
        } onCancel: {
            for job in jobs { job.task.cancel() }
        }
        timerWorkers.jobs.removeAll()
        releaseFinishedTimerVM()
    }

    private func runTimer(
        _ timer: ConfigScriptTimer, sleep: ConfigScriptTimerSleep, capture: ConfigScriptTimerCapture,
        deliver: ConfigScriptTimerDelivery
    ) async {
        while timerWorkers.cancelled & timer.bit == 0, !Task.isCancelled {
            do { try await sleep(timer.interval) } catch { return }
            guard timerWorkers.cancelled & timer.bit == 0, !Task.isCancelled else { return }
            let trigger: ConfigScriptCapture?
            if timer.reads.isEmpty {
                trigger = nil
            } else {
                guard let current = await capture(timer.reads), timerWorkers.cancelled & timer.bit == 0,
                      !Task.isCancelled else { return }
                trigger = current
            }
            timerWorkers.firing |= timer.bit
            do {
                let invocation = if let trigger {
                    try invoke(
                        reference: timer.reference,
                        input: .context(trigger.target.context),
                        snapshot: trigger.snapshot
                    )
                } else {
                    try invoke(reference: timer.reference, input: .timer)
                }
                if !invocation.commands.isEmpty { await deliver(.success(invocation), trigger?.target) }
            } catch {
                await deliver(.failure(error), trigger?.target)
            }
            timerWorkers.firing &= ~timer.bit
            if !timer.repeats { return }
        }
    }
}
