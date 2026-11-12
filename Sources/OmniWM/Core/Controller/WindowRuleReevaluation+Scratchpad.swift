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
    ) -> (evaluation: WMController.WindowDecisionEvaluation, scratchpadRelease: ScratchpadMemberRelease?) {
        let evaluation = controller.evaluateWindowDisposition(
            axRef: axRef,
            pid: token.pid,
            windowInfo: windowInfo,
            windowServerLookupAttempted: windowServerLookupAttempted
        )
        guard context == .explicitRuleApply,
              existingEntry != nil,
              let release = controller.beginScratchpadMemberRelease(token, decision: evaluation.decision)
        else {
            return (evaluation, nil)
        }
        let rulesEvaluation = controller.evaluateWindowDisposition(
            axRef: axRef,
            pid: token.pid,
            windowInfo: windowInfo,
            windowServerLookupAttempted: windowServerLookupAttempted
        )
        return (rulesEvaluation, release)
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
              window.evaluation.decision.isResolved,
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
