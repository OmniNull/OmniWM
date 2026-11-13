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

    func scratchpadArrival(for window: RuleReevaluationWindow) -> ScratchpadJoinArrival {
        guard let scratchpadAdmission = window.scratchpadAdmission else {
            return .quiet(previousFocusToken: controller.workspaceManager.selectedManagedToken)
        }
        return controller.axEventHandler.scratchpadJoinArrival(
            window.token,
            in: scratchpadAdmission.index,
            canCountAsFocused: !window.evaluation.appFullscreen
        )
    }

    func applyScratchpadDestination(_ window: RuleReevaluationWindow, arrival: ScratchpadJoinArrival) {
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
              let index = window.evaluation.decision.admissionHints.scratchpad
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
