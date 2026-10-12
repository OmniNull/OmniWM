// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

extension SettingsStore {
    func isCommandFeatureEnabled(_ command: HotkeyCommand) -> Bool {
        switch command {
        case .presentation(.overview): overview.enabled
        case .presentation(.quakeTerminal): quakeTerminal.enabled
        default: true
        }
    }

    func updateBinding(for commandId: String, newBinding: KeyBinding) {
        updateTrigger(for: commandId, newTrigger: newBinding.isUnassigned ? .unassigned : .chord(newBinding))
    }

    func updateTrigger(for commandId: String, newTrigger: HotkeyTrigger) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.id == commandId }) else { return }
        hotkeyBindings[index] = HotkeyBinding(
            id: hotkeyBindings[index].id,
            command: hotkeyBindings[index].command,
            trigger: newTrigger
        )
    }

    func clearBinding(for commandId: String) {
        updateBinding(for: commandId, newBinding: .unassigned)
    }

    func resetBindings(for commandId: String) {
        guard let defaultBinding = HotkeyBindingRegistry.defaultBinding(for: commandId),
              let index = hotkeyBindings.firstIndex(where: { $0.id == commandId })
        else { return }
        hotkeyBindings[index] = defaultBinding
    }

    func findConflicts(for trigger: HotkeyTrigger, excluding commandId: String) -> [HotkeyBinding] {
        hotkeyBindings.filter { hotkeyBinding in
            hotkeyBinding.id != commandId &&
                hotkeyBinding.binding.conflicts(with: trigger)
        }
    }
}
