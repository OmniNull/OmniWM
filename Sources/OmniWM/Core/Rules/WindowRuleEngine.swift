// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
final class WindowRuleEngine {
    static let ownedWindowRuleName = "ownedWindow"
    nonisolated static let externalSurfaceRuleName = "externalSurface"
    nonisolated static let unprovenIndependentRootRuleName = "unprovenIndependentRoot"
    nonisolated static let hiddenTitleBarWindowRuleName = "hiddenTitleBarWindow"

    private enum Selection {
        case matched(MatchedWindowRules)
        case rejected(WindowDecision)
    }

    private var compiledUserRules: [CompiledWindowRule] = []
    private let builtInRules: [CompiledWindowRule]
    private var titleRules: [CompiledWindowRule] = []
    private(set) var invalidRegexMessagesByRuleId: [UUID: String] = [:]

    private(set) var hasDynamicReevaluationRules = false
    private let eligibilityPolicy: WindowEligibilityPolicy

    init(
        inputMethodBundleIds: Set<String>? = nil,
        hiddenTitleBarFullscreenButtonOptionalBundleIds: Set<String>? = nil,
        hiddenTitleBarNonStandardSubroleBundleIds: Set<String>? = nil
    ) {
        eligibilityPolicy = WindowEligibilityPolicy(
            hiddenTitleBarFullscreenButtonOptionalBundleIds: hiddenTitleBarFullscreenButtonOptionalBundleIds
                ?? HiddenTitleBarRegistry.fullscreenButtonOptionalBundleIds,
            hiddenTitleBarNonStandardSubroleBundleIds: hiddenTitleBarNonStandardSubroleBundleIds
                ?? HiddenTitleBarRegistry.nonStandardSubroleBundleIds,
            inputMethodBundleIds: inputMethodBundleIds ?? InputMethodBundleRegistry.discover()
        )
        builtInRules = CompiledWindowRule.makeBuiltInRules()
        titleRules = builtInRules.filter(\.requiresTitle)
        hasDynamicReevaluationRules = builtInRules.contains { $0.requiresDynamicReevaluation }
    }

    var needsWindowReevaluation: Bool {
        hasDynamicReevaluationRules
    }

    func needsTitleReevaluation(for bundleId: String?, appName: String? = nil) -> Bool {
        guard let bundleId, !bundleId.isEmpty else { return true }
        if eligibilityPolicy.requiresPictureInPictureTitle(for: bundleId) {
            return true
        }
        let canMatchApp: (CompiledWindowRule) -> Bool = { candidate in
            candidate.requiresDynamicReevaluation
                && candidate.matchesApp(
                    bundleId: bundleId,
                    appName: appName ?? candidate.rule.appNameSubstring
                )
        }
        return builtInRules.contains(where: canMatchApp)
            || compiledUserRules.contains(where: canMatchApp)
    }

    func requiresTitle(for bundleId: String?, appName: String? = nil) -> Bool {
        eligibilityPolicy.requiresPictureInPictureTitle(for: bundleId)
            || titleRules.contains { $0.matchesApp(bundleId: bundleId, appName: appName) }
    }

    func rebuild(rules: [AppRule]) {
        var invalidRegexMessagesByRuleId: [UUID: String] = [:]
        compiledUserRules = rules.enumerated().compactMap { index, rule in
            guard rule.hasIdentifyingMatcher, rule.hasEffect else { return nil }
            return CompiledWindowRule.compile(
                rule: rule,
                source: .user,
                order: index,
                invalidRegexMessagesByRuleId: &invalidRegexMessagesByRuleId
            )
        }
        self.invalidRegexMessagesByRuleId = invalidRegexMessagesByRuleId

        titleRules = (builtInRules + compiledUserRules).filter(\.requiresTitle)
        hasDynamicReevaluationRules = compiledUserRules.contains { $0.requiresDynamicReevaluation }
            || builtInRules.contains { $0.requiresDynamicReevaluation }
    }

    static func applyingManualOverride(
        _ decision: WindowDecision,
        manualOverride: ManualWindowOverride?
    ) -> WindowDecision {
        guard let manualOverride, decision.tracksWindow else {
            return decision
        }
        var provenance = decision.ruleProvenance
        provenance.layout = nil
        return WindowDecision(
            disposition: manualOverride == .forceTile ? .managed : .floating,
            source: .manualOverride,
            layoutDecisionKind: .explicitLayout,
            workspaceName: decision.workspaceName,
            ruleEffects: decision.ruleEffects,
            admissionHints: decision.admissionHints,
            ruleProvenance: provenance,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    func decision(
        for facts: WindowRuleFacts,
        token: WindowToken?,
        appFullscreen: Bool
    ) -> WindowDecision {
        if eligibilityPolicy.isExternalSurface(facts) {
            return externalSurfaceDecision()
        }
        let eligibility = eligibilityPolicy.eligibility(for: facts, token: token, appFullscreen: appFullscreen)
        let matches: MatchedWindowRules
        switch selectRules(for: facts, eligibility: eligibility) {
        case let .rejected(decision):
            return decision
        case let .matched(selected):
            matches = selected
        }
        if facts.ax.role == (kAXWindowRole as String),
           facts.ax.title == nil,
           eligibilityPolicy.requiresPictureInPictureTitle(for: facts.ax.bundleId)
        {
            return matches.fallbackDecision(disposition: .undecided, deferredReason: .requiredTitleMissing)
        }
        if let decision = matches.explicitDecision(for: facts) {
            return decision
        }
        if facts.ax.title == nil,
           requiresTitle(for: facts.ax.bundleId, appName: facts.appName)
        {
            return matches.fallbackDecision(disposition: .undecided, deferredReason: .requiredTitleMissing)
        }
        if appFullscreen {
            return matches.fallbackDecision(disposition: .managed)
        }
        if eligibilityPolicy.acceptsHiddenTitleBar(facts) {
            return matches.fallbackDecision(
                disposition: .managed,
                source: .builtInRule(Self.hiddenTitleBarWindowRuleName)
            )
        }
        return matches.heuristicDecision(for: facts)
    }

    private func selectRules(for facts: WindowRuleFacts, eligibility: WindowStructuralEligibility) -> Selection {
        let userRules: ComposedUserRules
        let builtInRule: CompiledWindowRule?
        switch eligibility {
        case .eligible:
            userRules = composedUserRules(facts: facts)
            builtInRule = bestMatch(in: builtInRules, facts: facts)
        case .requiresExplicitInclusion:
            userRules = composedUserRules(facts: facts, requireExplicitInclusion: true)
            builtInRule = bestMatch(in: builtInRules, facts: facts, requireExplicitInclusion: true)
            if userRules.isEmpty, builtInRule == nil {
                return .rejected(externalSurfaceDecision())
            }
        case .requiresExplicitUserInclusion:
            userRules = composedUserRules(facts: facts, requireExplicitInclusion: true)
            builtInRule = nil
            if userRules.isEmpty {
                return .rejected(externalSurfaceDecision())
            }
        case .requiresIndependentRootInclusion:
            userRules = composedUserRules(facts: facts, requireExplicitInclusion: true)
            builtInRule = bestMatch(in: builtInRules, facts: facts, requireExplicitInclusion: true)
            if userRules.isEmpty, builtInRule == nil {
                return .rejected(unprovenIndependentRootDecision())
            }
        case .external:
            return .rejected(externalSurfaceDecision())
        case let .deferred(reason):
            return .rejected(deferredStructuralDecision(reason: reason))
        }
        return .matched(MatchedWindowRules(userRules: userRules, builtInRule: builtInRule))
    }

    private func externalSurfaceDecision() -> WindowDecision {
        WindowDecision(
            disposition: .unmanaged,
            source: .builtInRule(Self.externalSurfaceRuleName),
            layoutDecisionKind: .explicitLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            ruleProvenance: .none,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    private func unprovenIndependentRootDecision() -> WindowDecision {
        WindowDecision(
            disposition: .unmanaged,
            source: .builtInRule(Self.unprovenIndependentRootRuleName),
            layoutDecisionKind: .explicitLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            ruleProvenance: .none,
            heuristicReasons: [],
            deferredReason: nil
        )
    }

    private func deferredStructuralDecision(
        reason: WindowDecisionDeferredReason
    ) -> WindowDecision {
        WindowDecision(
            disposition: .undecided,
            source: .heuristic,
            layoutDecisionKind: .fallbackLayout,
            workspaceName: nil,
            ruleEffects: .none,
            admissionHints: .none,
            ruleProvenance: .none,
            heuristicReasons: reason == .attributeFetchFailed ? [.attributeFetchFailed] : [],
            deferredReason: reason
        )
    }

    private func composedUserRules(
        facts: WindowRuleFacts,
        requireExplicitInclusion: Bool = false
    ) -> ComposedUserRules {
        var composed = ComposedUserRules()
        forEachMatch(in: compiledUserRules, facts: facts, requireExplicitInclusion: requireExplicitInclusion) {
            composed.add($0)
        }
        return composed
    }

    private func bestMatch(
        in rules: [CompiledWindowRule],
        facts: WindowRuleFacts,
        requireExplicitInclusion: Bool = false
    ) -> CompiledWindowRule? {
        var best: CompiledWindowRule?
        forEachMatch(in: rules, facts: facts, requireExplicitInclusion: requireExplicitInclusion) { candidate in
            if let current = best, !candidate.outranks(current) { return }
            best = candidate
        }
        return best
    }

    private func forEachMatch(
        in rules: [CompiledWindowRule],
        facts: WindowRuleFacts,
        requireExplicitInclusion: Bool,
        _ body: (CompiledWindowRule) -> Void
    ) {
        for index in rules.indices {
            if requireExplicitInclusion, !rules[index].explicitlyIncludesNonstandardSurface {
                continue
            }
            guard rules[index].matches(facts) else { continue }
            body(rules[index])
        }
    }
}
