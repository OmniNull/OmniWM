// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    struct PreparedCreate {
        let windowId: UInt32
        let token: WindowToken
        let axRef: AXWindowRef
        let ruleEffects: ManagedWindowRuleEffects
        let admissionHints: ManagedWindowAdmissionHints
        let appFullscreen: Bool
        var isMinimized = false
        let replacementMetadata: ManagedReplacementMetadata
        let structuralReplacementMatch: StructuralReplacementMatch?
        var observedFrame: CGRect?
        var scratchpadAdmission: ScratchpadAdmission?

        var bundleId: String? {
            replacementMetadata.bundleId
        }

        var workspaceId: WorkspaceDescriptor.ID {
            replacementMetadata.workspaceId
        }

        var mode: TrackedWindowMode {
            replacementMetadata.mode
        }
    }

    enum CreatePreparationOutcome {
        case prepared(PreparedCreate)
        case alreadyTracked(WindowToken)
        case identityRebindPending
        case pending(token: WindowToken?, axRef: AXWindowRef?, reason: WindowAdmissionPendingReason)
        case ignored(token: WindowToken?, reason: WindowAdmissionRejectionReason)
    }

    enum WindowDestroyEvidence {
        case transientLifecycle, windowClosed
    }

    struct PreparedDestroy {
        let token: WindowToken
        let replacementMetadata: ManagedReplacementMetadata
        var evidence: WindowDestroyEvidence

        var bundleId: String? {
            replacementMetadata.bundleId
        }

        var workspaceId: WorkspaceDescriptor.ID {
            replacementMetadata.workspaceId
        }

        var mode: TrackedWindowMode {
            replacementMetadata.mode
        }
    }
}
