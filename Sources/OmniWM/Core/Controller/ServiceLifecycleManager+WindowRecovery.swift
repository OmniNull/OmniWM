// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
struct StopRecoveryOperations {
    var hasContext: @MainActor @Sendable (pid_t) -> Bool = { AppAXContextRegistry.contexts[$0] != nil }
    var reveal: @MainActor @Sendable (pid_t, TimeInterval) async -> Bool = { pid, deadline in
        await StopApplicationReveal(pid: pid).reveal(deadline: deadline)
    }

    var restore: @MainActor @Sendable (StopWindowTarget, TimeInterval) async
        -> StopWindowOutcome = { target, deadline in
            guard let context = AppAXContextRegistry.contexts[target.token.pid] else {
                return StopWindowOutcome(target: target, failure: "AX context unavailable")
            }
            return await context.restoreForStop(target, deadline: deadline)
        }
}

extension ServiceLifecycleManager {
    func stopWindowTargets() -> [StopWindowTarget] {
        guard let controller else { return [] }
        let manager = controller.workspaceManager
        return manager.allEntries().compactMap { entry in
            guard let axRef = entry.axRef,
                  entry.layoutReason != .nativeFullscreen,
                  manager.nativeFullscreenRecord(for: entry.token) == nil,
                  !manager.spaceTopology.isWindowOnFullscreenSpace(entry.windowId),
                  !manager.spaceTopology.isWindowOnKnownInactiveSpace(entry.windowId)
            else { return nil }
            let reveal = controller.layoutRefreshController.pendingRevealTransaction(for: entry.windowId)
            let hidden = entry.hiddenState ?? reveal?.hiddenState
            let frame = controller.layoutRefreshController.fastFrame(for: entry.token, axRef: axRef)
            let offscreen = frame.map { !StopWindowGeometry.isOnscreen($0, monitors: manager.monitors) } ?? false
            let parkedByOmniWM = hidden != nil || reveal != nil
                || controller.axManager.pendingParkWindowIds.contains(entry.windowId)
                || controller.axManager.verifiedParkFrame(for: entry.windowId) != nil
            guard parkedByOmniWM || offscreen && !entry.observedState.isNativeWithdrawn else { return nil }
            let monitor = manager.monitor(for: entry.workspaceId)
                ?? (hidden?.referenceMonitorId ?? entry.floatingState?.referenceMonitorId)
                .flatMap { manager.monitor(byId: $0) }
                ?? manager.monitors.first(where: \.isMain) ?? manager.monitors.first
            let placement = StopWindowGeometry.placement(
                floating: entry.mode == .floating ? entry.floatingState : nil,
                hidden: hidden, monitor: monitor, fallbackFrame: reveal?.targetFrame
            )
            return StopWindowTarget(
                token: entry.token,
                window: axRef,
                visibleFrame: monitor?.visibleFrame,
                placement: placement
            )
        }
    }

    func recoverStopWindows(
        _ targets: [StopWindowTarget],
        deadline: TimeInterval,
        operations: StopRecoveryOperations = StopRecoveryOperations()
    ) async {
        let applications = Dictionary(grouping: targets, by: { $0.token.pid })
        let failures = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for (pid, windows) in applications {
                group.addTask {
                    await self.recoverStopApplication(pid, windows: windows, deadline: deadline, operations: operations)
                }
            }
            var failures = 0
            for await count in group { failures += count }
            return failures
        }
        Log.ax
            .notice(
                "Stop restoration: candidates=\(targets.count) restored=\(targets.count - failures) failed=\(failures)"
            )
    }

    private func recoverStopApplication(
        _ pid: pid_t, windows: [StopWindowTarget], deadline: TimeInterval, operations: StopRecoveryOperations
    ) async -> Int {
        guard await operations.reveal(pid, deadline) else {
            return recordStopFailures(windows, reason: "native app unhide refused, unavailable, or deadline exceeded")
        }
        controller?.workspaceManager.setAppHidden(false, pid: pid, source: .service)
        guard operations.hasContext(pid) else {
            return recordStopFailures(windows, reason: "AX context unavailable")
        }
        var failures = 0
        for target in windows {
            let outcome = await operations.restore(target, deadline)
            reconcileStopOutcome(outcome)
            if let failure = outcome.failure { failures += recordStopFailures([target], reason: failure) }
        }
        return failures
    }

    func reconcileStopOutcome(_ outcome: StopWindowOutcome) {
        guard let controller, let entry = controller.workspaceManager.entry(for: outcome.target.token),
              let axRef = entry.axRef,
              sameAXWindowIdentity(axRef, outcome.target.window)
        else { return }
        if let minimized = outcome.confirmedMinimized {
            controller.workspaceManager.setWindowMinimized(minimized, token: entry.token, source: .service)
        }
        if outcome.failure == nil, outcome.frame != nil {
            controller.workspaceManager.setHiddenState(nil, for: entry.token)
            controller.axManager.markWindowActive(entry.windowId)
        }
    }

    private func recordStopFailures(_ targets: [StopWindowTarget], reason: String) -> Int {
        for target in targets {
            Log.ax
                .error(
                    "Stop restoration failed: pid=\(target.token.pid) window=\(target.token.windowId) reason=\(reason)"
                )
        }
        return targets.count
    }
}
