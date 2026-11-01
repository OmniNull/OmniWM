// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class AXManagedWindowBindings {
    var onManagedWindowBindingFailed: ((pid_t) -> Void)?
    var managedWindowBindingRetryDelayProvider: (Int) -> Duration? = {
        AXManager.managedWindowBindingRetryDelay(afterFailure: $0)
    }

    private struct ManagedWindowBindingRetryState {
        let generation: UInt64
        var failures: Int
        var task: Task<Void, Never>?
    }

    private var nextManagedWindowBindingGeneration: UInt64 = 1
    private var managedWindowBindingRetryStateByPID: [pid_t: ManagedWindowBindingRetryState] = [:]

    func bindManagedWindows(_ entries: [WindowState]) {
        let windowsByPID = managedWindowsByPID(entries)
        for (pid, windows) in windowsByPID {
            submitManagedWindowBindings(
                pid: pid,
                windows: windows,
                authoritative: false,
                resetsRetryBudget: true
            )
        }
    }

    func reconcileManagedWindowBindings(
        _ entries: [WindowState],
        scopedPIDs: Set<pid_t>? = nil
    ) {
        let windowsByPID = managedWindowsByPID(entries, includedPIDs: scopedPIDs)
        let contextPIDs = Set(AppAXContextRegistry.contexts.keys)
        if scopedPIDs == nil {
            for pid in Set(managedWindowBindingRetryStateByPID.keys)
                where !contextPIDs.contains(pid) && windowsByPID[pid] == nil
            {
                clearManagedWindowBindingRetry(for: pid)
            }
        }
        let bindingPIDs = AXManager.managedWindowBindingPIDs(
            contextPIDs: contextPIDs,
            windowPIDs: Set(windowsByPID.keys),
            scopedPIDs: scopedPIDs
        )
        for pid in bindingPIDs {
            let windows = windowsByPID[pid] ?? [:]
            AppAXContextRegistry.contexts[pid]?.retainFrameState(only: Set(windows.keys))
            submitManagedWindowBindings(
                pid: pid,
                windows: windows,
                authoritative: true,
                resetsRetryBudget: false
            )
        }
    }

    func pendingManagedWindowBindingRetryPIDs(
        intersecting pids: Set<pid_t>
    ) -> Set<pid_t> {
        Set(managedWindowBindingRetryStateByPID.keys).intersection(pids)
    }

    private func managedWindowsByPID(
        _ entries: [WindowState],
        includedPIDs: Set<pid_t>? = nil
    ) -> [pid_t: [Int: AXWindowRef]] {
        var windowsByPID: [pid_t: [Int: AXWindowRef]] = [:]
        windowsByPID.reserveCapacity(min(entries.count, 8))
        for entry in entries where includedPIDs?.contains(entry.pid) ?? true {
            guard let axRef = entry.axRef else { continue }
            windowsByPID[entry.pid, default: [:]][entry.windowId] = axRef
        }
        return windowsByPID
    }

    private func submitManagedWindowBindings(
        pid: pid_t,
        windows: [Int: AXWindowRef],
        authoritative: Bool,
        resetsRetryBudget: Bool
    ) {
        let previousState = managedWindowBindingRetryStateByPID[pid]
        previousState?.task?.cancel()
        let generation = nextManagedWindowBindingGeneration
        nextManagedWindowBindingGeneration &+= 1
        managedWindowBindingRetryStateByPID[pid] = .init(
            generation: generation,
            failures: resetsRetryBudget ? 0 : previousState?.failures ?? 0,
            task: nil
        )
        guard let context = AppAXContextRegistry.contexts[pid] else {
            handleManagedWindowBindingResult(.retryRequired, pid: pid, generation: generation)
            return
        }
        let completion: @MainActor @Sendable (AppAXWindowBindingResult) -> Void = { [weak self] in
            self?.handleManagedWindowBindingResult($0, pid: pid, generation: generation)
        }
        if authoritative {
            context.reconcileWindowBindings(windows, timeoutSeconds: AXManager.perAppTimeout, completion: completion)
        } else {
            context.bindWindows(windows, timeoutSeconds: AXManager.perAppTimeout, completion: completion)
        }
    }

    private func handleManagedWindowBindingResult(
        _ result: AppAXWindowBindingResult,
        pid: pid_t,
        generation: UInt64
    ) {
        guard var state = managedWindowBindingRetryStateByPID[pid],
              state.generation == generation
        else { return }
        guard case .retryRequired = result else {
            clearManagedWindowBindingRetry(for: pid)
            return
        }
        state.failures += 1
        guard let delay = managedWindowBindingRetryDelayProvider(state.failures) else {
            managedWindowBindingRetryStateByPID[pid] = state
            return
        }
        state.task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  var state = self.managedWindowBindingRetryStateByPID[pid],
                  state.generation == generation
            else { return }
            state.task = nil
            self.managedWindowBindingRetryStateByPID[pid] = state
            self.onManagedWindowBindingFailed?(pid)
        }
        managedWindowBindingRetryStateByPID[pid] = state
    }

    func clearManagedWindowBindingRetry(for pid: pid_t) {
        managedWindowBindingRetryStateByPID.removeValue(forKey: pid)?.task?.cancel()
    }

    func shutdown() {
        for state in managedWindowBindingRetryStateByPID.values {
            state.task?.cancel()
        }
        managedWindowBindingRetryStateByPID.removeAll()
    }
}
