// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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

    func perform(_ action: WorkspaceAction, controller: WMController) -> ExternalCommandResult {
        switch action {
        case let .moveToMonitor(direction):
            controller.workspaceNavigationHandler.moveWindowToMonitor(direction: direction)
        case let .moveTo(index):
            controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceIndex: index)
        case .moveUp:
            controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .up)
        case .moveDown:
            controller.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(direction: .down)
        case let .switchTo(index):
            controller.workspaceNavigationHandler.switchWorkspace(index: index)
        case let .switchSlot(slot):
            controller.workspaceNavigationHandler.switchWorkspaceSlot(slot)
        case let .moveToSlot(slot):
            controller.workspaceNavigationHandler.moveFocusedWindow(toWorkspaceSlot: slot)
        case .next:
            controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
        case .previous:
            controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: false)
        case let .moveWorkspaceToMonitor(direction):
            if let workspaceId = controller.activeWorkspace()?.id {
                _ = controller.workspaceNavigationHandler.moveWorkspaceToMonitor(
                    workspaceId,
                    direction: direction,
                    force: true
                )
            }
        case let .swapWithMonitor(direction):
            controller.workspaceNavigationHandler.swapCurrentWorkspaceWithMonitor(direction: direction)
        case .backAndForth:
            controller.workspaceNavigationHandler.workspaceBackAndForth()
        case .toggleLayout:
            toggleWorkspaceLayout()
        case .toggleAccordion:
            toggleAccordion()
        }
        return .executed
    }

    func perform(_ action: WindowMovementAction, controller: WMController) -> ExternalCommandResult {
        switch action {
        case .down:
            moveWindowWithinContainer(direction: .down)
        case .up:
            moveWindowWithinContainer(direction: .up)
        case .downOrToWorkspaceDown:
            controller.niriLayoutHandler.moveWindowOrToAdjacentWorkspace(direction: .down)
        case .upOrToWorkspaceUp:
            controller.niriLayoutHandler.moveWindowOrToAdjacentWorkspace(direction: .up)
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
        switch action {
        case .previous:
            controller.workspaceNavigationHandler.focusMonitorCyclic(previous: true)
        case .next:
            controller.workspaceNavigationHandler.focusMonitorCyclic(previous: false)
        case .last:
            controller.workspaceNavigationHandler.focusLastMonitor()
        }
        return .executed
    }

    func perform(_ action: IPCFullscreenCommand, controller: WMController) -> ExternalCommandResult {
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
        }
        return .executed
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
        guard let controller else { return }
        controller.niriLayoutHandler.withNiriWorkspaceContext { engine, wsId, motion, state, _, _, _, orientation in
            if engine.toggleColumnTabbed(
                in: wsId,
                state: state,
                motion: motion,
                orientation: orientation
            ) {
                controller.workspaceManager.recordReconcileEvent(
                    .layoutOperationPerformed(workspaceId: wsId, operation: .displayModeChanged, source: .command)
                )
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
                if engine.hasAnyWindowAnimationsRunning(in: wsId) {
                    controller.layoutRefreshController.startScrollAnimation(for: wsId)
                }
                controller.niriLayoutHandler.showColumnModeToast(
                    engine: engine,
                    workspaceId: wsId,
                    state: state,
                    motion: motion
                )
            }
        }
    }
}
