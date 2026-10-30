// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct ShellIslandConfig: Equatable {
    enum Displays: String {
        case notch
        case main
        case all
    }

    enum Sizing: String {
        case fixed
        case display
    }

    enum Fullscreen: String {
        case hide
        case show
    }

    static let focusRibbon = "focus-ribbon"

    var root = Self.focusRibbon
    var displays = Displays.notch
    var width: CGFloat = 760
    var height: CGFloat = 300
    var fullscreen = Fullscreen.hide
    var sizing = Sizing.fixed
    var components: [ShellComponentInstance] = []

    var size: CGSize {
        CGSize(width: width, height: height)
    }

    func size(on monitor: Monitor) -> CGSize {
        sizing == .display ? monitor.frame.size : size
    }

    func includes(_ monitor: Monitor) -> Bool {
        switch displays {
        case .notch: monitor.hasNotch
        case .main: monitor.isMain
        case .all: true
        }
    }
}
