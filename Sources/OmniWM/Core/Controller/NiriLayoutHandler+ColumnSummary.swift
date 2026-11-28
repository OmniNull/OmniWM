// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriLayoutHandler {
    func columnSummary(
        for workspaceId: WorkspaceDescriptor.ID, usesLiveBackingScale: Bool = true
    ) -> NiriColumnSummary? {
        guard let controller,
              let engine = controller.niriEngine,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri
        else { return nil }
        let geometry = controller.workspaceManager.monitor(for: workspaceId).map { monitor in
            let scale = usesLiveBackingScale ? controller.backingScaleFactor(for: monitor)
                : controller.layoutRefreshController.layoutState.backingScaleByDisplay?[monitor.displayId]
                ?? monitor.backingScale
            let interaction = controller.niriInteractionGeometry(for: monitor, scale: scale)
            return NiriSizingGeometry(
                workingFrame: interaction.workingFrame,
                gaps: interaction.innerGap,
                orientation: resolvedOrientation(for: workspaceId, monitor: monitor, engine: engine)
            )
        }
        return engine.columnSummary(
            in: workspaceId,
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            geometry: geometry
        )
    }
}
