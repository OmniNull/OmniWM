// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum IPCRuleProjection {
    @MainActor
    static func result(
        settings: SettingsStore,
        windowRuleEngine: WindowRuleEngine
    ) -> IPCRulesQueryResult {
        let rules = settings.appRules.enumerated().map { index, rule in
            snapshot(
                from: rule,
                position: index + 1,
                invalidRegexMessagesByRuleId: windowRuleEngine.invalidRegexMessagesByRuleId
            )
        }
        return IPCRulesQueryResult(rules: rules)
    }

    static func snapshot(
        from rule: AppRule,
        position: Int,
        invalidRegexMessagesByRuleId: [UUID: String]
    ) -> IPCRuleSnapshot {
        let report = rule.savedReport(runtimeRegexError: invalidRegexMessagesByRuleId[rule.id])
        let values = report.rule

        return IPCRuleSnapshot(
            id: values.id.uuidString,
            position: position,
            bundleId: values.bundleId,
            appNameSubstring: values.appNameSubstring,
            titleSubstring: values.titleSubstring,
            titleRegex: values.titleRegex,
            axRole: values.axRole,
            axSubrole: values.axSubrole,
            layout: values.ipcRuleLayout,
            assignToWorkspace: values.assignToWorkspace,
            assignToWorkspaceForAllWindows: values.assignToWorkspaceForAllWindows,
            initialContainerPrimarySpan: values.initialContainerPrimarySpan,
            minWidth: values.minWidth,
            minHeight: values.minHeight,
            scratchpad: values.scratchpad,
            specificity: report.specificity,
            isValid: report.isValid,
            invalidRegexMessage: report.invalidRegexMessage,
            validationMessages: report.validationMessages
        )
    }

    static func definition(from rule: AppRule) -> IPCRuleDefinition {
        rule.normalizedForReporting.ipcDefinition
    }
}
