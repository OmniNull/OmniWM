// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCAutomationManifest {
    public static let commandDescriptors: [IPCCommandDescriptor] = [
        .init(
            name: .focus(.spatial),
            summary: "Focus spatially; Dwindle Up/Down traverse grouped tabs before edge fallback.",
            arguments: [.direction]
        ),
        .init(
            commandWords: ["focus", "previous"],
            name: .focus(.previous),
            summary: "Focus the previously focused window."
        ),
        .init(
            commandWords: ["focus", "down-or-left"],
            name: .focus(.downOrLeft),
            summary: "Traverse backward through the active Niri workspace.",
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["focus", "up-or-right"],
            name: .focus(.upOrRight),
            summary: "Traverse forward through the active Niri workspace.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .focus(.windowInColumn),
            summary: "Focus a window in the focused Niri column by one-based index.",
            arguments: [.windowIndex],
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["focus-window", "top"],
            name: .focus(.windowTop),
            summary: "Focus the top window in the focused Niri column.",
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["focus-window", "bottom"],
            name: .focus(.windowBottom),
            summary: "Focus the bottom window in the focused Niri column.",
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["focus-window", "down-or-top"],
            name: .focus(.windowDownOrTop),
            summary: "Focus the next window in the active Niri column or Dwindle group, wrapping to the top."
        ),
        .init(
            commandWords: ["focus-window", "up-or-bottom"],
            name: .focus(.windowUpOrBottom),
            summary: "Focus the previous window in the active Niri column or Dwindle group, wrapping to the bottom."
        ),
        .init(
            name: .focus(.windowOrWorkspaceDown),
            summary: "Focus down using the active Niri orientation; if no target exists, switch without wrapping to the workspace below.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .focus(.windowOrWorkspaceUp),
            summary: "Focus up using the active Niri orientation; if no target exists, switch without wrapping to the workspace above.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .focus(.column),
            summary: "Focus a Niri column by one-based index.",
            arguments: [.columnIndex],
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["focus-column", "first"],
            name: .focus(.columnFirst),
            summary: "Focus the first Niri column.",
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["focus-column", "last"],
            name: .focus(.columnLast),
            summary: "Focus the last Niri column.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .focus(.centerColumn),
            summary: "Center the focused Niri column without changing focus.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .focus(.centerVisibleColumns),
            summary: "Center the current block of fully visible Niri columns in the viewport.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .windowMovement(.spatial),
            summary: "Move with layout-aware consume/expel or Dwindle join/extract behavior.",
            arguments: [.direction]
        ),
        .init(
            name: .windowMovement(.down),
            summary: "Reorder the focused window down by one without wrapping within its Niri column or Dwindle group."
        ),
        .init(
            name: .windowMovement(.up),
            summary: "Reorder the focused window up by one without wrapping within its Niri column or Dwindle group."
        ),
        .init(
            name: .windowMovement(.downOrToWorkspaceDown),
            summary: "Move the focused Niri window down, or to the workspace below at the column edge.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .windowMovement(.upOrToWorkspaceUp),
            summary: "Move the focused Niri window up, or to the workspace above at the column edge.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .windowMovement(.consumeOrExpelLeft),
            summary: "Consume the focused Niri window into the column to the left, or expel it left from its column.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .windowMovement(.consumeOrExpelRight),
            summary: "Consume the focused Niri window into the column to the right, or expel it right from its column.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .windowMovement(.consumeIntoColumn),
            summary: "Consume the top window from the next Niri column into the focused column.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .windowMovement(.expelFromColumn),
            summary: "Expel the bottom window from the focused Niri column into a new following column.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .workspace(.switchTo),
            summary: "Switch to a workspace by workspace ID on its assigned monitor.",
            arguments: [.workspaceNumber]
        ),
        .init(
            commandWords: ["switch-workspace", "next"],
            name: .workspace(.next),
            summary: "Switch to the next workspace on the current monitor."
        ),
        .init(
            commandWords: ["switch-workspace", "prev"],
            name: .workspace(.previous),
            summary: "Switch to the previous workspace on the current monitor."
        ),
        .init(
            commandWords: ["switch-workspace", "back-and-forth"],
            name: .workspace(.backAndForth),
            summary: "Switch to the previously active workspace on the current monitor."
        ),
        .init(
            commandWords: ["switch-workspace", "anywhere"],
            name: .workspace(.switchAnywhere),
            summary: "Focus a workspace by workspace ID across all monitors.",
            arguments: [.workspaceNumber]
        ),
        .init(
            commandWords: ["switch-workspace", "slot"],
            name: .workspace(.switchSlot),
            summary: "Switch to the workspace at a one-based position in the interaction monitor's workspace list.",
            arguments: [.slotNumber]
        ),
        .init(
            name: .workspace(.moveTo),
            summary: "Move the focused window to a workspace by workspace ID.",
            arguments: [.workspaceNumber]
        ),
        .init(
            commandWords: ["move-to-workspace", "up"],
            name: .workspace(.moveUp),
            summary: "Move the focused window to the adjacent workspace above."
        ),
        .init(
            commandWords: ["move-to-workspace", "down"],
            name: .workspace(.moveDown),
            summary: "Move the focused window to the adjacent workspace below."
        ),
        .init(
            commandWords: ["move-to-workspace", "on-monitor"],
            name: .workspace(.moveToOnMonitor),
            summary: "Move the focused window to a workspace already assigned to the requested adjacent monitor.",
            arguments: [.workspaceNumber, .direction]
        ),
        .init(
            commandWords: ["move-to-workspace", "slot"],
            name: .workspace(.moveToSlot),
            summary: "Move the focused window to the workspace at a one-based position in the interaction monitor's workspace list.",
            arguments: [.slotNumber]
        ),
        .init(
            name: .workspace(.moveToMonitor),
            summary: "Move the focused window to the active workspace on the adjacent monitor.",
            arguments: [.direction]
        ),
        .init(
            commandWords: ["focus-monitor", "prev"],
            name: .monitorFocus(.previous),
            summary: "Move interaction focus to the previous monitor."
        ),
        .init(
            commandWords: ["focus-monitor", "next"],
            name: .monitorFocus(.next),
            summary: "Move interaction focus to the next monitor."
        ),
        .init(
            commandWords: ["focus-monitor", "last"],
            name: .monitorFocus(.last),
            summary: "Move interaction focus back to the previous monitor."
        ),
        .init(
            name: .column(.move),
            summary: "Move a Niri column horizontally or a complete Dwindle tile/group without monitor fallback.",
            arguments: [.direction]
        ),
        .init(
            name: .column(.moveToFirst),
            summary: "Move the focused Niri column to the first position.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .column(.moveToLast),
            summary: "Move the focused Niri column to the last position.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .column(.moveToIndex),
            summary: "Move the focused Niri column to a one-based index.",
            arguments: [.columnIndex],
            layoutCompatibility: .niri
        ),
        .init(
            name: .column(.moveToWorkspace),
            summary: "Move the focused Niri column to a Niri workspace by workspace ID.",
            arguments: [.workspaceNumber],
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["move-column-to-workspace", "up"],
            name: .column(.moveToWorkspaceUp),
            summary: "Move the focused Niri column to the adjacent workspace above.",
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["move-column-to-workspace", "down"],
            name: .column(.moveToWorkspaceDown),
            summary: "Move the focused Niri column to the adjacent workspace below.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .column(.toggleTabbed),
            summary: "Toggle tabbed mode for the focused Niri column.",
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["cycle-size", "forward"],
            name: .sizing(.cycleSizeForward),
            summary: "Cycle layout sizing presets forward."
        ),
        .init(
            commandWords: ["cycle-size", "backward"],
            name: .sizing(.cycleSizeBackward),
            summary: "Cycle layout sizing presets backward."
        ),
        .init(
            commandWords: ["cycle-window-primary-span", "forward"],
            name: .sizing(.cycleWindowPrimarySpanForward),
            summary: "Cycle Niri window primary-span presets forward.",
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["cycle-window-primary-span", "backward"],
            name: .sizing(.cycleWindowPrimarySpanBackward),
            summary: "Cycle Niri window primary-span presets backward.",
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["cycle-window-secondary-span", "forward"],
            name: .sizing(.cycleWindowSecondarySpanForward),
            summary: "Cycle Niri window secondary-span presets forward.",
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["cycle-window-secondary-span", "backward"],
            name: .sizing(.cycleWindowSecondarySpanBackward),
            summary: "Cycle Niri window secondary-span presets backward.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.toggleContainerFullPrimarySpan),
            summary: "Toggle full-primary-span mode for the focused Niri container.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.expandContainerToAvailablePrimarySpan),
            summary: "Expand the focused Niri container into available primary-axis space.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.resetWindowSecondarySpan),
            summary: "Reset the focused Niri window secondary span.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.setContainerPrimarySpan),
            summary: "Set or adjust the focused Niri container primary span.",
            arguments: [.sizeChange],
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.setWindowPrimarySpan),
            summary: "Set or adjust the focused Niri window primary span.",
            arguments: [.sizeChange],
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.setWindowSecondarySpan),
            summary: "Set or adjust the focused Niri window secondary span.",
            arguments: [.sizeChange],
            layoutCompatibility: .niri
        ),
        .init(
            name: .swapWorkspaceWithMonitor,
            summary: "Swap the active workspace with the active workspace on an adjacent monitor.",
            arguments: [.direction]
        ),
        .init(
            name: .dwindle(.balanceSizes),
            summary: "Balance layout sizes in the active workspace."
        ),
        .init(
            name: .dwindle(.moveToRoot),
            summary: "Move the selected Dwindle window to the root split.",
            layoutCompatibility: .dwindle
        ),
        .init(
            name: .dwindle(.toggleSplit),
            summary: "Toggle the active Dwindle split orientation.",
            layoutCompatibility: .dwindle
        ),
        .init(
            name: .dwindle(.swapSplit),
            summary: "Swap the active Dwindle split.",
            layoutCompatibility: .dwindle
        ),
        .init(
            name: .dwindle(.resize),
            summary: "Resize the selected Dwindle window.",
            arguments: [.resizeAxis, .resizeOperation],
            layoutCompatibility: .dwindle
        ),
        .init(
            name: .dwindle(.resizeFocused),
            summary: "Grow or shrink the focused Dwindle window.",
            arguments: [.resizeOperation],
            layoutCompatibility: .dwindle
        ),
        .init(
            name: .dwindle(.preselect),
            summary: "Set the Dwindle preselection direction.",
            arguments: [.direction],
            layoutCompatibility: .dwindle
        ),
        .init(
            commandWords: ["preselect", "clear"],
            name: .dwindle(.preselectClear),
            summary: "Clear the Dwindle preselection.",
            layoutCompatibility: .dwindle
        ),
        .init(
            name: .openCommandPalette,
            summary: "Toggle the command palette."
        ),
        .init(
            name: .raiseAllFloatingWindows,
            summary: "Raise all visible floating windows."
        ),
        .init(
            name: .toggleFloatingFocus,
            summary: "Toggle focus between the floating and tiled windows of the active workspace."
        ),
        .init(
            name: .rescueOffscreenWindows,
            summary: "Clamp tracked floating windows back onto their visible monitors."
        ),
        .init(
            name: .windowState(.toggleFloating),
            summary: "Toggle the focused managed window between tiled and floating."
        ),
        .init(
            name: .windowState(.close),
            summary: "Close the focused managed window through its close button."
        ),
        .init(
            commandWords: ["scratchpad", "assign"],
            name: .scratchpad(.assign),
            summary: "Assign the focused managed window to a scratchpad, or remove it when already there.",
            arguments: [.scratchpadIndex]
        ),
        .init(
            commandWords: ["scratchpad", "toggle"],
            name: .scratchpad(.toggle),
            summary: "Show or hide a scratchpad's windows.",
            arguments: [.scratchpadIndex]
        ),
        .init(
            name: .openMenuAnywhere,
            summary: "Open the menu surface anywhere."
        ),
        .init(
            name: .presentation(.workspaceBar),
            summary: "Toggle runtime workspace bar visibility."
        ),
        .init(
            commandWords: ["hidden-bar", "panel"],
            name: .presentation(.hiddenBar),
            summary: "Toggle the hidden-bar items panel."
        ),
        .init(
            name: .presentation(.quakeTerminal),
            summary: "Toggle the configured Quake terminal."
        ),
        .init(
            name: .workspaceLayout(.toggle),
            summary: "Toggle the current workspace between Niri and Dwindle."
        ),
        .init(
            name: .workspaceLayout(.set),
            summary: "Set the current workspace layout explicitly.",
            arguments: [.layout]
        ),
        .init(
            name: .fullscreen(.managed),
            summary: "Toggle OmniWM-managed fullscreen."
        ),
        .init(
            name: .fullscreen(.native),
            summary: "Toggle native macOS fullscreen."
        ),
        .init(
            name: .presentation(.overview),
            summary: "Toggle the overview surface."
        ),
        .init(
            name: .presentation(.systemStats),
            summary: "Toggle the system stats popup when a workspace-bar System Stats button is available."
        )
    ]
}
