// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func recordLayoutOperation(
        _ operation: LayoutOperation,
        in workspaceId: WorkspaceDescriptor.ID,
        source: WMEventSource = .command,
        preMutate: () -> Void = {}
    ) {
        recordReconcileEvent(
            .layoutOperationPerformed(workspaceId: workspaceId, operation: operation, source: source),
            preMutate: preMutate
        )
    }

    func viewportWorkspaceId(for event: WMEvent) -> WorkspaceDescriptor.ID? {
        switch event {
        case let .selectionChanged(workspaceId, _, _),
             let .viewportChanged(workspaceId, _, _):
            workspaceId
        case let .viewportCommitted(workspaceId, _, _):
            workspaceId
        default:
            nil
        }
    }

    func viewportEventState(for event: WMEvent) -> ViewportState? {
        switch event {
        case let .viewportChanged(_, state, _):
            state
        case let .viewportCommitted(_, state, _):
            state
        default:
            nil
        }
    }

    func noteViewportInvalidationIfNeeded(
        for workspaceId: WorkspaceDescriptor.ID,
        previousViewport: ViewportState?,
        pendingOffsetAnimation: Bool
    ) {
        guard let nextViewport = recordedViewportStates[workspaceId],
              niriViewportChangeRequiresInvalidation(
                  previous: previousViewport,
                  next: nextViewport,
                  pendingOffsetAnimation: pendingOffsetAnimation
              )
        else {
            return
        }
        noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout])
    }
}
