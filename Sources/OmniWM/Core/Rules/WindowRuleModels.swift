// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

enum WindowDecisionDisposition: Equatable, Sendable {
    case managed
    case floating
    case unmanaged
    case undecided
}

enum WindowDecisionSource: Equatable, Sendable {
    case manualOverride
    case userRule(UUID)
    case builtInRule(String)
    case heuristic
}

enum WindowDecisionLayoutKind: String, Equatable, Sendable {
    case explicitLayout
    case fallbackLayout
}

enum WindowDecisionDeferredReason: String, Equatable, Sendable {
    case attributeFetchFailed
    case independentRootEvidenceMissing
    case requiredTitleMissing
    case windowServerEvidenceMissing
}

enum WindowDecisionAdmissionOutcome: String, Equatable, Sendable {
    case trackedTiling
    case trackedFloating
    case ignored
    case deferred
}

enum ManualWindowOverride: String, Codable, Equatable {
    case forceTile
    case forceFloat
}

struct ManagedWindowRuleEffects: Equatable, Sendable {
    var minWidth: Double?
    var minHeight: Double?

    static let none = ManagedWindowRuleEffects()
}

struct WindowRuleProvenance: Equatable, Sendable {
    var layout: UUID?
    var workspace: UUID?
    var minWidth: UUID?
    var minHeight: UUID?
    var initialContainerPrimarySpan: UUID?
    var scratchpad: UUID?

    static let none = WindowRuleProvenance()
}

struct ManagedWindowAdmissionHints: Equatable, Sendable {
    var initialNiriContainerPrimarySpan: Double?
    var scratchpad: ScratchpadIndex?

    static let none = ManagedWindowAdmissionHints()
}

struct WindowDecision: Equatable, Sendable {
    let disposition: WindowDecisionDisposition
    let source: WindowDecisionSource
    let layoutDecisionKind: WindowDecisionLayoutKind
    let workspaceName: String?
    let ruleEffects: ManagedWindowRuleEffects
    let admissionHints: ManagedWindowAdmissionHints
    let ruleProvenance: WindowRuleProvenance
    let heuristicReasons: [AXWindowHeuristicReason]
    let deferredReason: WindowDecisionDeferredReason?

    var managesWindow: Bool {
        disposition == .managed
    }

    var trackedMode: TrackedWindowMode? {
        switch disposition {
        case .managed:
            .tiling
        case .floating:
            .floating
        case .unmanaged,
             .undecided:
            nil
        }
    }

    var admissionOutcome: WindowDecisionAdmissionOutcome {
        switch disposition {
        case .managed:
            .trackedTiling
        case .floating:
            .trackedFloating
        case .unmanaged:
            .ignored
        case .undecided:
            .deferred
        }
    }

    var tracksWindow: Bool {
        trackedMode != nil
    }

    var reflectsExplicitUserIntent: Bool {
        switch source {
        case .manualOverride,
             .userRule:
            true
        case .builtInRule,
             .heuristic:
            false
        }
    }

    var isResolved: Bool {
        disposition != .undecided
    }

    @MainActor
    var isUnprovenIndependentRootDecision: Bool {
        source == .builtInRule(WindowRuleEngine.unprovenIndependentRootRuleName)
    }
}

struct WindowRuleFacts: Equatable, Sendable {
    let appName: String?
    let ax: AXWindowFacts
    let sizeConstraints: WindowSizeConstraints?
    let windowServer: WindowServerInfo?

    var degradedWindowServerChildEvidence: Bool {
        guard !ax.attributeFetchSucceeded,
              let windowServer
        else {
            return false
        }
        return windowServer.hasModalTag || (windowServer.hasFloatingTag && !windowServer.hasDocumentTag)
    }
}

enum WindowRuleReevaluationTarget: Hashable, Sendable {
    case window(WindowToken)
    case pid(pid_t)
}

enum WindowRuleReevaluationContext: Equatable, Sendable {
    case automatic
    case explicitRuleApply
}

struct WindowRuleReevaluationOutcome: Equatable, Sendable {
    let resolvedAnyTarget: Bool
    let evaluatedAnyWindow: Bool
    let relayoutNeeded: Bool
    let stale: Bool

    init(
        resolvedAnyTarget: Bool,
        evaluatedAnyWindow: Bool,
        relayoutNeeded: Bool,
        stale: Bool = false
    ) {
        self.resolvedAnyTarget = resolvedAnyTarget
        self.evaluatedAnyWindow = evaluatedAnyWindow
        self.relayoutNeeded = relayoutNeeded
        self.stale = stale
    }

    static let none = WindowRuleReevaluationOutcome(
        resolvedAnyTarget: false,
        evaluatedAnyWindow: false,
        relayoutNeeded: false
    )
}
