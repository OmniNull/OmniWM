// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func resolvedAppInfo(for pid: pid_t) -> AppInfoCache.AppInfo? {
        appInfoCache.info(for: pid) ?? NSRunningApplication(processIdentifier: pid).map {
            AppInfoCache.AppInfo(
                name: $0.localizedName,
                bundleId: $0.bundleIdentifier,
                icon: $0.icon,
                activationPolicy: $0.activationPolicy
            )
        }
    }

    func evaluateWindowDisposition(
        axRef: AXWindowRef,
        pid: pid_t,
        appFullscreen: Bool? = nil,
        applyingManualOverride: Bool = true,
        windowInfo: WindowServerInfo? = nil,
        windowServerLookupAttempted: Bool = false,
        admissionGeometry: WindowAdmissionGeometryEvidence? = nil
    ) -> WindowDecisionEvaluation {
        let token = WindowToken(pid: pid, windowId: axRef.windowId)
        if pid == ProcessInfo.processInfo.processIdentifier || isOwnedWindow(windowNumber: axRef.windowId) {
            return Self.ownedWindowDispositionEvaluation(token: token)
        }
        if let evaluation = windowDispositionEvaluationForTests?(token) {
            return evaluation
        }
        let baseFacts = collectDispositionRuleFacts(for: token, axRef: axRef, admissionGeometry: admissionGeometry)
        let fullscreen = appFullscreen ?? AXWindowService.isFullscreen(axRef)
        let lookupAttempted = windowServerLookupAttempted || windowInfo != nil
        var resolvedWindowInfo = Self.exactWindowServerInfo(windowInfo, for: token)

        func evaluate(with windowServer: WindowServerInfo?) -> WindowDecisionEvaluation {
            makeWindowDispositionEvaluation(
                token: token,
                facts: WindowRuleFacts(
                    appName: baseFacts.appName,
                    ax: baseFacts.ax,
                    sizeConstraints: baseFacts.sizeConstraints,
                    windowServer: windowServer
                ),
                appFullscreen: fullscreen,
                applyingManualOverride: applyingManualOverride,
                admissionGeometry: admissionGeometry
            )
        }

        var evaluation = evaluate(with: resolvedWindowInfo)
        if evaluation.decision.deferredReason == .windowServerEvidenceMissing,
           !lookupAttempted
        {
            resolvedWindowInfo = resolveWindowServerInfoForDisposition(
                token: token,
                axFacts: baseFacts.ax,
                preferredWindowInfo: nil
            )
            evaluation = evaluate(with: resolvedWindowInfo)
        }
        return evaluation
    }

    func evaluateWindowDisposition(
        token: WindowToken,
        evidence: AXWindowDecisionEvidence,
        appFullscreen: Bool,
        applyingManualOverride: Bool = true,
        windowInfo: WindowServerInfo?,
        admissionGeometry: WindowAdmissionGeometryEvidence
    ) -> WindowDecisionEvaluation {
        if token.pid == ProcessInfo.processInfo.processIdentifier || isOwnedWindow(windowNumber: token.windowId) {
            return Self.ownedWindowDispositionEvaluation(token: token)
        }
        let appInfo = resolvedAppInfo(for: token.pid)
        let captured = evidence.facts
        let axFacts = AXWindowFacts(
            role: captured.role,
            subrole: captured.subrole,
            title: captured.title,
            hasCloseButton: captured.hasCloseButton,
            hasFullscreenButton: captured.hasFullscreenButton,
            fullscreenButtonEnabled: captured.fullscreenButtonEnabled,
            hasZoomButton: captured.hasZoomButton,
            hasMinimizeButton: captured.hasMinimizeButton,
            appPolicy: captured.appPolicy ?? appInfo?.activationPolicy,
            bundleId: captured.bundleId ?? appInfo?.bundleId,
            attributeFetchSucceeded: captured.attributeFetchSucceeded,
            isMain: captured.isMain,
            isModal: captured.isModal
        )
        return makeWindowDispositionEvaluation(
            token: token,
            facts: WindowRuleFacts(
                appName: appInfo?.name,
                ax: axFacts,
                sizeConstraints: evidence.sizeConstraints,
                windowServer: Self.exactWindowServerInfo(windowInfo, for: token)
            ),
            appFullscreen: appFullscreen,
            applyingManualOverride: applyingManualOverride,
            admissionGeometry: admissionGeometry
        )
    }

    private func makeWindowDispositionEvaluation(
        token: WindowToken,
        facts: WindowRuleFacts,
        appFullscreen: Bool,
        applyingManualOverride: Bool,
        admissionGeometry: WindowAdmissionGeometryEvidence?
    ) -> WindowDecisionEvaluation {
        let manualOverride = workspaceManager.manualLayoutOverride(for: token)
        let baseDecision = windowRuleEngine.decision(
            for: facts,
            token: token,
            appFullscreen: appFullscreen
        )
        let decision = applyingManualOverride
            ? WindowRuleEngine.applyingManualOverride(baseDecision, manualOverride: manualOverride)
            : baseDecision
        return WindowDecisionEvaluation(
            token: token,
            facts: facts,
            decision: decision,
            appFullscreen: appFullscreen,
            manualOverride: manualOverride,
            admissionGeometry: admissionGeometry
        )
    }

    private static func ownedWindowDispositionEvaluation(token: WindowToken) -> WindowDecisionEvaluation {
        WindowDecisionEvaluation(
            token: token,
            facts: WindowRuleFacts(
                appName: nil,
                ax: AXWindowFacts(
                    role: nil,
                    subrole: nil,
                    title: nil,
                    hasCloseButton: false,
                    hasFullscreenButton: false,
                    fullscreenButtonEnabled: nil,
                    hasZoomButton: false,
                    hasMinimizeButton: false,
                    appPolicy: nil,
                    bundleId: nil,
                    attributeFetchSucceeded: true
                ),
                sizeConstraints: nil,
                windowServer: nil
            ),
            decision: WindowDecision(
                disposition: .unmanaged,
                source: .builtInRule(WindowRuleEngine.ownedWindowRuleName),
                layoutDecisionKind: .explicitLayout,
                workspaceName: nil,
                ruleEffects: .none,
                admissionHints: .none,
                heuristicReasons: [],
                deferredReason: nil
            ),
            appFullscreen: false,
            manualOverride: nil,
            admissionGeometry: nil
        )
    }

    private func collectDispositionRuleFacts(
        for token: WindowToken,
        axRef: AXWindowRef,
        admissionGeometry: WindowAdmissionGeometryEvidence?
    ) -> WindowRuleFacts {
        let pid = token.pid
        let sizeConstraints = evaluateSizeConstraints(
            for: token,
            axRef: axRef,
            admissionGeometry: admissionGeometry
        )
        let appInfo = resolvedAppInfo(for: pid)
        return WindowRuleFacts(
            appName: appInfo?.name,
            ax: AXWindowService.collectWindowFacts(
                axRef,
                appPolicy: appInfo?.activationPolicy,
                bundleId: appInfo?.bundleId,
                includeTitle: windowRuleEngine.requiresTitle(
                    for: appInfo?.bundleId,
                    appName: appInfo?.name
                )
            ),
            sizeConstraints: sizeConstraints,
            windowServer: nil
        )
    }
}
