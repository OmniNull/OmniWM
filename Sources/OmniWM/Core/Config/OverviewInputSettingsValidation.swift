// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum OverviewInputSettingsError: Error, LocalizedError {
    case unsupportedButton
    case hyperConflict
    case usedByHotkey
    case usedByHyper
    case usedByOverview

    var errorDescription: String? {
        switch self {
        case .unsupportedButton:
            String(localized: "Overview supports the middle button and mouse buttons 3–5.")
        case .hyperConflict:
            String(
                localized: "Overview and System Hyper cannot use the same mouse button. Choose another button or unassign one."
            )
        case .usedByHotkey:
            String(localized: "This mouse button is assigned to a hotkey. Clear that hotkey or choose another button.")
        case .usedByHyper:
            String(
                localized: "This mouse button is the System Hyper trigger. Change System Hyper first or choose another button."
            )
        case .usedByOverview:
            String(
                localized: "This mouse button toggles Overview. Unassign it in Overview settings first or choose another button."
            )
        }
    }
}

enum OverviewInputSettingsValidation {
    static let mouseButtons: ClosedRange<Int64> = 2 ... 5

    static func validate(
        mouseButton: Int64?,
        hyperTrigger: SystemHyperTrigger,
        hotkeyBindings: [HotkeyBinding]
    ) throws {
        let hotkeyButtons = hotkeyMouseButtons(hotkeyBindings)
        if let hyperButton = hyperTrigger.mouseButtonNumber, hotkeyButtons.contains(hyperButton) {
            throw OverviewInputSettingsError.usedByHotkey
        }
        guard let mouseButton else { return }
        guard mouseButtons.contains(mouseButton) else { throw OverviewInputSettingsError.unsupportedButton }
        guard hyperTrigger.mouseButtonNumber != mouseButton else { throw OverviewInputSettingsError.hyperConflict }
        guard !hotkeyButtons.contains(mouseButton) else { throw OverviewInputSettingsError.usedByHotkey }
    }

    static func validate(
        hotkeyTrigger: HotkeyTrigger,
        overviewMouseButton: Int64?,
        hyperTrigger: SystemHyperTrigger
    ) throws {
        guard let button = hotkeyTrigger.mouseButtonBinding?.button else { return }
        guard hyperTrigger.mouseButtonNumber != button else { throw OverviewInputSettingsError.usedByHyper }
        guard overviewMouseButton != button else { throw OverviewInputSettingsError.usedByOverview }
    }

    static func hotkeyMouseButtons(_ bindings: [HotkeyBinding]) -> Set<Int64> {
        Set(bindings.compactMap { $0.binding.mouseButtonBinding?.button })
    }

    static func buttonLabel(_ button: Int64) -> String {
        button == 2 ? String(localized: "Middle Button") : String(localized: "Mouse Button \(button)")
    }
}

extension SettingsStore {
    func setOverviewMouseButton(_ button: Int64?) throws {
        try OverviewInputSettingsValidation.validate(
            mouseButton: button,
            hyperTrigger: systemHyperTrigger,
            hotkeyBindings: hotkeyBindings
        )
        overview.mouseButton = button
    }

    func setSystemHyperTrigger(_ trigger: SystemHyperTrigger) throws {
        try OverviewInputSettingsValidation.validate(
            mouseButton: overview.mouseButton,
            hyperTrigger: trigger,
            hotkeyBindings: hotkeyBindings
        )
        systemHyperTrigger = trigger
    }

    func validateHotkeyTrigger(_ trigger: HotkeyTrigger) throws {
        try OverviewInputSettingsValidation.validate(
            hotkeyTrigger: trigger,
            overviewMouseButton: overview.mouseButton,
            hyperTrigger: systemHyperTrigger
        )
    }
}
