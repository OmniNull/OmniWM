// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation

struct HiddenBarProfileOverride: Equatable {
    let profile: String
    var enabled: Bool?
    var rehideIntervalSeconds: Double?

    var overriddenKeys: [String] {
        [enabled.map { _ in "enabled" }, rehideIntervalSeconds.map { _ in "rehideIntervalSeconds" }].compactMap(\.self)
    }
}

@MainActor @Observable
final class HiddenBarSettings {
    private nonisolated static let defaults = SettingsExport.HiddenBar.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var enabled = HiddenBarSettings.defaults.enabled {
        didSet { onChange?() }
    }

    var hiddenBundleIDs = HiddenBarSettings.defaults.hiddenBundleIDs {
        didSet { onChange?() }
    }

    var rehideIntervalSeconds = HiddenBarSettings.defaults.rehideIntervalSeconds {
        didSet { onChange?() }
    }

    var profileOverride: HiddenBarProfileOverride?

    var resolvedEnabled: Bool {
        profileOverride?.enabled ?? enabled
    }

    var resolvedRehideIntervalSeconds: Double {
        profileOverride?.rehideIntervalSeconds ?? rehideIntervalSeconds
    }

    func export() -> SettingsExport.HiddenBar {
        SettingsExport.HiddenBar(
            enabled: enabled,
            hiddenBundleIDs: hiddenBundleIDs,
            rehideIntervalSeconds: rehideIntervalSeconds
        )
    }

    func apply(_ values: SettingsExport.HiddenBar) {
        enabled = values.enabled
        hiddenBundleIDs = HiddenBarSettingsPolicy.normalizedBundleIDs(values.hiddenBundleIDs)
        rehideIntervalSeconds = HiddenBarSettingsPolicy.validatedRehideIntervalSeconds(values.rehideIntervalSeconds)
    }
}

extension SettingsStore {
    var effectiveHiddenBarEnabled: Bool {
        hiddenBar.resolvedEnabled && workspaceBar.enabled
    }
}
