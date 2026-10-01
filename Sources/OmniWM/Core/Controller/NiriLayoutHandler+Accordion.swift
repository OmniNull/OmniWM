// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriLayoutHandler {
    func syncAccordion(_ enabled: Bool, in workspaceId: WorkspaceDescriptor.ID) {
        guard let engine = controller?.niriEngine else { return }
        let wasEnabled = engine.isAccordion(in: workspaceId)
        engine.setAccordion(enabled, in: workspaceId)
        if wasEnabled, !enabled {
            revealActiveColumn(in: workspaceId)
        }
    }

    private func revealActiveColumn(in workspaceId: WorkspaceDescriptor.ID) {
        withNiriWorkspaceContext(for: workspaceId) { engine, wsId, motion, state, _, frame, gaps, orientation in
            guard let selectedId = state.selectedNodeId,
                  let node = engine.findNode(by: selectedId, in: wsId)
            else { return }
            engine.resolvePrimaryContainerSpans(
                in: wsId, workingFrame: frame, gaps: gaps, orientation: orientation
            )
            engine.ensureSelectionVisible(
                node: node,
                context: NiriInteractionContext(
                    workspaceId: wsId, motion: motion, workingFrame: frame, gaps: gaps, orientation: orientation
                ),
                state: &state
            )
        }
    }
}
