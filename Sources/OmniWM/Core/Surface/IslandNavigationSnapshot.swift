// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

struct IslandNavigationSnapshot: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let token: WindowToken
        let bundle: String
        let name: String
        let title: String
        let column: Int
    }

    let workspace: String
    let name: String
    let layout: String
    let focused: WindowToken?
    let windows: [Window]
}
