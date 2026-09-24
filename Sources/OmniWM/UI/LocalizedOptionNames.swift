// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

private func localizedModifierName(_ name: String) -> String {
    name.split(separator: "+").map { part in
        switch part {
        case "Off": String(localized: "Off")
        case "Option": String(localized: "Option")
        case "Control": String(localized: "Control")
        case "Command": String(localized: "Command")
        case "Shift": String(localized: "Shift")
        case "Left Option": String(localized: "Left Option")
        case "Right Option": String(localized: "Right Option")
        case "Left Control": String(localized: "Left Control")
        case "Right Control": String(localized: "Right Control")
        case "Left Command": String(localized: "Left Command")
        case "Right Command": String(localized: "Right Command")
        case "Left Shift": String(localized: "Left Shift")
        case "Right Shift": String(localized: "Right Shift")
        default: String(part)
        }
    }.joined(separator: "+")
}

extension AppearanceMode {
    var localizedDisplayName: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

extension LayoutType {
    var localizedDisplayName: String {
        switch self {
        case .defaultLayout: String(localized: "Default")
        case .niri: String(localized: "Niri (Scrolling)")
        case .dwindle: String(localized: "Dwindle (BSP)")
        }
    }
}

extension WindowRuleLayoutAction {
    var localizedDisplayName: String {
        switch self {
        case .auto: String(localized: "Automatic")
        case .tile: String(localized: "Tile")
        case .float: String(localized: "Float")
        }
    }
}

extension SingleWindowFit.Mode {
    var localizedDisplayName: String {
        switch self {
        case .fill: String(localized: "Full Screen")
        case .custom: String(localized: "Custom (W:H)")
        case .containerPrimarySpan: String(localized: "Container Primary Span")
        }
    }
}

extension CenterFocusedColumn {
    var localizedDisplayName: String {
        switch self {
        case .never: String(localized: "Never")
        case .always: String(localized: "Always")
        case .onOverflow: String(localized: "On Overflow")
        }
    }
}

extension TrackpadScrollStyle {
    var localizedDisplayName: String {
        switch self {
        case .snap: String(localized: "Snap to Columns")
        case .momentum: String(localized: "Momentum")
        }
    }
}

extension ScrollModifierKey {
    var localizedDisplayName: String {
        switch self {
        case .optionShift: String(localized: "Option+Shift (⌥⇧)")
        case .controlShift: String(localized: "Control+Shift (⌃⇧)")
        }
    }
}

extension QuakeTerminalPosition {
    var localizedDisplayName: String {
        switch self {
        case .top: String(localized: "Top")
        case .bottom: String(localized: "Bottom")
        case .left: String(localized: "Left")
        case .right: String(localized: "Right")
        case .center: String(localized: "Center")
        }
    }
}

extension QuakeTerminalMonitorMode {
    var localizedDisplayName: String {
        switch self {
        case .mouseCursor: String(localized: "Mouse Cursor's Monitor")
        case .focusedWindow: String(localized: "Focused Window's Monitor")
        case .mainMonitor: String(localized: "Main Monitor")
        }
    }
}

extension QuakeTerminalBackgroundEffect {
    var localizedDisplayName: String {
        switch self {
        case .standardBlur: String(localized: "Standard Blur")
        case .glassRegular: String(localized: "Regular Glass")
        case .glassClear: String(localized: "Clear Glass")
        }
    }
}

extension MouseMoveModifierKey {
    var localizedDisplayName: String {
        localizedModifierName(displayName)
    }
}

extension MouseResizeModifierKey {
    var localizedDisplayName: String {
        localizedModifierName(displayName)
    }
}

extension FocusLockModifier {
    var localizedDisplayName: String {
        localizedModifierName(displayName)
    }
}

extension WorkspaceBarRevealModifier {
    var localizedDisplayName: String {
        localizedModifierName(displayName)
    }
}
