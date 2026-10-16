// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation

@MainActor @Observable
final class IslandSettings {
    @ObservationIgnored var onChange: (() -> Void)?

    var enabled = SettingsExport.Island.defaults().enabled {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.Island {
        SettingsExport.Island(enabled: enabled)
    }

    func apply(_ values: SettingsExport.Island) {
        enabled = values.enabled
    }
}
