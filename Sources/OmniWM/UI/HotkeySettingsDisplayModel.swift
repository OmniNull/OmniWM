// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

enum HotkeyCaptureResult {
    case applied
    case conflict(ConflictAlert)
    case rejected(String)
}

@MainActor enum HotkeyBindingEditor {
    static func triggerKeepingSide(
        _ newTrigger: HotkeyTrigger,
        for actionId: String,
        settings: SettingsStore
    ) -> HotkeyTrigger {
        guard let chord = newTrigger.chordBinding else { return newTrigger }
        let previousSide = settings.hotkeyBindings
            .first { $0.id == actionId }?.binding.chordBinding?.side ?? .either
        return .chord(chord.settingSide(previousSide))
    }

    static func trigger(for actionId: String, side: ModifierSide, settings: SettingsStore) -> HotkeyTrigger? {
        guard let chord = settings.hotkeyBindings.first(where: { $0.id == actionId })?.binding.chordBinding
        else { return nil }
        return .chord(chord.settingSide(side))
    }

    static func capture(
        _ newBinding: KeyBinding,
        for actionId: String,
        settings: SettingsStore
    ) -> HotkeyCaptureResult {
        capture(newBinding.isUnassigned ? .unassigned : .chord(newBinding), for: actionId, settings: settings)
    }

    static func capture(
        _ newTrigger: HotkeyTrigger,
        for actionId: String,
        settings: SettingsStore
    ) -> HotkeyCaptureResult {
        do {
            try settings.validateHotkeyTrigger(newTrigger)
        } catch {
            return .rejected(error.localizedDescription)
        }
        let conflicts = settings.findConflicts(for: newTrigger, excluding: actionId)
        guard conflicts.isEmpty else {
            return .conflict(
                ConflictAlert(
                    targetActionId: actionId,
                    newTrigger: newTrigger,
                    conflictingCommands: conflicts.map(\.command.localizedDisplayName)
                )
            )
        }

        settings.updateTrigger(for: actionId, newTrigger: newTrigger)
        return .applied
    }

    static func captureModeKey(
        _ trigger: HotkeyTrigger,
        for actionId: String,
        settings: SettingsStore
    ) -> HotkeyCaptureResult {
        guard let key = trigger.chordBinding, KeyboardModeTable.isSupported(key) else {
            return .rejected(
                String(localized: "A mode key is a single key, optionally with Shift. Escape always leaves the mode.")
            )
        }
        if let other = settings.hotkeyBindings.first(where: { $0.id != actionId && $0.modeKey == key }) {
            return .rejected(
                String(localized: "This key is already the mode key for \(other.command.localizedDisplayName).")
            )
        }
        if settings.hotkeyBindings.contains(where: { $0.binding.chordBinding?.conflicts(with: key) == true }) {
            return .rejected(String(localized: "A shortcut already uses this key"))
        }
        settings.updateModeKey(for: actionId, newModeKey: key)
        return .applied
    }

    static func applyConflictResolution(_ alert: ConflictAlert, settings: SettingsStore) {
        let conflicts = settings.findConflicts(for: alert.newTrigger, excluding: alert.targetActionId)
        for conflict in conflicts {
            settings.clearBinding(for: conflict.id)
        }
        settings.updateTrigger(for: alert.targetActionId, newTrigger: alert.newTrigger)
    }
}

enum HotkeyInputMonitoringStatus: Equatable {
    case granted
    case denied

    init(granted: Bool) {
        self = granted ? .granted : .denied
    }

    var displayText: String {
        switch self {
        case .granted:
            String(localized: "Granted")
        case .denied:
            String(localized: "Denied")
        }
    }
}

enum HotkeySettingsDisplayModel {
    private static let unassignedText = String(localized: "Unassigned")
    struct Group: Identifiable {
        let category: HotkeyCategory
        let bindings: [HotkeyBinding]

        var id: HotkeyCategory {
            category
        }
    }

    static func search(_ query: String, bindings: [HotkeyBinding]) -> [Group] {
        let normalizedQuery = ActionCatalog.normalizedSearchTerm(query)
        var bindingsByCategory: [HotkeyCategory: [HotkeyBinding]] = [:]
        for binding in bindings {
            guard ActionCatalog.visibility(for: binding.id).map({ ![.unassignable, .niriSettings].contains($0) })
                ?? true,
                matchesSearch(normalizedQuery, binding: binding)
            else { continue }
            bindingsByCategory[binding.category, default: []].append(binding)
        }
        return HotkeyCategory.allCases.compactMap { category in
            bindingsByCategory[category].map { Group(category: category, bindings: $0) }
        }
    }

    private static func matchesSearch(_ normalizedQuery: String, binding: HotkeyBinding) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        if let terms = ActionCatalog.normalizedSearchTerms(for: binding.id) {
            if terms.contains(where: { $0.contains(normalizedQuery) }) { return true }
        } else if ActionCatalog.normalizedSearchTerm(binding.command.displayName).contains(normalizedQuery)
            || ActionCatalog.normalizedSearchTerm(binding.command.layoutCompatibility.rawValue)
            .contains(normalizedQuery)
        {
            return true
        }
        return ActionCatalog.normalizedSearchTerm(displayString(for: binding.binding)).contains(normalizedQuery)
            || ActionCatalog.normalizedSearchTerm(humanReadableString(for: binding.binding)).contains(normalizedQuery)
    }

    static func displayString(for binding: KeyBinding) -> String {
        binding.isUnassigned ? unassignedText : binding.displayString
    }

    static func displayString(for trigger: HotkeyTrigger) -> String {
        switch trigger {
        case .unassigned:
            return unassignedText
        case let .chord(binding):
            return displayString(for: binding)
        case let .mouseButton(binding):
            return binding.displayString
        }
    }

    static func humanReadableString(for binding: KeyBinding) -> String {
        binding.isUnassigned ? unassignedText : binding.humanReadableString
    }

    static func humanReadableString(for trigger: HotkeyTrigger) -> String {
        switch trigger {
        case .unassigned:
            return unassignedText
        case let .chord(binding):
            return humanReadableString(for: binding)
        case let .mouseButton(binding):
            return binding.humanReadableString
        }
    }

    static func inputMonitoringStatus(
        preflightGranted: Bool,
        requestIfNeeded: Bool,
        requestGranted: Bool
    ) -> HotkeyInputMonitoringStatus {
        HotkeyInputMonitoringStatus(granted: preflightGranted || (requestIfNeeded && requestGranted))
    }
}

struct ConflictAlert: Identifiable {
    let targetActionId: String
    let newTrigger: HotkeyTrigger
    let conflictingCommands: [String]

    var id: String {
        [
            targetActionId,
            newTrigger.humanReadableString,
            conflictingCommands.joined(separator: "|")
        ].joined(separator: ":")
    }

    var message: String {
        if conflictingCommands.count == 1 {
            return String(
                localized: "This key combination is already used by \"\(conflictingCommands[0])\". Do you want to replace it?"
            )
        }
        let commandList = conflictingCommands.joined(separator: ", ")
        return String(localized: "This key combination is used by: \(commandList). Do you want to replace all?")
    }
}
