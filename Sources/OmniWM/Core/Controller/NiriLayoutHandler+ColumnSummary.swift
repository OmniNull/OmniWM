// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriLayoutHandler {
    func columnSummary(for workspaceId: WorkspaceDescriptor.ID) -> NiriColumnSummary? {
        guard let controller,
              let engine = controller.niriEngine,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri
        else { return nil }
        let geometry = controller.workspaceManager.monitor(for: workspaceId).map { monitor in
            let interaction = controller.niriInteractionGeometry(for: monitor)
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
