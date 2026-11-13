// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    static func ruleReevaluationLifetimeAuthority(
        existing: ManagedWindowLifetimeAuthority?,
        observedInTopLevelInventory: Bool
    ) -> ManagedWindowLifetimeAuthority {
        if observedInTopLevelInventory {
            return .axTopLevelInventory
        }
        return existing ?? .directLifecycle
    }

    @discardableResult
    func reevaluateWindowRules(
        for targets: Set<WindowRuleReevaluationTarget>,
        context: WindowRuleReevaluationContext = .automatic,
        stillWantsExplicitApply: (() -> Bool)? = nil
    ) async -> WindowRuleReevaluationOutcome {
        guard !targets.isEmpty else { return .none }
        var reevaluation = WindowRuleReevaluation(
            controller: self,
            context: context,
            stillWantsExplicitApply: stillWantsExplicitApply
        )
        return await reevaluation.run(for: targets)
    }
}
