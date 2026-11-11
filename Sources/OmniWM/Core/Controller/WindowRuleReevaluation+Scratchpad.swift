// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension WindowRuleReevaluation {
    func evaluate(
        _ token: WindowToken,
        axRef: AXWindowRef,
        existingEntry: WindowState?,
        windowInfo: WindowServerInfo?,
        windowServerLookupAttempted: Bool
    ) -> (existingEntry: WindowState?, evaluation: WMController.WindowDecisionEvaluation) {
        let evaluation = controller.evaluateWindowDisposition(
            axRef: axRef,
            pid: token.pid,
            windowInfo: windowInfo,
            windowServerLookupAttempted: windowServerLookupAttempted
        )
        guard context == .explicitRuleApply,
              existingEntry != nil,
              controller.releaseScratchpadMemberForWorkspaceDestination(token, decision: evaluation.decision)
        else {
            return (existingEntry, evaluation)
        }
        return (
            controller.workspaceManager.entry(for: token),
            controller.evaluateWindowDisposition(
                axRef: axRef,
                pid: token.pid,
                windowInfo: windowInfo,
                windowServerLookupAttempted: windowServerLookupAttempted
            )
        )
    }

    func applyScratchpadDestination(_ window: RuleReevaluationWindow, previousFocusToken: WindowToken?) {
        let arrival = ScratchpadJoinArrival.quiet(previousFocusToken: previousFocusToken)
        if let scratchpadAdmission = window.scratchpadAdmission {
            controller.joinScratchpadOnAdmission(
                window.token,
                scratchpadAdmission,
                observedFrame: window.admission.geometry?.frame,
                appFullscreen: window.evaluation.appFullscreen,
                arrival: arrival
            )
            return
        }
        guard context == .explicitRuleApply,
              window.existingEntry != nil,
              let index = controller.scratchpadDestination(for: window.evaluation)
        else {
            return
        }
        controller.ensureScratchpadMembership(
            window.token,
            in: index,
            observedFrame: WindowAdmissionGeometryEvidence.usableAppKitFrame(
                fromWindowServer: window.evaluation.facts.windowServer?.frame
            ),
            arrival: arrival
        )
    }
}
