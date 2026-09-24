// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum OverviewInputSettingsError: Error, LocalizedError {
    case unsupportedButton
    case hyperConflict

    var errorDescription: String? {
        switch self {
        case .unsupportedButton:
            String(localized: "Overview supports the middle button and mouse buttons 3–5.")
        case .hyperConflict:
            String(
                localized: "Overview and System Hyper cannot use the same mouse button. Choose another button or unassign one."
            )
        }
    }
}

enum OverviewInputSettingsValidation {
    static let mouseButtons: ClosedRange<Int64> = 2 ... 5

    static func validate(mouseButton: Int64?, hyperTrigger: SystemHyperTrigger) throws {
        guard let mouseButton else { return }
        guard mouseButtons.contains(mouseButton) else { throw OverviewInputSettingsError.unsupportedButton }
        guard hyperTrigger.mouseButtonNumber != mouseButton else { throw OverviewInputSettingsError.hyperConflict }
    }

    static func buttonLabel(_ button: Int64) -> String {
        button == 2 ? String(localized: "Middle Button") : String(localized: "Mouse Button \(button)")
    }
}

extension SettingsStore {
    func setOverviewMouseButton(_ button: Int64?) throws {
        try OverviewInputSettingsValidation.validate(mouseButton: button, hyperTrigger: systemHyperTrigger)
        overview.mouseButton = button
    }

    func setSystemHyperTrigger(_ trigger: SystemHyperTrigger) throws {
        try OverviewInputSettingsValidation.validate(mouseButton: overview.mouseButton, hyperTrigger: trigger)
        systemHyperTrigger = trigger
    }
}
