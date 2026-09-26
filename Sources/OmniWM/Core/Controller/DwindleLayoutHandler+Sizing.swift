// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    func swapWindow(direction: Direction) -> WindowMoveOutcome {
        guard let controller else { return .blocked }
        var outcome = WindowMoveOutcome.blocked
        withDwindleContext { engine, wsId in
            outcome = engine.swapWindowOutcome(direction: direction, in: wsId)
            guard outcome == .movedWithinWorkspace else { return }
            recordLayoutOperation(.windowsSwapped, in: wsId)
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
        return outcome
    }

    func toggleFullscreen() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if let token = engine.toggleFullscreen(in: wsId) {
                recordLayoutOperation(.fullscreenToggled(token: token), in: wsId)
                _ = controller.workspaceManager.applySessionPatch(
                    .init(
                        workspaceId: wsId,
                        viewportState: nil,
                        rememberedFocusToken: token,
                        plannedSeq: controller.workspaceManager.worldSeq
                    )
                )
                controller.layoutRefreshController.requestLayoutCommandRelayout(
                    affectedWorkspaceIds: [wsId]
                )
            }
        }
    }

    func cycleSize(forward: Bool) {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if engine.cycleSplitRatio(forward: forward, in: wsId) {
                recordLayoutOperation(.splitRatioChanged, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func balanceSizes() {
        guard let controller else { return }
        withDwindleContext { engine, wsId in
            if engine.balanceSizes(in: wsId) {
                recordLayoutOperation(.sizesBalanced, in: wsId)
            }
            controller.layoutRefreshController.requestLayoutCommandRelayout(
                affectedWorkspaceIds: [wsId]
            )
        }
    }

    func enableDwindleLayout() {
        guard let controller else { return }
        let engine = DwindleLayoutEngine()
        engine.tabRailWidth = controller.tabRailStyle.reservedWidth
        engine.animationClock = controller.animationClock
        controller.dwindleEngine = engine
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }

    func updateDwindleConfig(
        smartSplit: Bool? = nil,
        defaultSplitRatio: CGFloat? = nil,
        splitWidthMultiplier: CGFloat? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        innerGap: CGFloat? = nil,
        stackIncomingWindows: Bool? = nil
    ) {
        guard let controller, let engine = controller.dwindleEngine else { return }
        controller.workspaceManager.withEngineMutationScope {
            if let smartSplit { engine.settings.smartSplit = smartSplit }
            if let defaultSplitRatio { engine.settings.defaultSplitRatio = defaultSplitRatio }
            if let splitWidthMultiplier { engine.settings.splitWidthMultiplier = splitWidthMultiplier }
            if let singleWindowFit { engine.settings.singleWindowFit = singleWindowFit }
            if let innerGap { engine.settings.innerGap = innerGap }
            if let stackIncomingWindows { engine.settings.stackIncomingWindows = stackIncomingWindows }
        }
        controller.workspaceManager.invalidateAllLayouts()
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }

    func withDwindleContext(
        perform: (DwindleLayoutEngine, WorkspaceDescriptor.ID) -> Void
    ) {
        guard let controller,
              let engine = controller.dwindleEngine,
              let wsId = controller.activeWorkspace()?.id,
              let monitor = controller.workspaceManager.monitor(for: wsId)
        else { return }
        controller.workspaceManager.withEngineMutationScope {
            applyResolvedSettings(controller.resolvedDwindleSettings(for: monitor), to: engine)
            perform(engine, wsId)
        }
    }
}
