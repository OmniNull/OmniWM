// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

enum WorkspaceBarWindowLevel: String, CaseIterable, Codable, Identifiable {
    case normal
    case floating
    case status
    case popup
    case screensaver

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .normal: String(localized: "Normal")
        case .floating: String(localized: "Floating")
        case .status: String(localized: "Status Bar")
        case .popup: String(localized: "Popup")
        case .screensaver: String(localized: "Screen Saver")
        }
    }

    var nsWindowLevel: NSWindow.Level {
        switch self {
        case .normal: .normal
        case .floating: .floating
        case .status: .statusBar
        case .popup: .popUpMenu
        case .screensaver: .screenSaver
        }
    }
}

enum WorkspaceBarPosition: String, CaseIterable, Codable, Identifiable {
    case overlappingMenuBar
    case belowMenuBar
    case bottom
    case left
    case right

    var isVertical: Bool {
        self == .left || self == .right
    }

    var usesNotch: Bool {
        self == .overlappingMenuBar || self == .belowMenuBar
    }

    var popupEdge: PopupAttachment.Edge {
        switch self {
        case .overlappingMenuBar,
             .belowMenuBar: .below
        case .bottom: .above
        case .left: .right
        case .right: .left
        }
    }

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .overlappingMenuBar: String(localized: "Overlapping Menu Bar")
        case .belowMenuBar: String(localized: "Below Menu Bar")
        case .bottom: String(localized: "Bottom")
        case .left: String(localized: "Left")
        case .right: String(localized: "Right")
        }
    }
}

enum WorkspaceBarNotchMode: String, CaseIterable, Codable, Identifiable {
    case off
    case moveBelowMenuBar
    case rightOfNotch
    case splitActiveLeft
    case splitActiveRight
    case fillLeftOfNotch

    var id: String {
        rawValue
    }

    var isSplit: Bool {
        self == .splitActiveLeft || self == .splitActiveRight
    }

    var displayName: String {
        switch self {
        case .off: String(localized: "Off")
        case .moveBelowMenuBar: String(localized: "Move Below Menu Bar")
        case .rightOfNotch: String(localized: "Right of Notch")
        case .splitActiveLeft: String(localized: "Split — Active Left")
        case .splitActiveRight: String(localized: "Split — Active Right")
        case .fillLeftOfNotch: String(localized: "Fill Left of Notch")
        }
    }
}
