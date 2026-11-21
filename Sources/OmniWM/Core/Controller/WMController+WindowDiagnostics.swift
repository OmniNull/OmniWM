// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    static func exactWindowServerInfo(
        _ windowInfo: WindowServerInfo?,
        for token: WindowToken
    ) -> WindowServerInfo? {
        guard let windowInfo,
              let windowId = UInt32(exactly: token.windowId),
              windowInfo.id == windowId,
              pid_t(windowInfo.pid) == token.pid
        else {
            return nil
        }
        return windowInfo
    }

    func resolveWindowServerInfoForDisposition(
        token: WindowToken,
        axFacts: AXWindowFacts,
        preferredWindowInfo: WindowServerInfo?
    ) -> WindowServerInfo? {
        if preferredWindowInfo != nil {
            return Self.exactWindowServerInfo(preferredWindowInfo, for: token)
        }

        guard axFacts.role != (kAXHelpTagRole as String),
              let windowId = UInt32(exactly: token.windowId)
        else {
            return nil
        }

        return Self.exactWindowServerInfo(
            axEventHandler.resolveWindowInfo(windowId),
            for: token
        )
    }

    func makeWindowDecisionDebugSnapshot(
        from evaluation: WindowDecisionEvaluation
    ) -> WindowDecisionDebugSnapshot {
        WindowDecisionDebugSnapshot(
            token: evaluation.token,
            appName: evaluation.facts.appName,
            bundleId: evaluation.facts.ax.bundleId,
            title: evaluation.facts.ax.title,
            axRole: evaluation.facts.ax.role,
            axSubrole: evaluation.facts.ax.subrole,
            appFullscreen: evaluation.appFullscreen,
            manualOverride: evaluation.manualOverride,
            disposition: evaluation.decision.disposition,
            source: evaluation.decision.source,
            layoutDecisionKind: evaluation.decision.layoutDecisionKind,
            deferredReason: evaluation.decision.deferredReason,
            admissionOutcome: evaluation.decision.admissionOutcome,
            workspaceName: evaluation.decision.workspaceName,
            scratchpad: evaluation.decision.admissionHints.scratchpad,
            minWidth: evaluation.decision.ruleEffects.minWidth,
            minHeight: evaluation.decision.ruleEffects.minHeight,
            initialNiriContainerPrimarySpan: evaluation.decision.admissionHints.initialNiriContainerPrimarySpan,
            ruleProvenance: evaluation.decision.ruleProvenance,
            heuristicReasons: evaluation.decision.heuristicReasons,
            attributeFetchSucceeded: evaluation.facts.ax.attributeFetchSucceeded
        )
    }

    func windowDecisionDebugSnapshot(for token: WindowToken) -> WindowDecisionDebugSnapshot? {
        let axRef = workspaceManager.entry(for: token)?.axRef
            ?? AXWindowService.axWindowRef(for: UInt32(token.windowId), pid: token.pid)
        guard let axRef else { return nil }
        let evaluation = evaluateWindowDisposition(axRef: axRef, pid: token.pid)
        return makeWindowDecisionDebugSnapshot(from: evaluation)
    }

    func focusedWindowDecisionDebugSnapshot() -> WindowDecisionDebugSnapshot? {
        let token = focusedOrFrontmostWindowTokenForAutomation()
        guard let token else { return nil }
        return windowDecisionDebugSnapshot(for: token)
    }

    func copyDebugDump(_ snapshot: WindowDecisionDebugSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.formattedDump(), forType: .string)
    }

    func clearManualWindowOverride(for token: WindowToken) {
        workspaceManager.setManualLayoutOverride(nil, for: token)
    }

    func workspaceAssignment(pid: pid_t, windowId: Int) -> WorkspaceDescriptor.ID? {
        workspaceManager.workspace(for: WindowToken(pid: pid, windowId: windowId))
    }
}
