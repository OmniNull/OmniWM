// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum HotkeyBindingRegistry {
    private static let defaultBindings = DefaultHotkeyBindings.all()
    private static let bindingsByID = Dictionary(
        defaultBindings.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func defaults() -> [HotkeyBinding] {
        defaultBindings
    }

    static func command(for id: String) -> HotkeyCommand? {
        defaultBinding(for: id)?.command
    }

    static func defaultBinding(for id: String) -> HotkeyBinding? {
        if let binding = bindingsByID[id] { return binding }
        guard let spec = ActionCatalog.workspaceNumberSpec(for: id) else { return nil }
        return HotkeyBinding(id: id, command: spec.command, binding: spec.defaultBinding)
    }

    static func makeBinding(id: String, binding: KeyBinding) -> HotkeyBinding? {
        guard let command = command(for: id) else { return nil }
        return HotkeyBinding(id: id, command: command, binding: binding)
    }

    static func makeBinding(id: String, trigger: HotkeyTrigger) -> HotkeyBinding? {
        guard let command = command(for: id) else { return nil }
        return HotkeyBinding(id: id, command: command, trigger: trigger)
    }

    static func reconcilingWorkspaceNumberBindings(
        _ bindings: [HotkeyBinding],
        workspaceNames: [String]
    ) -> [HotkeyBinding] {
        let existing = Dictionary(bindings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workspaceBindings = Set(workspaceNames.compactMap(WorkspaceIDPolicy.workspaceNumber(from:)))
            .sorted()
            .flatMap(ActionCatalog.workspaceNumberSpecs(forWorkspaceNumber:))
            .map { spec in
                existing[spec.id] ?? HotkeyBinding(id: spec.id, command: spec.command, binding: spec.defaultBinding)
            }
        var result = bindings.filter { bindingsByID[$0.id] != nil }
        let groups = Dictionary(grouping: workspaceBindings) { rowGroup(of: $0.id) }
        let insertions = groups.map { group, rows in
            (index: result.lastIndex { rowGroup(of: $0.id) == group }.map { $0 + 1 } ?? result.count, rows: rows)
        }
        for insertion in insertions.sorted(by: { $0.index > $1.index }) {
            result.insert(contentsOf: insertion.rows, at: insertion.index)
        }
        return result
    }

    private static func rowGroup(of id: String) -> WorkspaceNumberActionKind? {
        WorkspaceNumberActionKind.parse(id)?.kind.rowGroup
    }

    static func resolve(_ persisted: [PersistedHotkeyBinding]) throws -> [HotkeyBinding] {
        var overrides: [String: HotkeyTrigger] = [:]
        for entry in persisted {
            guard command(for: entry.id) != nil else {
                if ActionCatalog.visibility(for: entry.id) == .unassignable {
                    throw HotkeyBindingResolutionError.unassignableActionID(entry.id)
                }
                throw HotkeyBindingResolutionError.unknownActionID(entry.id)
            }
            guard overrides[entry.id] == nil else {
                throw HotkeyBindingResolutionError.duplicateActionID(entry.id)
            }
            overrides[entry.id] = canonicalizeTrigger(entry.binding)
        }
        let staticBindings = try defaultBindings.map { binding in
            guard let override = overrides[binding.id] else {
                throw HotkeyBindingResolutionError.missingActionID(binding.id)
            }
            return HotkeyBinding(id: binding.id, command: binding.command, trigger: override)
        }
        let workspaceNumberBindings = persisted
            .filter { bindingsByID[$0.id] == nil }
            .compactMap { makeBinding(id: $0.id, trigger: $0.binding) }
        return staticBindings + workspaceNumberBindings
    }

    static func canonicalizeTrigger(_ trigger: HotkeyTrigger) -> HotkeyTrigger {
        switch trigger {
        case .unassigned:
            return .unassigned
        case let .chord(binding):
            return binding.isUnassigned ? .unassigned : .chord(binding)
        case .mouseButton:
            return trigger
        }
    }

    static func retargetingHyperChords(
        _ bindings: [HotkeyBinding],
        to composition: HyperKeyModifiers
    ) -> [HotkeyBinding] {
        let encoded = bindings.map { ($0, $0.binding.humanReadableString) }
        KeySymbolMapper.setHyperKeyModifiers(composition)
        return encoded.map { binding, string in
            guard !binding.binding.isUnassigned,
                  let trigger = HotkeyTrigger.fromHumanReadable(string)
            else { return binding }
            return HotkeyBinding(id: binding.id, command: binding.command, trigger: trigger)
        }
    }
}
