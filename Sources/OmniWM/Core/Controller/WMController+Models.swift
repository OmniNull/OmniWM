// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    struct StatusBarWorkspaceSummary: Equatable {
        let monitorId: Monitor.ID
        let workspaceLabel: String
        let workspaceRawName: String
        let focusedAppName: String?
        let layout: ActiveLayoutKind
    }

    struct WindowDecisionEvaluation {
        let token: WindowToken
        let facts: WindowRuleFacts
        let decision: WindowDecision
        let appFullscreen: Bool
        let manualOverride: ManualWindowOverride?
        let admissionGeometry: WindowAdmissionGeometryEvidence?
    }
}
