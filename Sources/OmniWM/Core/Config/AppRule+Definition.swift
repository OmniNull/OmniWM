// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

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
            appNameSubstring: Self.trimmedNonEmpty(appNameSubstring),
            titleSubstring: Self.trimmedNonEmpty(titleSubstring),
            titleRegex: Self.trimmedNonEmpty(titleRegex),
            axRole: Self.trimmedNonEmpty(axRole),
            axSubrole: Self.trimmedNonEmpty(axSubrole),
            layout: layout,
            assignToWorkspace: Self.trimmedNonEmpty(assignToWorkspace),
            assignToWorkspaceForAllWindows: assignToWorkspaceForAllWindows,
            initialContainerPrimarySpan: initialContainerPrimarySpan,
            minWidth: minWidth,
            minHeight: minHeight,
            scratchpad: scratchpad
        )
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return trimmed.isEmpty ? nil : trimmed
    }
}
