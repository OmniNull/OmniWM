// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriLayoutHandler {
    func showColumnModeToast(
        engine: NiriLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        state: ViewportState,
        motion: MotionSnapshot
    ) {
        let column = state.selectedNodeId
            .flatMap { engine.findNode(by: $0, in: workspaceId) }
            .flatMap { engine.column(of: $0) }
        showToast(.columnMode(isTabbed: column?.isTabbed ?? false), over: column, in: workspaceId, motion: motion)
    }

    func showToast(
        _ message: ColumnModeToastController.Message,
        over column: NiriContainer?,
        in workspaceId: WorkspaceDescriptor.ID,
        motion: MotionSnapshot
    ) {
        guard let controller,
              let monitor = controller.workspaceManager.monitor(for: workspaceId),
              let frame = toastFrame(of: column)
        else {
            controller?.columnModeToast.hide()
            return
        }
        controller.columnModeToast.show(
            message,
            columnFrame: frame,
            visibleFrame: monitor.visibleFrame,
            motion: motion,
            source: .init(workspaceId: workspaceId, monitorId: monitor.id)
        )
    }

    func toastFrame(of column: NiriContainer?) -> CGRect? {
        guard let frame = column?.renderedFrame,
              !frame.isNull,
              !frame.isInfinite,
              frame.width > 0,
              frame.height > 0
        else { return nil }
        return frame
    }
}
