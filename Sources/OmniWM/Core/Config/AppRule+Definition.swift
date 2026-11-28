// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

struct SavedAppRuleReport {
    let rule: AppRule
    let specificity: Int
    let invalidRegexMessage: String?
    let validationMessages: [String]

    var isValid: Bool {
        validationMessages.isEmpty
    }
}

extension AppRule {
    init(definition: IPCRuleDefinition, id: UUID = UUID()) {
        let normalized = definition.normalized
        self.init(
            id: id,
            bundleId: normalized.bundleId,
            appNameSubstring: normalized.appNameSubstring,
            titleSubstring: normalized.titleSubstring,
            titleRegex: normalized.titleRegex,
            axRole: normalized.axRole,
            axSubrole: normalized.axSubrole,
            layout: Self.layoutAction(normalized.layout),
            assignToWorkspace: normalized.assignToWorkspace,
            assignToWorkspaceForAllWindows: normalized.assignToWorkspaceForAllWindows,
            initialContainerPrimarySpan: normalized.initialContainerPrimarySpan,
            minWidth: normalized.minWidth,
            minHeight: normalized.minHeight,
            scratchpad: normalized.scratchpad
        )
    }

    var normalizedForReporting: AppRule {
        var rule = self
        rule.bundleId = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.appNameSubstring = trimmedRuleText(appNameSubstring)
        rule.titleSubstring = trimmedRuleText(titleSubstring)
        rule.titleRegex = trimmedRuleText(titleRegex)
        rule.axRole = trimmedRuleText(axRole)
        rule.axSubrole = trimmedRuleText(axSubrole)
        rule.assignToWorkspace = trimmedRuleText(assignToWorkspace)
        return rule
    }

    var ipcDefinition: IPCRuleDefinition {
        IPCRuleDefinition(
            bundleId: bundleId,
            appNameSubstring: appNameSubstring,
            titleSubstring: titleSubstring,
            titleRegex: titleRegex,
            axRole: axRole,
            axSubrole: axSubrole,
            layout: ipcRuleLayout,
            assignToWorkspace: assignToWorkspace,
            assignToWorkspaceForAllWindows: assignToWorkspaceForAllWindows,
            initialContainerPrimarySpan: initialContainerPrimarySpan,
            minWidth: minWidth,
            minHeight: minHeight,
            scratchpad: scratchpad
        )
    }

    var ipcRuleLayout: IPCRuleLayout {
        switch effectiveLayoutAction {
        case .auto: .auto
        case .tile: .tile
        case .float: .float
        }
    }

    func savedReport(runtimeRegexError: String?) -> SavedAppRuleReport {
        let rule = normalizedForReporting
        let validation = IPCRuleValidator.validate(rule.ipcDefinition)
        let invalidRegexMessage = runtimeRegexError ?? validation.invalidRegexMessage
        let validationMessages = [
            validation.bundleIdError,
            invalidRegexMessage,
            validation.identifierError,
            validation.titleMatcherError,
            validation.initialContainerPrimarySpanError,
            validation.workspaceAssignmentError,
            validation.scratchpadError,
            validation.effectError,
            validation.minSizeError
        ].compactMap { $0 }
        return SavedAppRuleReport(
            rule: rule,
            specificity: specificity,
            invalidRegexMessage: invalidRegexMessage,
            validationMessages: validationMessages
        )
    }

    private static func layoutAction(_ layout: IPCRuleLayout) -> WindowRuleLayoutAction? {
        switch layout {
        case .auto:
            nil
        case .tile:
            .tile
        case .float:
            .float
        }
    }
}

extension IPCRuleDefinition {
    var normalized: IPCRuleDefinition {
        IPCRuleDefinition(
            bundleId: bundleId.trimmingCharacters(in: .whitespacesAndNewlines),
            appNameSubstring: trimmedRuleText(appNameSubstring),
            titleSubstring: trimmedRuleText(titleSubstring),
            titleRegex: trimmedRuleText(titleRegex),
            axRole: trimmedRuleText(axRole),
            axSubrole: trimmedRuleText(axSubrole),
            layout: layout,
            assignToWorkspace: trimmedRuleText(assignToWorkspace),
            assignToWorkspaceForAllWindows: assignToWorkspaceForAllWindows,
            initialContainerPrimarySpan: initialContainerPrimarySpan,
            minWidth: minWidth,
            minHeight: minHeight,
            scratchpad: scratchpad
        )
    }
}

private func trimmedRuleText(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    return trimmed.isEmpty ? nil : trimmed
}
