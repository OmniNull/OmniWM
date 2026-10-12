// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore

@MainActor
final class OverviewStructuralActions {
    private(set) weak var wmController: WMController?
    let windowFacts: OverviewWindowFacts

    init(wmController: WMController, windowFacts: OverviewWindowFacts) {
        self.wmController = wmController
        self.windowFacts = windowFacts
    }

    func performStructuralHotkey(
        _ command: HotkeyCommand,
        selectedHandle: WindowHandle
    ) -> StructuralMutationOutcome? {
        guard let wmController,
              let entry = windowFacts.visibleManagedEntry(for: selectedHandle),
              windowFacts.isStructurallyMutable(entry)
        else {
            return .unchanged
        }
        let workspaceId = entry.workspaceId
        let isNiri = wmController.workspaceManager.activeLayoutKind(for: workspaceId) == .niri

        switch command {
        case let .move(direction):
            guard isNiri else { return .unchanged }
            let outcome = wmController.niriLayoutHandler.moveWindow(
                handle: selectedHandle,
                direction: direction
            )
            if case .atWorkspaceEdge = outcome,
               wmController.settings.focus.moveCrossesMonitorAtEdge
            {
                return wmController.workspaceNavigationHandler.moveWindowToMonitor(
                    handle: selectedHandle,
                    direction: direction
                )
            }
            return outcome
        case let .moveColumn(direction):
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveColumn(
                containing: selectedHandle,
                direction: direction
            )
        case let .windowMovement(action):
            return performWindowMovement(
                action,
                selectedHandle: selectedHandle,
                isNiri: isNiri,
                wmController: wmController
            )
        case let .column(action):
            return performColumn(action, selectedHandle: selectedHandle, isNiri: isNiri, wmController: wmController)
        case let .workspace(action):
            return performWorkspace(action, selectedHandle: selectedHandle, isNiri: isNiri, wmController: wmController)
        default:
            return nil
        }
    }

    static func isStructuralHotkey(_ command: HotkeyCommand) -> Bool {
        switch command {
        case .move,
             .workspace(.moveToMonitor),
             .windowMovement(.down),
             .windowMovement(.up),
             .windowMovement(.downOrToWorkspaceDown),
             .windowMovement(.upOrToWorkspaceUp),
             .windowMovement(.consumeIntoColumn),
             .windowMovement(.expelFromColumn),
             .moveColumn,
             .column(.moveToFirst),
             .column(.moveToLast),
             .column(.moveToIndex),
             .workspace(.moveTo),
             .workspace(.moveUp),
             .workspace(.moveDown),
             .column(.moveToWorkspace),
             .column(.moveToWorkspaceUp),
             .column(.moveToWorkspaceDown):
            true
        default:
            false
        }
    }
}

extension OverviewStructuralActions {
    private func performWindowMovement(
        _ action: WindowMovementAction,
        selectedHandle: WindowHandle,
        isNiri: Bool,
        wmController: WMController
    ) -> StructuralMutationOutcome? {
        switch action {
        case .down:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveWindowWithinContainer(
                handle: selectedHandle,
                direction: .down
            )
        case .up:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveWindowWithinContainer(
                handle: selectedHandle,
                direction: .up
            )
        case .downOrToWorkspaceDown:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveWindowOrToAdjacentWorkspace(
                handle: selectedHandle,
                direction: .down
            )
        case .upOrToWorkspaceUp:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveWindowOrToAdjacentWorkspace(
                handle: selectedHandle,
                direction: .up
            )
        case .consumeIntoColumn:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.consumeWindowIntoColumn(containing: selectedHandle)
        case .expelFromColumn:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.expelWindowFromColumn(containing: selectedHandle)
        default: return nil
        }
    }

    private func performColumn(
        _ action: ColumnAction,
        selectedHandle: WindowHandle,
        isNiri: Bool,
        wmController: WMController
    ) -> StructuralMutationOutcome? {
        switch action {
        case .moveToFirst:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveColumnToFirst(containing: selectedHandle)
        case .moveToLast:
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveColumnToLast(containing: selectedHandle)
        case let .moveToIndex(index):
            guard isNiri else { return .unchanged }
            return wmController.niriLayoutHandler.moveColumn(
                containing: selectedHandle,
                toOneBasedIndex: index
            )
        case let .moveToWorkspace(index):
            guard isNiri else { return .unchanged }
            return wmController.workspaceNavigationHandler.moveColumn(
                containing: selectedHandle,
                toWorkspaceIndex: index
            )
        case .moveToWorkspaceUp:
            guard isNiri else { return .unchanged }
            return wmController.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(
                containing: selectedHandle,
                direction: .up
            )
        case .moveToWorkspaceDown:
            guard isNiri else { return .unchanged }
            return wmController.workspaceNavigationHandler.moveColumnToAdjacentWorkspace(
                containing: selectedHandle,
                direction: .down
            )
        default: return nil
        }
    }

    private func performWorkspace(
        _ action: WorkspaceAction,
        selectedHandle: WindowHandle,
        isNiri: Bool,
        wmController: WMController
    ) -> StructuralMutationOutcome? {
        switch action {
        case let .moveToMonitor(direction):
            return wmController.workspaceNavigationHandler.moveWindowToMonitor(
                handle: selectedHandle,
                direction: direction
            )
        case let .moveTo(index):
            return wmController.workspaceNavigationHandler.moveWindow(
                handle: selectedHandle,
                toWorkspaceIndex: index
            )
        case .moveUp:
            return wmController.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(
                handle: selectedHandle,
                direction: .up
            )
        case .moveDown:
            return wmController.workspaceNavigationHandler.moveWindowToAdjacentWorkspace(
                handle: selectedHandle,
                direction: .down
            )
        default: return nil
        }
    }
}
