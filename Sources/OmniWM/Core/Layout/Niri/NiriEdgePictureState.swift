// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct NiriEdgePictureState {
    static let none = Self()

    var isAvailable = false
    var readyTokens: Set<WindowToken> = []
    var parkedAboveTokens: Set<WindowToken> = []

    func columnState(
        _ column: NiriProjectedColumn,
        activeTab: NiriWindow?,
        isActive: Bool,
        isSettled: Bool
    ) -> NiriColumnPictureState {
        guard isActive, !isSettled,
              column.windows.allSatisfy({ $0.sizingMode == .normal && parkedAboveTokens.contains($0.token) })
        else { return NiriColumnPictureState(isAvailable: isAvailable) }
        let ready = if let activeTab {
            readyTokens.contains(activeTab.token)
        } else {
            column.windows.allSatisfy { readyTokens.contains($0.token) }
        }
        return NiriColumnPictureState(isAvailable: isAvailable, holdsActive: true, isReady: ready)
    }
}

struct NiriColumnPictureState {
    static let none = Self()

    var isAvailable = false
    var holdsActive = false
    var isReady = false
}
