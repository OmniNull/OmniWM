// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct NiriEdgePictureState {
    static let none = Self()

    var isAvailable = false
    var readyTokens: Set<WindowToken> = []
    var parkedAboveTokens: Set<WindowToken> = []
    var parkedBelowTokens: Set<WindowToken> = []

    func columnState(
        _ column: NiriProjectedColumn,
        activeTab: NiriWindow?,
        isActive: Bool,
        isSettled: Bool
    ) -> NiriColumnPictureState {
        let normal = column.windows.allSatisfy { $0.sizingMode == .normal }
        let ready = if let activeTab {
            readyTokens.contains(activeTab.token)
        } else {
            column.windows.allSatisfy { readyTokens.contains($0.token) }
        }
        return NiriColumnPictureState(
            isAvailable: isAvailable,
            holdsActive: isActive && !isSettled && normal
                && column.windows.allSatisfy { parkedAboveTokens.contains($0.token) },
            holdsActiveBelow: isActive && !isSettled && normal
                && column.windows.allSatisfy { parkedBelowTokens.contains($0.token) },
            isReady: normal && ready,
            isSettled: isSettled
        )
    }
}

struct NiriColumnPictureState {
    static let none = Self()

    var isAvailable = false
    var holdsActive = false
    var holdsActiveBelow = false
    var isReady = false
    var isSettled = true
}
