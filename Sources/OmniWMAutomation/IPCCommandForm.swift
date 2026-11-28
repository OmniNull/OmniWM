// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCAutomationLayoutCompatibility: String, Codable, CaseIterable, Equatable, Sendable {
    case shared
    case niri
    case dwindle
}

package struct IPCCommandForm: Sendable {
    package let name: IPCCommandName
    package let commandWords: [String]
    package let arguments: [IPCCommandArgumentKind]
    package let layoutCompatibility: IPCAutomationLayoutCompatibility

    private init(
        _ name: IPCCommandName,
        words: [String]? = nil,
        arguments: [IPCCommandArgumentKind] = [],
        layoutCompatibility: IPCAutomationLayoutCompatibility = .shared
    ) {
        self.name = name
        commandWords = words ?? [name.rawValue]
        self.arguments = arguments
        self.layoutCompatibility = layoutCompatibility
    }

    package static let all: [Self] = [
        .init(.focus(.spatial), arguments: [.direction]),
        .init(.focus(.previous), words: ["focus", "previous"]),
        .init(.focus(.downOrLeft), words: ["focus", "down-or-left"], layoutCompatibility: .niri),
        .init(.focus(.upOrRight), words: ["focus", "up-or-right"], layoutCompatibility: .niri),
        .init(.focus(.windowInColumn), arguments: [.windowIndex], layoutCompatibility: .niri),
        .init(.focus(.windowTop), words: ["focus-window", "top"], layoutCompatibility: .niri),
        .init(.focus(.windowBottom), words: ["focus-window", "bottom"], layoutCompatibility: .niri),
        .init(.focus(.windowDownOrTop), words: ["focus-window", "down-or-top"]),
        .init(.focus(.windowUpOrBottom), words: ["focus-window", "up-or-bottom"]),
        .init(.focus(.windowOrWorkspaceDown), layoutCompatibility: .niri),
        .init(.focus(.windowOrWorkspaceUp), layoutCompatibility: .niri),
        .init(.focus(.column), arguments: [.columnIndex], layoutCompatibility: .niri),
        .init(.focus(.columnFirst), words: ["focus-column", "first"], layoutCompatibility: .niri),
        .init(.focus(.columnLast), words: ["focus-column", "last"], layoutCompatibility: .niri),
        .init(.focus(.centerColumn), layoutCompatibility: .niri),
        .init(.focus(.centerVisibleColumns), layoutCompatibility: .niri),
        .init(.windowMovement(.spatial), arguments: [.direction]),
        .init(.windowMovement(.down)),
        .init(.windowMovement(.up)),
        .init(.windowMovement(.downOrToWorkspaceDown), layoutCompatibility: .niri),
        .init(.windowMovement(.upOrToWorkspaceUp), layoutCompatibility: .niri),
        .init(.windowMovement(.consumeOrExpelLeft), layoutCompatibility: .niri),
        .init(.windowMovement(.consumeOrExpelRight), layoutCompatibility: .niri),
        .init(.windowMovement(.consumeIntoColumn), layoutCompatibility: .niri),
        .init(.windowMovement(.expelFromColumn), layoutCompatibility: .niri),
        .init(.workspace(.switchTo), arguments: [.workspaceNumber]),
        .init(.workspace(.next), words: ["switch-workspace", "next"]),
        .init(.workspace(.previous), words: ["switch-workspace", "prev"]),
        .init(.workspace(.backAndForth), words: ["switch-workspace", "back-and-forth"]),
        .init(.workspace(.switchAnywhere), words: ["switch-workspace", "anywhere"], arguments: [.workspaceNumber]),
        .init(.workspace(.switchSlot), words: ["switch-workspace", "slot"], arguments: [.workspaceNumber]),
        .init(.workspace(.moveTo), arguments: [.workspaceNumber]),
        .init(.workspace(.moveUp), words: ["move-to-workspace", "up"]),
        .init(.workspace(.moveDown), words: ["move-to-workspace", "down"]),
        .init(
            .workspace(.moveToOnMonitor),
            words: ["move-to-workspace", "on-monitor"],
            arguments: [.workspaceNumber, .direction]
        ),
        .init(.workspace(.moveToSlot), words: ["move-to-workspace", "slot"], arguments: [.workspaceNumber]),
        .init(.workspace(.moveToMonitor), arguments: [.direction]),
        .init(.monitorFocus(.previous), words: ["focus-monitor", "prev"]),
        .init(.monitorFocus(.next), words: ["focus-monitor", "next"]),
        .init(.monitorFocus(.last), words: ["focus-monitor", "last"]),
        .init(.column(.move), arguments: [.direction]),
        .init(.column(.moveToFirst), layoutCompatibility: .niri),
        .init(.column(.moveToLast), layoutCompatibility: .niri),
        .init(.column(.moveToIndex), arguments: [.columnIndex], layoutCompatibility: .niri),
        .init(.column(.moveToWorkspace), arguments: [.workspaceNumber], layoutCompatibility: .niri),
        .init(.column(.moveToWorkspaceUp), words: ["move-column-to-workspace", "up"], layoutCompatibility: .niri),
        .init(.column(.moveToWorkspaceDown), words: ["move-column-to-workspace", "down"], layoutCompatibility: .niri),
        .init(.column(.toggleTabbed), layoutCompatibility: .niri),
        .init(.sizing(.cycleSizeForward), words: ["cycle-size", "forward"]),
        .init(.sizing(.cycleSizeBackward), words: ["cycle-size", "backward"]),
        .init(
            .sizing(.cycleWindowPrimarySpanForward),
            words: ["cycle-window-primary-span", "forward"],
            layoutCompatibility: .niri
        ),
        .init(
            .sizing(.cycleWindowPrimarySpanBackward),
            words: ["cycle-window-primary-span", "backward"],
            layoutCompatibility: .niri
        ),
        .init(
            .sizing(.cycleWindowSecondarySpanForward),
            words: ["cycle-window-secondary-span", "forward"],
            layoutCompatibility: .niri
        ),
        .init(
            .sizing(.cycleWindowSecondarySpanBackward),
            words: ["cycle-window-secondary-span", "backward"],
            layoutCompatibility: .niri
        ),
        .init(.sizing(.toggleContainerFullPrimarySpan), layoutCompatibility: .niri),
        .init(.sizing(.expandContainerToAvailablePrimarySpan), layoutCompatibility: .niri),
        .init(.sizing(.resetWindowSecondarySpan), layoutCompatibility: .niri),
        .init(.sizing(.setContainerPrimarySpan), arguments: [.sizeChange], layoutCompatibility: .niri),
        .init(.sizing(.setWindowPrimarySpan), arguments: [.sizeChange], layoutCompatibility: .niri),
        .init(.sizing(.setWindowSecondarySpan), arguments: [.sizeChange], layoutCompatibility: .niri),
        .init(.sizing(.setVisibleContainers), arguments: [.visibleContainerCount]),
        .init(.swapWorkspaceWithMonitor, arguments: [.direction]),
        .init(.dwindle(.balanceSizes)),
        .init(.dwindle(.moveToRoot), layoutCompatibility: .dwindle),
        .init(.dwindle(.toggleSplit), layoutCompatibility: .dwindle),
        .init(.dwindle(.swapSplit), layoutCompatibility: .dwindle),
        .init(.dwindle(.resize), arguments: [.resizeAxis, .resizeOperation], layoutCompatibility: .dwindle),
        .init(.dwindle(.resizeFocused), arguments: [.resizeOperation], layoutCompatibility: .dwindle),
        .init(.dwindle(.resizeDirection), arguments: [.direction], layoutCompatibility: .dwindle),
        .init(.dwindle(.preselect), arguments: [.direction], layoutCompatibility: .dwindle),
        .init(.dwindle(.preselectClear), words: ["preselect", "clear"], layoutCompatibility: .dwindle),
        .init(.openCommandPalette),
        .init(.openCommandPaletteMode, words: ["open-command-palette"], arguments: [.paletteMode]),
        .init(.windowSwitcher, arguments: [.switcherDirection]),
        .init(.windowSwitcher, arguments: [.switcherDirection, .switcherScope]),
        .init(.raiseAllFloatingWindows),
        .init(.toggleFloatingFocus),
        .init(.rescueOffscreenWindows),
        .init(.windowState(.toggleFloating)),
        .init(.windowState(.close)),
        .init(.scratchpad(.assign), words: ["scratchpad", "assign"], arguments: [.scratchpadIndex]),
        .init(.scratchpad(.toggle), words: ["scratchpad", "toggle"], arguments: [.scratchpadIndex]),
        .init(.openMenuAnywhere),
        .init(.openSettings),
        .init(.presentation(.workspaceBar)),
        .init(.presentation(.hiddenBar), words: ["hidden-bar", "panel"]),
        .init(.presentation(.quakeTerminal)),
        .init(.workspaceLayout(.toggle)),
        .init(.workspaceLayout(.set), arguments: [.layout]),
        .init(.fullscreen(.managed)),
        .init(.fullscreen(.native)),
        .init(.presentation(.overview)),
        .init(.presentation(.systemStats)),
        .init(.media(.volumeUp)),
        .init(.media(.volumeDown)),
        .init(.media(.volumeMute)),
        .init(.media(.playPause)),
        .init(.media(.next)),
        .init(.media(.previous)),
        .init(.keyboardMode(.togglePause)),
        .init(.keyboardMode(.beginPrefix)),
        .init(.keyboardMode(.toggleWindowMode)),
        .init(.keyboardMode(.exit)),
        .init(.shellAppOpen, arguments: [.appID]),
        .init(.shellAppNewWindow, arguments: [.appID])
    ]
}
