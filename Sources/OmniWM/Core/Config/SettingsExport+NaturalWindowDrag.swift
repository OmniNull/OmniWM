// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension SettingsExport.Niri {
    func withNaturalWindowDragDefaults() -> Self {
        var niri = self
        niri.naturalWindowDrag = naturalWindowDrag ?? false
        niri.naturalWindowDragModifier = naturalWindowDragModifier ?? .option
        return niri
    }
}
