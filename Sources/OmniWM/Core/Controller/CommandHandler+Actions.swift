// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension CommandHandler {
    func perform(_ action: FocusNavigationAction, controller: WMController) -> ExternalCommandResult {
        switch action {
        case .previous:
            controller.niriLayoutHandler.focusPreviousInNiri(observation: .init(
                frontmostAppPidProvider: frontmostAppPidProvider,
                frontmostFocusedWindowTokenProvider: frontmostFocusedWindowTokenProvider
            ))
        case .downOrLeft:
            controller.niriLayoutHandler.focusDownOrLeftInNiri()
        case .upOrRight:
            controller.niriLayoutHandler.focusUpOrRightInNiri()
        case let .windowInColumn(index):
            controller.niriLayoutHandler.focusWindowInColumnInNiri(index: index)
        case .windowTop:
            controller.niriLayoutHandler.focusWindowTopInNiri()
        case .windowBottom:
            controller.niriLayoutHandler.focusWindowBottomInNiri()
        case .windowDownOrTop:
            focusWindowWrapping(direction: .down)
        case .windowUpOrBottom:
            focusWindowWrapping(direction: .up)
        case .windowOrWorkspaceDown:
            controller.niriLayoutHandler.focusWindowOrWorkspaceInNiri(direction: .down)
        case .windowOrWorkspaceUp:
            controller.niriLayoutHandler.focusWindowOrWorkspaceInNiri(direction: .up)
        case .columnFirst:
            controller.niriLayoutHandler.focusColumnFirstInNiri()
        case .columnLast:
            controller.niriLayoutHandler.focusColumnLastInNiri()
        case let .column(index):
            controller.niriLayoutHandler.focusColumnInNiri(index: index)
        case .centerColumn:
            controller.niriLayoutHandler.centerColumn()
        case .centerVisibleColumns:
            controller.niriLayoutHandler.centerVisibleColumns()
        }
        return .executed
    }

    func perform(_ action: WorkspaceAction, source: Source, controller: WMController) -> ExternalCommandResult {
        if detachesWindow(action), let token = controller.focusedManagedTokenForCommand(),
           controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role.parent != nil
        {
            return .attachedWindow
        }
        let navigation = controller.workspaceNavigationHandler
        switch action {
        case let .moveToMonitor(direction):
            return navigation.moveWindowToMonitor(direction: direction)
        case let .moveTo(index):
            return navigation.moveFocusedWindow(toWorkspaceIndex: index)
        case let .moveToOnMonitor(index, direction):
            return navigation.moveFocusedWindow(toWorkspaceIndex: index, onMonitor: direction)
        case .moveUp,
             .moveDown:
            return navigation.moveWindowToAdjacentWorkspace(direction: action == .moveUp ? .up : .down)
        case let .switchTo(number),
             let .switchSlot(number):
            let autoBackAndForth = source == .shortcut && controller.settings.workspaces.autoBackAndForth
            if case .switchTo = action {
                return navigation.switchWorkspace(index: number, autoBackAndForth: autoBackAndForth)
            }
            return navigation.switchWorkspaceSlotResult(number, autoBackAndForth: autoBackAndForth)
        case let .switchAnywhere(index):
            return navigation.switchWorkspace(index: index, anywhere: true)
        case let .moveToSlot(slot):
            return navigation.moveFocusedWindowToWorkspaceSlot(slot)
        case .next,
             .previous,
             .backAndForth:
            return switchRelative(action, navigation: navigation, controller: controller)
        case let .moveWorkspaceToMonitor(direction):
            moveActiveWorkspace(toMonitor: direction, controller: controller)
        case let .swapWithMonitor(direction):
            return navigation.swapCurrentWorkspaceWithMonitor(direction: direction)
        case .toggleLayout:
            return toggleWorkspaceLayout()
        case let .setLayout(layout):
            return setWorkspaceLayout(layout)
        }
        return .executed
    }

    @inline(__always)
    private func switchRelative(
        _ action: WorkspaceAction,
        navigation: WorkspaceNavigationHandler,
        controller: WMController
    ) -> ExternalCommandResult {
        let origin = if action == .backAndForth {
            navigation.workspaceBackAndForth()
        } else {
            navigation.switchWorkspaceRelative(
                isNext: action == .next,
                wrapAround: controller.settings.workspaces.switchWrapAroundUntracked,
                interactionOrigin: .init(id: controller.activeWorkspace()?.id)
            )
        }
        guard let origin else { return .noChange }
        return controller.activeWorkspace()?.id == origin.id ? .noChange : .executed
    }

    private func detachesWindow(_ action: WorkspaceAction) -> Bool {
        switch action {
        case .moveToMonitor,
             .moveTo,
             .moveToOnMonitor,
             .moveUp,
             .moveDown,
             .moveToSlot:
            true
        case .switchTo,
             .switchAnywhere,
             .setLayout,
             .switchSlot,
             .next,
             .previous,
             .moveWorkspaceToMonitor,
             .swapWithMonitor,
             .backAndForth,
             .toggleLayout:
            false
        }
    }

    private func moveActiveWorkspace(toMonitor direction: Direction, controller: WMController) {
        guard let workspaceId = controller.activeWorkspace()?.id else { return }
        _ = controller.workspaceNavigationHandler.moveWorkspaceToMonitor(workspaceId, direction: direction, force: true)
    }

    func perform(
        _ action: WindowMovementAction,
        controller: WMController,
        widening changeStart: inout NiriLayoutChangeStart?
    ) -> ExternalCommandResult {
        switch action {
        case .down:
            moveWindowWithinContainer(direction: .down)
        case .up:
            moveWindowWithinContainer(direction: .up)
        case .downOrToWorkspaceDown:
            controller.niriLayoutHandler.moveWindowOrToAdjacentWorkspace(direction: .down, widening: &changeStart)
        case .upOrToWorkspaceUp:
            controller.niriLayoutHandler.moveWindowOrToAdjacentWorkspace(direction: .up, widening: &changeStart)
        case .consumeOrExpelLeft:
            controller.niriLayoutHandler.consumeOrExpelWindow(direction: .left)
        case .consumeOrExpelRight:
            controller.niriLayoutHandler.consumeOrExpelWindow(direction: .right)
        case .consumeIntoColumn:
            controller.niriLayoutHandler.consumeWindowIntoColumn()
        case .expelFromColumn:
            controller.niriLayoutHandler.expelWindowFromColumn()
        }
        return .executed
    }

    func perform(_ action: ColumnAction, controller: WMController) -> ExternalCommandResult {
        switch action {
        case let .moveToWorkspace(index):
            controller.workspaceNavigationHandler.moveColumnToWorkspaceByIndex(index: index)
        case .moveToWorkspaceUp:
            controller.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(direction: .up)
        case .moveToWorkspaceDown:
            controller.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(direction: .down)
        case .moveToFirst:
            controller.niriLayoutHandler.moveColumnToFirst()
        case .moveToLast:
            controller.niriLayoutHandler.moveColumnToLast()
        case let .moveToIndex(index):
            controller.niriLayoutHandler.moveColumn(toOneBasedIndex: index)
        case .toggleTabbed:
            toggleColumnTabbedInNiri()
        }
        return .executed
    }

    func perform(_ action: IPCMonitorFocusCommand, controller: WMController) -> ExternalCommandResult {
        let changed = switch action {
        case .previous: controller.workspaceNavigationHandler.focusMonitorCyclic(previous: true)
        case .next: controller.workspaceNavigationHandler.focusMonitorCyclic(previous: false)
        case .last: controller.workspaceNavigationHandler.focusLastMonitor()
        }
        return changed ? .executed : .noChange
    }

    func perform(_ action: IPCFullscreenCommand, controller: WMController) -> ExternalCommandResult {
        if let token = controller.focusedManagedTokenForCommand(),
           controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role.parent != nil
        {
            return .attachedWindow
        }
        switch action {
        case .managed:
            toggleFullscreen()
        case .native:
            toggleNativeFullscreenForFocused()
        }
        return .executed
    }

    func perform(_ action: SizingAction, controller: WMController) -> ExternalCommandResult {
        switch action {
        case .cycleSizeForward:
            layoutHandler(as: LayoutSizable.self)?.cycleSize(forward: true)
        case .cycleSizeBackward:
            layoutHandler(as: LayoutSizable.self)?.cycleSize(forward: false)
        case .cycleWindowPrimarySpanForward:
            controller.niriLayoutHandler.cycleWindowPrimarySpan(forward: true)
        case .cycleWindowPrimarySpanBackward:
            controller.niriLayoutHandler.cycleWindowPrimarySpan(forward: false)
        case .cycleWindowSecondarySpanForward:
            controller.niriLayoutHandler.cycleWindowSecondarySpan(forward: true)
        case .cycleWindowSecondarySpanBackward:
            controller.niriLayoutHandler.cycleWindowSecondarySpan(forward: false)
        case .toggleContainerFullPrimarySpan:
            controller.niriLayoutHandler.toggleContainerFullPrimarySpan()
        case .expandContainerToAvailablePrimarySpan:
            controller.niriLayoutHandler.expandContainerToAvailablePrimarySpan()
        case .resetWindowSecondarySpan:
            controller.niriLayoutHandler.resetWindowSecondarySpan()
        case let .resizeContainerPrimarySpan(grow):
            controller.niriLayoutHandler.setContainerPrimarySpan(
                niriResizeChange(grow: grow, controller: controller)
            )
        case let .resizeWindowPrimarySpan(grow):
            controller.niriLayoutHandler.setWindowPrimarySpan(
                niriResizeChange(grow: grow, controller: controller)
            )
        case let .resizeWindowSecondarySpan(grow):
            controller.niriLayoutHandler.setWindowSecondarySpan(
                niriResizeChange(grow: grow, controller: controller)
            )
        case let .setContainerPrimarySpan(change):
            controller.niriLayoutHandler.setContainerPrimarySpan(change)
        case let .setWindowPrimarySpan(change):
            controller.niriLayoutHandler.setWindowPrimarySpan(change)
        case let .setWindowSecondarySpan(change):
            controller.niriLayoutHandler.setWindowSecondarySpan(change)
        case .balanceSizes:
            layoutHandler(as: LayoutSizable.self)?.balanceSizes()
        case .undo:
            stepLayoutHistory(undo: true, controller: controller)
        case .redo:
            stepLayoutHistory(undo: false, controller: controller)
        }
        return .executed
    }

    private func stepLayoutHistory(undo: Bool, controller: WMController) {
        let niri = controller.niriLayoutHandler
        guard let workspaceId = niri.layoutHistoryWorkspaceId() else { return }
        if controller.workspaceManager.activeLayoutKind(for: workspaceId) == .dwindle {
            controller.dwindleLayoutHandler.stepLayoutHistory(undo ? .undo : .redo, in: workspaceId)
        } else {
            niri.stepLayoutHistory(undo ? .undo : .redo, in: workspaceId)
        }
    }

    private func niriResizeChange(grow: Bool, controller: WMController) -> NiriSizeChange {
        .adjustProportion(CGFloat(controller.settings.niri.resizeStepPercent) * (grow ? 1 : -1))
    }

    func perform(_ action: DwindleAction, controller: WMController) -> ExternalCommandResult {
        let changed = switch action {
        case .moveToRoot:
            controller.dwindleLayoutHandler.moveToRootInDwindle()
        case .toggleSplit:
            controller.dwindleLayoutHandler.toggleSplitInDwindle()
        case .swapSplit:
            controller.dwindleLayoutHandler.swapSplitInDwindle()
        case let .resizeAlongAxis(orientation, grow):
            controller.dwindleLayoutHandler.resizeAlongAxisInDwindle(orientation: orientation, grow: grow)
        case let .resizeFocusedWindow(grow):
            controller.dwindleLayoutHandler.resizeFocusedWindowInDwindle(grow: grow)
        case let .preselect(direction):
            controller.dwindleLayoutHandler.preselectInDwindle(direction: direction)
        case .preselectClear:
            controller.dwindleLayoutHandler.clearPreselectInDwindle()
        }
        return changed ? .executed : .noChange
    }

    func perform(_ action: ScratchpadAction, controller: WMController) -> ExternalCommandResult {
        switch action {
        case let .assign(index):
            guard let index = ScratchpadIndex(index) else { return .invalidArguments }
            return controller.assignFocusedWindowToScratchpad(index)
        case let .toggle(index):
            guard let index = ScratchpadIndex(index) else { return .invalidArguments }
            return controller.toggleScratchpad(index)
        }
    }

    func perform(_ action: IPCMediaCommand, controller: WMController) {
        switch action {
        case .volumeUp:
            ShellAudio.perform(.change(percent: ShellVolumeCommand.step), appVolumes: controller.appVolumeMixer)
        case .volumeDown:
            ShellAudio.perform(.change(percent: -ShellVolumeCommand.step), appVolumes: controller.appVolumeMixer)
        case .volumeMute:
            ShellAudio.perform(.toggleMute, appVolumes: controller.appVolumeMixer)
        case .playPause:
            controller.mediaController.perform(.toggle)
        case .next:
            controller.mediaController.perform(.next)
        case .previous:
            controller.mediaController.perform(.previous)
        }
    }

    func perform(_ action: IPCPresentationCommand, controller: WMController) -> ExternalCommandResult {
        switch action {
        case .workspaceBar:
            controller.toggleWorkspaceBarVisibility()
        case .hiddenBar:
            controller.toggleHiddenBarPanel()
        case .quakeTerminal:
            guard controller.settings.quakeTerminal.enabled else { return .ignoredDisabled }
            controller.toggleQuakeTerminal()
        case .overview:
            guard controller.settings.overview.enabled else { return .ignoredDisabled }
            controller.toggleOverview()
        case .systemStats:
            controller.toggleSystemStats()
        }
        return .executed
    }

    func toggleColumnTabbedInNiri() {
        controller?.niriLayoutHandler.toggleColumnTabbed(target: .focused)
    }
}
