// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct ShellIslandConfig: Equatable {
    enum Displays: String {
        case notch
        case main
        case all
    }

    enum Fullscreen: String {
        case hide
        case show
    }

    var root = "lake"
    var displays = Displays.notch
    var width: CGFloat = 760
    var height: CGFloat = 300
    var fullscreen = Fullscreen.hide
    var components: [ShellComponentInstance] = []

    var size: CGSize {
        CGSize(width: width, height: height)
    }

    func includes(_ monitor: Monitor) -> Bool {
        switch displays {
        case .notch: monitor.hasNotch
        case .main: monitor.isMain
        case .all: true
        }
    }
}
