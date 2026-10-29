// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension SettingsExport.Niri {
    func withNaturalWindowDragDefaults(edgePeekPercent: Double? = nil) -> Self {
        var niri = self
        niri.naturalWindowDrag = naturalWindowDrag ?? false
        niri.naturalWindowDragModifier = naturalWindowDragModifier ?? .option
        niri.edgePeek = edgePeek ?? false
        niri.edgePeekPercent = self.edgePeekPercent ?? edgePeekPercent
        return niri
    }
}
