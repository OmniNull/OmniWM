// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension DwindleLayoutHandler {
    @discardableResult
    func swapWindows(
        _ token: WindowToken,
        with otherToken: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard let controller, let engine = controller.dwindleEngine else { return false }
        let swapped = controller.workspaceManager.withEngineMutationScope(
            in: workspaceId,
            label: "dwindle_bar_swap",
            source: .mouse
        ) {
            engine.swapLeafTiles(of: token, and: otherToken, in: workspaceId)
        }
        guard swapped else { return false }
        recordLayoutOperation(.windowsSwapped, in: workspaceId, source: .mouse)
        controller.layoutRefreshController.requestLayoutCommandRelayout(affectedWorkspaceIds: [workspaceId])
        return true
    }

    func moveToRootInDwindle() -> Bool {
        guard let controller else { return false }
        var changed = false
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            let stable = controller.settings.dwindle.moveToRootStable
            changed = engine.moveSelectionToRoot(stable: stable, in: wsId)
            guard changed else { return }
            controller.dwindleLayoutHandler.recordLayoutOperation(.windowMovedToRoot, in: wsId)
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
        return changed
    }

    func toggleSplitInDwindle() -> Bool {
        guard let controller else { return false }
        var changed = false
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            changed = engine.toggleOrientation(in: wsId)
            guard changed else { return }
            controller.dwindleLayoutHandler.recordLayoutOperation(.splitOrientationToggled, in: wsId)
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
        return changed
    }

    func swapSplitInDwindle() -> Bool {
        guard let controller else { return false }
        var changed = false
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            changed = engine.swapSplit(in: wsId)
            guard changed else { return }
            controller.dwindleLayoutHandler.recordLayoutOperation(.splitSwapped, in: wsId)
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
        return changed
    }

    func resizeAlongAxisInDwindle(orientation: DwindleOrientation, grow: Bool) -> Bool {
        guard let controller else { return false }
        var changed = false
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            let delta = grow ? engine.settings.resizeStep : -engine.settings.resizeStep
            changed = engine.resizeSelected(by: delta, orientation: orientation, in: wsId)
            guard changed else { return }
            controller.dwindleLayoutHandler.recordLayoutOperation(.splitRatioChanged, in: wsId)
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
        return changed
    }

    func resizeFocusedWindowInDwindle(grow: Bool) -> Bool {
        guard let controller else { return false }
        var changed = false
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            let delta = grow ? engine.settings.resizeStep : -engine.settings.resizeStep
            changed = engine.resizeFocusedWindow(by: delta, in: wsId)
            guard changed else { return }
            controller.dwindleLayoutHandler.recordLayoutOperation(.splitRatioChanged, in: wsId)
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
        return changed
    }

    func preselectInDwindle(direction: Direction) -> Bool {
        guard let controller else { return false }
        var changed = false
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            changed = engine.setPreselection(direction, in: wsId)
            guard changed else { return }
            controller.dwindleLayoutHandler.recordLayoutOperation(.preselectionChanged, in: wsId)
        }
        return changed
    }

    func clearPreselectInDwindle() -> Bool {
        guard let controller else { return false }
        var changed = false
        controller.dwindleLayoutHandler.withDwindleContext { engine, wsId in
            changed = engine.setPreselection(nil, in: wsId)
            guard changed else { return }
            controller.dwindleLayoutHandler.recordLayoutOperation(.preselectionChanged, in: wsId)
        }
        return changed
    }
}
