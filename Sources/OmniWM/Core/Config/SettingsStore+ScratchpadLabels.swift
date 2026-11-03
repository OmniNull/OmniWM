// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension SettingsStore {
    func scratchpadLabel(for index: Int) -> String? {
        scratchpadLabels[String(index)]
    }

    static func normalizedScratchpadLabels(_ labels: [String: String]) -> [String: String] {
        labels.reduce(into: [:]) { normalized, entry in
            guard let index = Int(entry.key.trimmingCharacters(in: .whitespacesAndNewlines)),
                  IPCScratchpadSlots.range.contains(index)
            else {
                return
            }
            let label = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return }
            normalized[String(index)] = label
        }
    }
}
