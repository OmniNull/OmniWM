// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import OmniWMIPC

extension HotkeyCommand {
    init?(ipc command: IPCFocusCommand) {
        switch command {
        case let .spatial(ipcDirection):
            self = .focus(Direction(ipc: ipcDirection))
        case .previous:
            self = .focusNavigation(.previous)
        case .downOrLeft:
            self = .focusNavigation(.downOrLeft)
        case .upOrRight:
            self = .focusNavigation(.upOrRight)
        case let .windowInColumn(windowIndex):
            guard windowIndex >= 0 else {
                return nil
            }
            self = .focusNavigation(.windowInColumn(windowIndex))
        case .windowTop:
            self = .focusNavigation(.windowTop)
        case .windowBottom:
            self = .focusNavigation(.windowBottom)
        case .windowDownOrTop:
            self = .focusNavigation(.windowDownOrTop)
        case .windowUpOrBottom:
            self = .focusNavigation(.windowUpOrBottom)
        case .windowOrWorkspaceDown:
            self = .focusNavigation(.windowOrWorkspaceDown)
        case .windowOrWorkspaceUp:
            self = .focusNavigation(.windowOrWorkspaceUp)
        case let .column(columnIndex):
            guard let zeroBasedIndex = Self.zeroBasedIndex(from: columnIndex) else {
                return nil
            }
            self = .focusNavigation(.column(zeroBasedIndex))
        case .columnFirst:
            self = .focusNavigation(.columnFirst)
        case .columnLast:
            self = .focusNavigation(.columnLast)
        case .centerColumn:
            self = .focusNavigation(.centerColumn)
        case .centerVisibleColumns:
            self = .focusNavigation(.centerVisibleColumns)
        }
    }

    init(ipc command: IPCWindowMovementCommand) {
        switch command {
        case let .spatial(ipcDirection):
            self = .move(Direction(ipc: ipcDirection))
        case .down:
            self = .windowMovement(.down)
        case .up:
            self = .windowMovement(.up)
        case .downOrToWorkspaceDown:
            self = .windowMovement(.downOrToWorkspaceDown)
        case .upOrToWorkspaceUp:
            self = .windowMovement(.upOrToWorkspaceUp)
        case .consumeOrExpelLeft:
            self = .windowMovement(.consumeOrExpelLeft)
        case .consumeOrExpelRight:
            self = .windowMovement(.consumeOrExpelRight)
        case .consumeIntoColumn:
            self = .windowMovement(.consumeIntoColumn)
        case .expelFromColumn:
            self = .windowMovement(.expelFromColumn)
        }
    }

    init?(ipc command: IPCColumnCommand) {
        switch command {
        case let .move(ipcDirection):
            self = .moveColumn(Direction(ipc: ipcDirection))
        case .moveToFirst:
            self = .column(.moveToFirst)
        case .moveToLast:
            self = .column(.moveToLast)
        case let .moveToIndex(columnIndex):
            guard columnIndex >= 0 else {
                return nil
            }
            self = .column(.moveToIndex(columnIndex))
        case let .moveToWorkspace(workspaceNumber):
            guard let workspaceIndex = Self.zeroBasedIndex(from: workspaceNumber) else {
                return nil
            }
            self = .column(.moveToWorkspace(workspaceIndex))
        case .moveToWorkspaceUp:
            self = .column(.moveToWorkspaceUp)
        case .moveToWorkspaceDown:
            self = .column(.moveToWorkspaceDown)
        case .toggleTabbed:
            self = .column(.toggleTabbed)
        }
    }

    init(ipc command: IPCSizingCommand) {
        switch command {
        case .cycleSizeForward:
            self = .sizing(.cycleSizeForward)
        case .cycleSizeBackward:
            self = .sizing(.cycleSizeBackward)
        case .cycleWindowPrimarySpanForward:
            self = .sizing(.cycleWindowPrimarySpanForward)
        case .cycleWindowPrimarySpanBackward:
            self = .sizing(.cycleWindowPrimarySpanBackward)
        case .cycleWindowSecondarySpanForward:
            self = .sizing(.cycleWindowSecondarySpanForward)
        case .cycleWindowSecondarySpanBackward:
            self = .sizing(.cycleWindowSecondarySpanBackward)
        case .toggleContainerFullPrimarySpan:
            self = .sizing(.toggleContainerFullPrimarySpan)
        case .expandContainerToAvailablePrimarySpan:
            self = .sizing(.expandContainerToAvailablePrimarySpan)
        case .resetWindowSecondarySpan:
            self = .sizing(.resetWindowSecondarySpan)
        case let .setContainerPrimarySpan(change):
            self = .sizing(.setContainerPrimarySpan(NiriSizeChange(ipc: change)))
        case let .setWindowPrimarySpan(change):
            self = .sizing(.setWindowPrimarySpan(NiriSizeChange(ipc: change)))
        case let .setWindowSecondarySpan(change):
            self = .sizing(.setWindowSecondarySpan(NiriSizeChange(ipc: change)))
        }
    }

    init(ipc command: IPCDwindleCommand) {
        switch command {
        case .balanceSizes:
            self = .sizing(.balanceSizes)
        case .moveToRoot:
            self = .dwindle(.moveToRoot)
        case .toggleSplit:
            self = .dwindle(.toggleSplit)
        case .swapSplit:
            self = .dwindle(.swapSplit)
        case let .resize(axis, operation):
            self = .dwindle(.resizeAlongAxis(DwindleOrientation(ipc: axis), operation == .grow))
        case let .resizeFocused(operation):
            self = .dwindle(.resizeFocusedWindow(operation == .grow))
        case let .preselect(ipcDirection):
            self = .dwindle(.preselect(Direction(ipc: ipcDirection)))
        case .preselectClear:
            self = .dwindle(.preselectClear)
        }
    }

    init(ipc command: IPCScratchpadCommand) {
        switch command {
        case let .assign(index):
            self = .scratchpad(.assign(index))
        case let .toggle(index):
            self = .scratchpad(.toggle(index))
        }
    }

    private static func zeroBasedIndex(from oneBasedValue: Int) -> Int? {
        guard oneBasedValue > 0 else { return nil }
        return oneBasedValue - 1
    }
}

extension Direction {
    init(ipc value: IPCDirection) {
        switch value {
        case .left:
            self = .left
        case .right:
            self = .right
        case .up:
            self = .up
        case .down:
            self = .down
        }
    }
}

extension DwindleOrientation {
    init(ipc axis: IPCResizeAxis) {
        switch axis {
        case .horizontal:
            self = .horizontal
        case .vertical:
            self = .vertical
        }
    }
}

extension NiriSizeChange {
    init(ipc change: IPCSizeChange) {
        switch change.kind {
        case .setFixed:
            self = .setFixed(change.value)
        case .setProportion:
            self = .setProportion(change.value)
        case .adjustFixed:
            self = .adjustFixed(change.value)
        case .adjustProportion:
            self = .adjustProportion(change.value)
        }
    }
}

extension LayoutType {
    init(ipc value: IPCWorkspaceLayout) {
        switch value {
        case .defaultLayout:
            self = .defaultLayout
        case .niri:
            self = .niri
        case .dwindle:
            self = .dwindle
        }
    }
}

extension CommandPaletteMode {
    init(ipc value: IPCCommandPaletteMode) {
        switch value {
        case .windows:
            self = .windows
        case .menu:
            self = .menu
        case .clipboard:
            self = .clipboard
        case .commands:
            self = .commands
        case .applications:
            self = .applications
        case .files:
            self = .files
        }
    }
}
