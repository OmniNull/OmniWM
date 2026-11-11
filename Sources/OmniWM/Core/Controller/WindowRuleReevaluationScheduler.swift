// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
final class WindowRuleReevaluationScheduler {
    private weak var controller: WMController?
    private var pendingWindowRuleReevaluationTask: Task<Void, Never>?
    private(set) var pendingWindowRuleReevaluationTargets: Set<WindowRuleReevaluationTarget> = []
    private var pendingWindowRuleReevaluationGeneration: UInt64 = 0
    private let reevaluate: (WMController, Set<WindowRuleReevaluationTarget>) async -> WindowRuleReevaluationOutcome
    var axWindowRefProvider: (WindowToken) -> AXWindowRef? = { token in
        AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
    }

    init(
        controller: WMController,
        reevaluate: @escaping (WMController, Set<WindowRuleReevaluationTarget>) async
            -> WindowRuleReevaluationOutcome = {
                await $0.reevaluateWindowRules(for: $1)
            }
    ) {
        self.controller = controller
        self.reevaluate = reevaluate
    }

    func reset() {
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationTask = nil
        pendingWindowRuleReevaluationTargets.removeAll()
        pendingWindowRuleReevaluationGeneration &+= 1
    }

    func schedule(
        targets: Set<WindowRuleReevaluationTarget>
    ) {
        guard let controller,
              controller.windowRuleEngine.needsWindowReevaluation,
              !targets.isEmpty
        else {
            return
        }

        pendingWindowRuleReevaluationTargets.formUnion(targets)
        pendingWindowRuleReevaluationTask?.cancel()
        pendingWindowRuleReevaluationGeneration &+= 1
        let generation = pendingWindowRuleReevaluationGeneration
        pendingWindowRuleReevaluationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.pendingWindowRuleReevaluationGeneration == generation,
                  let controller = self.controller
            else { return }
            guard controller.niriLayoutHandler.scrollAnimationByDisplay.isEmpty else {
                self.pendingWindowRuleReevaluationTask = nil
                self.schedule(targets: self.pendingWindowRuleReevaluationTargets)
                return
            }
            let targets = self.pendingWindowRuleReevaluationTargets
            let outcome = await self.reevaluate(controller, targets)
            guard !Task.isCancelled, self.pendingWindowRuleReevaluationGeneration == generation else { return }
            self.pendingWindowRuleReevaluationTask = nil
            if outcome.stale {
                self.schedule(targets: targets)
            } else {
                self.pendingWindowRuleReevaluationTargets.removeAll()
            }
        }
    }
}
