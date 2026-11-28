// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

extension IPCAutomationManifest {
    public static let commandDescriptors = IPCCommandForm.all.map { form in
        IPCCommandDescriptor(
            commandWords: form.commandWords,
            name: form.name,
            summary: commandSummary(for: form),
            arguments: form.arguments.map { argumentDescriptor(for: $0, command: form.name) },
            layoutCompatibility: form.layoutCompatibility
        )
    }

    private static func commandSummary(for form: IPCCommandForm) -> String {
        if form.name == .windowSwitcher, form.arguments.contains(.switcherScope) {
            return "Open the window switcher in a scope, or move its selection if open; releasing the modifiers commits."
        }
        guard let summary = commandSummaries[form.name] else {
            preconditionFailure("Missing command summary for \(form.name.rawValue)")
        }
        return summary
    }

    private static func argumentDescriptor(
        for kind: IPCCommandArgumentKind,
        command: IPCCommandName
    ) -> IPCCommandArgumentDescriptor {
        switch kind {
        case .appID: .appID
        case .direction: .direction
        case .columnIndex: .columnIndex
        case .windowIndex: .windowIndex
        case .scratchpadIndex: .scratchpadIndex
        case .visibleContainerCount: .visibleContainerCount
        case .layout: .layout
        case .paletteMode: .paletteMode
        case .switcherDirection: .switcherDirection
        case .switcherScope: .switcherScope
        case .resizeAxis: .resizeAxis
        case .resizeOperation: .resizeOperation
        case .sizeChange: .sizeChange
        case .workspaceNumber:
            switch command {
            case .workspace(.switchSlot),
                 .workspace(.moveToSlot): .slotNumber
            default: .workspaceNumber
            }
        }
    }

    private static let commandSummaries: [IPCCommandName: String] = [
        .focus(.spatial): "Focus spatially; Dwindle Up/Down traverse grouped tabs before edge fallback.",
        .focus(.previous): "Focus the previously focused window.",
        .focus(.downOrLeft): "Traverse backward through the active Niri workspace.",
        .focus(.upOrRight): "Traverse forward through the active Niri workspace.",
        .focus(.windowInColumn): "Focus a window in the focused Niri column by one-based index.",
        .focus(.windowTop): "Focus the top window in the focused Niri column.",
        .focus(.windowBottom): "Focus the bottom window in the focused Niri column.",
        .focus(.windowDownOrTop): "Focus the next window in the active Niri column or Dwindle group, wrapping to the top.",
        .focus(.windowUpOrBottom): "Focus the previous window in the active Niri column or Dwindle group, wrapping to the bottom.",
        .focus(.windowOrWorkspaceDown): "Focus down using the active Niri orientation; if no target exists, switch without wrapping to the workspace below.",
        .focus(.windowOrWorkspaceUp): "Focus up using the active Niri orientation; if no target exists, switch without wrapping to the workspace above.",
        .focus(.column): "Focus a Niri column by one-based index.",
        .focus(.columnFirst): "Focus the first Niri column.",
        .focus(.columnLast): "Focus the last Niri column.",
        .focus(.centerColumn): "Center the focused Niri column without changing focus.",
        .focus(.centerVisibleColumns): "Center the current block of fully visible Niri columns in the viewport.",
        .windowMovement(.spatial): "Move with layout-aware consume/expel or Dwindle join/extract behavior.",
        .windowMovement(.down): "Reorder the focused window down by one without wrapping within its Niri column or Dwindle group.",
        .windowMovement(.up): "Reorder the focused window up by one without wrapping within its Niri column or Dwindle group.",
        .windowMovement(.downOrToWorkspaceDown): "Move the focused Niri window down, or to the workspace below at the column edge.",
        .windowMovement(.upOrToWorkspaceUp): "Move the focused Niri window up, or to the workspace above at the column edge.",
        .windowMovement(.consumeOrExpelLeft): "Consume the focused Niri window into the column to the left, or expel it left from its column.",
        .windowMovement(.consumeOrExpelRight): "Consume the focused Niri window into the column to the right, or expel it right from its column.",
        .windowMovement(.consumeIntoColumn): "Consume the top window from the next Niri column into the focused column.",
        .windowMovement(.expelFromColumn): "Expel the bottom window from the focused Niri column into a new following column.",
        .workspace(.switchTo): "Switch to a workspace by workspace ID on its assigned monitor.",
        .workspace(.next): "Switch to the next workspace on the current monitor.",
        .workspace(.previous): "Switch to the previous workspace on the current monitor.",
        .workspace(.backAndForth): "Switch to the previously active workspace on the current monitor.",
        .workspace(.switchAnywhere): "Focus a workspace by workspace ID across all monitors.",
        .workspace(.switchSlot): "Switch to the workspace at a one-based position in the interaction monitor's workspace list.",
        .workspace(.moveTo): "Move the focused window to a workspace by workspace ID.",
        .workspace(.moveUp): "Move the focused window to the adjacent workspace above.",
        .workspace(.moveDown): "Move the focused window to the adjacent workspace below.",
        .workspace(.moveToOnMonitor): "Move the focused window to a workspace already assigned to the requested adjacent monitor.",
        .workspace(.moveToSlot): "Move the focused window to the workspace at a one-based position in the interaction monitor's workspace list.",
        .workspace(.moveToMonitor): "Move the focused window to the active workspace on the adjacent monitor.",
        .monitorFocus(.previous): "Move interaction focus to the previous monitor.",
        .monitorFocus(.next): "Move interaction focus to the next monitor.",
        .monitorFocus(.last): "Move interaction focus back to the previous monitor.",
        .column(.move): "Move a Niri column horizontally or a complete Dwindle tile/group without monitor fallback.",
        .column(.moveToFirst): "Move the focused Niri column to the first position.",
        .column(.moveToLast): "Move the focused Niri column to the last position.",
        .column(.moveToIndex): "Move the focused Niri column to a one-based index.",
        .column(.moveToWorkspace): "Move the focused Niri column to a Niri workspace by workspace ID.",
        .column(.moveToWorkspaceUp): "Move the focused Niri column to the adjacent workspace above.",
        .column(.moveToWorkspaceDown): "Move the focused Niri column to the adjacent workspace below.",
        .column(.toggleTabbed): "Toggle tabbed mode for the focused Niri column.",
        .sizing(.cycleSizeForward): "Cycle layout sizing presets forward.",
        .sizing(.cycleSizeBackward): "Cycle layout sizing presets backward.",
        .sizing(.cycleWindowPrimarySpanForward): "Cycle Niri window primary-span presets forward.",
        .sizing(.cycleWindowPrimarySpanBackward): "Cycle Niri window primary-span presets backward.",
        .sizing(.cycleWindowSecondarySpanForward): "Cycle Niri window secondary-span presets forward.",
        .sizing(.cycleWindowSecondarySpanBackward): "Cycle Niri window secondary-span presets backward.",
        .sizing(.toggleContainerFullPrimarySpan): "Toggle full-primary-span mode for the focused Niri container.",
        .sizing(.expandContainerToAvailablePrimarySpan): "Expand the focused Niri container into available primary-axis space.",
        .sizing(.resetWindowSecondarySpan): "Reset the focused Niri window secondary span.",
        .sizing(.setContainerPrimarySpan): "Set or adjust the focused Niri container primary span.",
        .sizing(.setWindowPrimarySpan): "Set or adjust the focused Niri window primary span.",
        .sizing(.setWindowSecondarySpan): "Set or adjust the focused Niri window secondary span.",
        .sizing(.setVisibleContainers): "Set how many Niri columns fit on screen, or 0 for Off, as the Visible Containers setting does.",
        .swapWorkspaceWithMonitor: "Swap the active workspace with the active workspace on an adjacent monitor.",
        .dwindle(.balanceSizes): "Balance layout sizes in the active workspace.",
        .dwindle(.moveToRoot): "Move the selected Dwindle window to the root split.",
        .dwindle(.toggleSplit): "Toggle the active Dwindle split orientation.",
        .dwindle(.swapSplit): "Swap the active Dwindle split.",
        .dwindle(.resize): "Resize the selected Dwindle window.",
        .dwindle(.resizeFocused): "Grow or shrink the focused Dwindle window.",
        .dwindle(.resizeDirection): "Move the focused Dwindle window's right or bottom border toward a direction, or its opposite border when it has none.",
        .dwindle(.preselect): "Set the Dwindle preselection direction.",
        .dwindle(.preselectClear): "Clear the Dwindle preselection.",
        .openCommandPalette: "Toggle the command palette.",
        .openCommandPaletteMode: "Open the command palette in a mode; switch to it if open, close it if already there.",
        .windowSwitcher: "Open the window switcher, or move its selection if open; releasing the modifiers commits.",
        .raiseAllFloatingWindows: "Raise all visible floating windows.",
        .toggleFloatingFocus: "Toggle focus between the floating and tiled windows of the active workspace.",
        .rescueOffscreenWindows: "Clamp tracked floating windows back onto their visible monitors.",
        .windowState(.toggleFloating): "Toggle the focused managed window between tiled and floating.",
        .windowState(.close): "Close the focused managed window through its close button.",
        .scratchpad(.assign): "Assign the focused managed window to a scratchpad, or remove it when already there.",
        .scratchpad(.toggle): "Show or hide a scratchpad's windows.",
        .openMenuAnywhere: "Open the menu surface anywhere.",
        .openSettings: "Open OmniWM Settings, or bring it forward if it's open.",
        .presentation(.workspaceBar): "Toggle runtime workspace bar visibility.",
        .presentation(.hiddenBar): "Toggle the hidden-bar items panel.",
        .presentation(.quakeTerminal): "Toggle the configured Quake terminal.",
        .workspaceLayout(.toggle): "Toggle the current workspace between Niri and Dwindle.",
        .workspaceLayout(.set): "Set the current workspace layout explicitly.",
        .fullscreen(.managed): "Toggle OmniWM-managed fullscreen.",
        .fullscreen(.native): "Toggle native macOS fullscreen.",
        .presentation(.overview): "Toggle the overview surface.",
        .presentation(.systemStats): "Toggle the system stats popup when a workspace-bar System Stats button is available.",
        .media(.volumeUp): "Raise the output volume by one step.",
        .media(.volumeDown): "Lower the output volume by one step.",
        .media(.volumeMute): "Mute or unmute the output.",
        .media(.playPause): "Play or pause what is playing.",
        .media(.next): "Skip to the next track.",
        .media(.previous): "Go back to the previous track.",
        .keyboardMode(.togglePause): "Pause or resume OmniWM shortcuts so their keys reach the focused app.",
        .keyboardMode(.beginPrefix): "Arm the prefix: the next mode key runs its OmniWM command.",
        .keyboardMode(.toggleWindowMode): "Enter or leave Window mode, where mode keys run OmniWM commands until Escape.",
        .keyboardMode(.exit): "Leave Pause, Prefix, or Window mode.",
        .shellAppOpen: "Open or focus a hosted OmniShell app window.",
        .shellAppNewWindow: "Create a new hosted OmniShell app window."
    ]
}
