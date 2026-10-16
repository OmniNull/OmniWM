// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Observation
import SwiftUI

enum StatusMenuControlPreview: Equatable {
    case focusedWindow
    case workspaceBar
    case keepAwake
    case focusMouse
    case focusEdge
    case mouseToFocused
    case followMonitor
    case moveEdge
    case mouseWarp
    case hiddenMenuIcons
}

enum StatusMenuControl: String, CaseIterable, Identifiable {
    case bordersEnabled
    case workspaceBarEnabled
    case preventSleepEnabled
    case focusFollowsMouse
    case focusCrossesMonitorAtEdge
    case moveMouseToFocusedWindow
    case focusFollowsWindowToMonitor
    case moveCrossesMonitorAtEdge
    case mouseWarpEnabled
    case hiddenBarEnabled

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .bordersEnabled:
            "square.dashed"
        case .workspaceBarEnabled:
            "menubar.rectangle"
        case .preventSleepEnabled:
            "moon.zzz"
        case .focusFollowsMouse:
            "cursorarrow.motionlines"
        case .focusCrossesMonitorAtEdge:
            "display.2"
        case .moveMouseToFocusedWindow:
            "arrow.up.left.and.down.right.magnifyingglass"
        case .focusFollowsWindowToMonitor:
            "arrow.right.square"
        case .moveCrossesMonitorAtEdge:
            "macwindow.on.rectangle"
        case .mouseWarpEnabled:
            "arrow.left.arrow.right"
        case .hiddenBarEnabled:
            "eye.slash"
        }
    }

    var label: String {
        switch self {
        case .bordersEnabled:
            String(localized: "Borders")
        case .workspaceBarEnabled:
            String(localized: "Workspace Bar")
        case .preventSleepEnabled:
            String(localized: "Keep Awake")
        case .focusFollowsMouse:
            String(localized: "Focus Mouse")
        case .focusCrossesMonitorAtEdge:
            String(localized: "Focus Edge")
        case .moveMouseToFocusedWindow:
            String(localized: "Mouse to Focused")
        case .focusFollowsWindowToMonitor:
            String(localized: "Follow Monitor")
        case .moveCrossesMonitorAtEdge:
            String(localized: "Move Edge")
        case .mouseWarpEnabled:
            String(localized: "Mouse Warp")
        case .hiddenBarEnabled:
            String(localized: "Hide Menu Icons")
        }
    }

    var accessibilityName: String {
        switch self {
        case .bordersEnabled:
            String(localized: "Window Borders")
        case .workspaceBarEnabled:
            String(localized: "Workspace Bar")
        case .preventSleepEnabled:
            String(localized: "Keep Awake")
        case .focusFollowsMouse:
            String(localized: "Focus Follows Mouse")
        case .focusCrossesMonitorAtEdge:
            String(localized: "Focus Across Monitor at Edge")
        case .moveMouseToFocusedWindow:
            String(localized: "Mouse to Focused")
        case .focusFollowsWindowToMonitor:
            String(localized: "Follow Window to Monitor")
        case .moveCrossesMonitorAtEdge:
            String(localized: "Move Window Across Monitor at Edge")
        case .mouseWarpEnabled:
            String(localized: "Mouse Warp")
        case .hiddenBarEnabled:
            String(localized: "Hide Menu Bar Icons")
        }
    }

    var explanation: String {
        String(localized: explanationResource)
    }

    private var explanationResource: LocalizedStringResource {
        switch self {
        case .bordersEnabled:
            "Shows a colored outline around the currently focused managed window. Customize its appearance in Settings."
        case .workspaceBarEnabled:
            "Shows workspaces and their windows in a clickable bar on each display. Per-display overrides can change an individual bar."
        case .preventSleepEnabled:
            "Prevents idle display sleep while your user session is active. Manual sleep and closing the laptop lid still work."
        case .focusFollowsMouse:
            "Focuses a managed window when the pointer enters it—no click needed. Choose whether OmniWM explicitly raises it in Settings, or hold Focus Lock to cross windows without changing focus."
        case .focusCrossesMonitorAtEdge:
            "At the last window in any direction, Focus continues left, right, up, or down onto the adjacent display in OmniWM’s Routing Arrangement."
        case .moveMouseToFocusedWindow:
            "Moves the pointer into a window after OmniWM navigation changes focus. It stays put if already inside or the pointer caused the focus."
        case .focusFollowsWindowToMonitor:
            "After moving a window or column to another workspace, switches there and keeps it focused. When off, you stay in the source workspace."
        case .moveCrossesMonitorAtEdge:
            "At a workspace edge, Move Window sends the focused window left, right, up, or down to the adjacent routed display and follows it."
        case .mouseWarpEnabled:
            "Moves the pointer across matching display edges using OmniWM’s Routing Arrangement. Available only with multiple displays."
        case .hiddenBarEnabled:
            "Hides the menu-bar items selected in Settings. Right-click or Option-click OmniWM’s icon to reveal the hidden-icons bar."
        }
    }

    var preview: StatusMenuControlPreview {
        switch self {
        case .bordersEnabled:
            .focusedWindow
        case .workspaceBarEnabled:
            .workspaceBar
        case .preventSleepEnabled:
            .keepAwake
        case .focusFollowsMouse:
            .focusMouse
        case .focusCrossesMonitorAtEdge:
            .focusEdge
        case .moveMouseToFocusedWindow:
            .mouseToFocused
        case .focusFollowsWindowToMonitor:
            .followMonitor
        case .moveCrossesMonitorAtEdge:
            .moveEdge
        case .mouseWarpEnabled:
            .mouseWarp
        case .hiddenBarEnabled:
            .hiddenMenuIcons
        }
    }
}

struct ToggleTileSpec: Identifiable {
    let control: StatusMenuControl
    let isOn: Binding<Bool>

    var id: String {
        control.id
    }
}
