// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension SettingsExport.Niri {
    func withMacOSFusionDefaults(edgePeekPercent: Double? = nil) -> Self {
        var niri = self
        niri.macOSFusion = macOSFusion ?? false
        niri.macOSFusionModifier = macOSFusionModifier ?? .option
        niri.edgePeekPercent = self.edgePeekPercent ?? edgePeekPercent
        return niri
    }
}
