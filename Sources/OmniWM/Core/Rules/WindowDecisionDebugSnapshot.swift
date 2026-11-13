// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct WindowDecisionDebugSnapshot: Equatable, Sendable {
    let token: WindowToken?
    let appName: String?
    let bundleId: String?
    let title: String?
    let axRole: String?
    let axSubrole: String?
    let appFullscreen: Bool
    let manualOverride: ManualWindowOverride?
    let disposition: WindowDecisionDisposition
    let source: WindowDecisionSource
    let layoutDecisionKind: WindowDecisionLayoutKind
    let deferredReason: WindowDecisionDeferredReason?
    let admissionOutcome: WindowDecisionAdmissionOutcome
    let workspaceName: String?
    let scratchpad: ScratchpadIndex?
    let minWidth: Double?
    let minHeight: Double?
    let initialNiriContainerPrimarySpan: Double?
    let ruleProvenance: WindowRuleProvenance
    let heuristicReasons: [AXWindowHeuristicReason]
    let attributeFetchSucceeded: Bool

    var sourceDescription: String {
        switch source {
        case .manualOverride:
            "manualOverride"
        case let .userRule(ruleId):
            "userRule(\(ruleId.uuidString))"
        case let .builtInRule(name):
            "builtInRule(\(name))"
        case .heuristic:
            "heuristic"
        }
    }

    private func ruleIdDescription(_ ruleId: UUID?) -> String {
        ruleId?.uuidString ?? "nil"
    }

    private func stringValue<T>(_ value: T?) -> String {
        value.map { String(describing: $0) } ?? "nil"
    }

    func formattedDump() -> String {
        let lines: [String] = [
            "token=\(token.map { "\($0.pid):\($0.windowId)" } ?? "nil")",
            "appName=\(appName ?? "nil")",
            "bundleId=\(bundleId ?? "nil")",
            "title=\(title ?? "nil")",
            "axRole=\(axRole ?? "nil")",
            "axSubrole=\(axSubrole ?? "nil")",
            "appFullscreen=\(appFullscreen)",
            "manualOverride=\(manualOverride?.rawValue ?? "nil")",
            "disposition=\(String(describing: disposition))",
            "source=\(sourceDescription)",
            "layoutDecisionKind=\(layoutDecisionKind.rawValue)",
            "layoutRuleId=\(ruleIdDescription(ruleProvenance.layout))",
            "deferredReason=\(deferredReason?.rawValue ?? "nil")",
            "admissionOutcome=\(admissionOutcome.rawValue)",
            "workspaceName=\(workspaceName ?? "nil")",
            "workspaceRuleId=\(ruleIdDescription(ruleProvenance.workspace))",
            "scratchpad=\(stringValue(scratchpad))",
            "scratchpadRuleId=\(ruleIdDescription(ruleProvenance.scratchpad))",
            "minWidth=\(stringValue(minWidth))",
            "minWidthRuleId=\(ruleIdDescription(ruleProvenance.minWidth))",
            "minHeight=\(stringValue(minHeight))",
            "minHeightRuleId=\(ruleIdDescription(ruleProvenance.minHeight))",
            "initialNiriContainerPrimarySpan=\(stringValue(initialNiriContainerPrimarySpan))",
            "initialNiriContainerPrimarySpanRuleId=\(ruleIdDescription(ruleProvenance.initialContainerPrimarySpan))",
            "heuristicReasons=\(heuristicReasons.map(\.rawValue).joined(separator: ","))",
            "attributeFetchSucceeded=\(attributeFetchSucceeded)"
        ]
        return lines.joined(separator: "\n")
    }
}
