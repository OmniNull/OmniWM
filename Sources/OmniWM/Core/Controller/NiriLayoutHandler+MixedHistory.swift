// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriLayoutHandler {
    func stepMixedLayoutHistory(
        _ direction: NiriLayoutHistoryDirection,
        in workspaceId: WorkspaceDescriptor.ID,
        keepingFocus: Bool,
        engine: NiriLayoutEngine,
        controller: WMController
    ) -> Bool? {
        while engine.hasForeignLayoutHistory(direction, in: workspaceId) {
            let focused = focusedToken(in: workspaceId)
            let drawn = engine.drawnLayout(in: workspaceId)
            guard let result = controller.stepMixedLayoutHistory(
                direction == .undo ? .undo : .redo, in: workspaceId, keepingFocus: keepingFocus
            ) else { return false }
            if result.changed {
                return applyLayoutHistoryStep(
                    in: workspaceId, drawn: drawn, focusedBefore: focused, keepingFocus: keepingFocus,
                    frontsRestoredWindow: !keepingFocus && !result.followed
                ) { _, _, _ in NiriLayoutHistoryStep(focused: result.focused) }
            }
            if applyLayoutHistoryStep(
                in: workspaceId, keepingFocus: keepingFocus, frontsRestoredWindow: !keepingFocus,
                step: { engine, id, focused in engine.stepLayoutHistory(direction, in: id, focused: focused) }
            ) { return true }
        }
        return nil
    }
}
