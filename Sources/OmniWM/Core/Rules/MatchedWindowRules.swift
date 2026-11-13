// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
struct ComposedUserRules {
    private(set) var primary: CompiledWindowRule?
    private(set) var layout: CompiledWindowRule?
    private(set) var destination: CompiledWindowRule?
    private(set) var minWidth: CompiledWindowRule?
    private(set) var minHeight: CompiledWindowRule?
    private(set) var initialContainerPrimarySpan: CompiledWindowRule?

    var isEmpty: Bool {
        primary == nil
    }

    mutating func add(_ candidate: CompiledWindowRule) {
        let rule = candidate.rule
        Self.keepHigherRanked(&primary, candidate)
        if rule.effectiveLayoutAction != .auto {
            Self.keepHigherRanked(&layout, candidate)
        }
        if rule.assignedWorkspaceName != nil || rule.validScratchpad != nil {
            Self.keepHigherRanked(&destination, candidate)
        }
        if rule.minWidth != nil {
            Self.keepHigherRanked(&minWidth, candidate)
        }
        if rule.minHeight != nil {
            Self.keepHigherRanked(&minHeight, candidate)
        }
        if rule.validInitialContainerPrimarySpan != nil {
            Self.keepHigherRanked(&initialContainerPrimarySpan, candidate)
        }
    }

    private static func keepHigherRanked(_ winner: inout CompiledWindowRule?, _ candidate: CompiledWindowRule) {
        if let current = winner, !candidate.outranks(current) { return }
        winner = candidate
    }
}

@MainActor
struct MatchedWindowRules {
    let userRules: ComposedUserRules
    let builtInRule: CompiledWindowRule?

    func explicitDecision(for facts: WindowRuleFacts) -> WindowDecision? {
        if let layoutRule = userRules.layout, let decision = explicitDecision(layoutRule) {
            return decision
        }
        if let builtInRule,
           builtInRule.canApplyExplicitly(to: facts),
           let decision = explicitDecision(builtInRule)
        {
            return decision
        }
        return nil
    }

    func fallbackDecision(
        disposition: WindowDecisionDisposition,
        source: WindowDecisionSource? = nil,
        deferredReason: WindowDecisionDeferredReason? = nil
    ) -> WindowDecision {
        makeDecision(
            disposition: disposition,
            source: source ?? fallbackSource(),
            layoutDecisionKind: .fallbackLayout,
            deferredReason: deferredReason
        )
    }

    func heuristicDecision(for facts: WindowRuleFacts) -> WindowDecision {
        let heuristic = AXWindowService.heuristicDisposition(for: facts.ax)
        return makeDecision(
            disposition: heuristic.disposition,
            source: userRules.primary.map { .userRule($0.rule.id) } ?? .heuristic,
            layoutDecisionKind: .fallbackLayout,
            heuristicReasons: heuristic.reasons,
            deferredReason: heuristic.disposition == .undecided ? .attributeFetchFailed : nil
        )
    }

    private func explicitDecision(_ compiled: CompiledWindowRule) -> WindowDecision? {
        let source: WindowDecisionSource
        let layoutRuleId: UUID?
        switch compiled.source {
        case .user:
            source = .userRule(compiled.rule.id)
            layoutRuleId = compiled.rule.id
        case let .builtIn(name):
            source = .builtInRule(name)
            layoutRuleId = nil
        }
        let disposition: WindowDecisionDisposition
        switch compiled.rule.effectiveLayoutAction {
        case .float:
            disposition = .floating
        case .tile:
            disposition = .managed
        case .auto:
            return nil
        }
        return makeDecision(
            disposition: disposition,
            source: source,
            layoutDecisionKind: .explicitLayout,
            layoutRuleId: layoutRuleId
        )
    }

    private func fallbackSource() -> WindowDecisionSource {
        if let primary = userRules.primary {
            return .userRule(primary.rule.id)
        }
        if let builtInRule, case let .builtIn(name) = builtInRule.source {
            return .builtInRule(name)
        }
        return .heuristic
    }

    private func makeDecision(
        disposition: WindowDecisionDisposition,
        source: WindowDecisionSource,
        layoutDecisionKind: WindowDecisionLayoutKind,
        layoutRuleId: UUID? = nil,
        heuristicReasons: [AXWindowHeuristicReason] = [],
        deferredReason: WindowDecisionDeferredReason? = nil
    ) -> WindowDecision {
        let destinationRule = userRules.destination?.rule
        let scratchpad = destinationRule?.validScratchpad
        return WindowDecision(
            disposition: disposition,
            source: source,
            layoutDecisionKind: layoutDecisionKind,
            workspaceName: scratchpad == nil ? destinationRule?.assignedWorkspaceName : nil,
            ruleEffects: ManagedWindowRuleEffects(
                minWidth: userRules.minWidth?.rule.minWidth,
                minHeight: userRules.minHeight?.rule.minHeight
            ),
            admissionHints: ManagedWindowAdmissionHints(
                initialNiriContainerPrimarySpan: userRules.initialContainerPrimarySpan?.rule
                    .validInitialContainerPrimarySpan,
                scratchpad: scratchpad
            ),
            ruleProvenance: WindowRuleProvenance(
                layout: layoutRuleId,
                workspace: scratchpad == nil ? destinationRule?.id : nil,
                minWidth: userRules.minWidth?.rule.id,
                minHeight: userRules.minHeight?.rule.id,
                initialContainerPrimarySpan: userRules.initialContainerPrimarySpan?.rule.id,
                scratchpad: scratchpad == nil ? nil : destinationRule?.id
            ),
            heuristicReasons: heuristicReasons,
            deferredReason: deferredReason
        )
    }
}
