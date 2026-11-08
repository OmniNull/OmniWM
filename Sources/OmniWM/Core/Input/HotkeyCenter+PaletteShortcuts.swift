// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension HotkeyCenter {
    func setPaletteShortcutChords(_ chords: [KeyBinding]) {
        guard paletteShortcutChords != chords else { return }
        let previous = paletteShortcutChords
        paletteShortcutChords = chords
        guard isRunning, !commandHotkeysSuspended else { return }
        restorePaletteYieldedRegistrations(previouslyYielding: previous)
        applyPaletteShortcutYield()
    }

    func yieldsToPalette(_ binding: KeyBinding) -> Bool {
        paletteShortcutChords.contains { $0.conflicts(with: binding) }
    }

    func applyPaletteShortcutYield() {
        if !paletteShortcutChords.isEmpty {
            carbonRegistrations.unregister(keeping: { !yieldsToPalette($0.binding) })
            sideSpecificDispatch.removeAll { yieldsToPalette($0.binding) }
        }
        updateEventTapEnablement()
    }

    private func restorePaletteYieldedRegistrations(previouslyYielding previous: [KeyBinding]) {
        guard !previous.isEmpty else { return }
        let plan = Self.registrationPlan(for: configuration.bindings)
        let restorable = { (registration: HotkeyPlannedRegistration) in
            previous.contains { $0.conflicts(with: registration.binding) }
                && !self.yieldsToPalette(registration.binding)
                && self.isRegistrationAllowed(registration.command)
        }
        carbonRegistrations.register(plan.registrations.filter(restorable), failures: &registrationFailures)
        guard hyperTriggerTap != nil else { return }
        sideSpecificDispatch += plan.sideSpecificRegistrations.filter(restorable).map {
            CommandHotkeyTapMatcher.Entry(binding: $0.binding, command: $0.command)
        }
    }
}
