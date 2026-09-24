// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation

@MainActor @Observable
final class ClipboardSettings {
    private nonisolated static let defaults = SettingsExport.Clipboard.defaults()
    @ObservationIgnored var onChange: (() -> Void)?

    var historyEnabled = ClipboardSettings.defaults.historyEnabled {
        didSet { onChange?() }
    }

    var maxItems = ClipboardSettings.defaults.maxItems {
        didSet { onChange?() }
    }

    var maxItemBytes = ClipboardSettings.defaults.maxItemBytes {
        didSet { onChange?() }
    }

    var maxTotalBytes = ClipboardSettings.defaults.maxTotalBytes {
        didSet { onChange?() }
    }

    var ignoredTypes = ClipboardSettings.defaults.ignoredTypes {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.Clipboard {
        SettingsExport.Clipboard(
            historyEnabled: historyEnabled,
            maxItems: maxItems,
            maxItemBytes: maxItemBytes,
            maxTotalBytes: maxTotalBytes,
            ignoredTypes: ignoredTypes
        )
    }

    func apply(_ values: SettingsExport.Clipboard) {
        historyEnabled = values.historyEnabled
        maxItems = values.maxItems
        maxItemBytes = values.maxItemBytes
        maxTotalBytes = values.maxTotalBytes
        ignoredTypes = values.ignoredTypes
    }
}
