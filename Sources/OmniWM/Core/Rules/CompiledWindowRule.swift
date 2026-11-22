// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
struct CompiledWindowRule {
    enum Source {
        case user
        case builtIn(String)
    }

    let rule: AppRule
    let source: Source
    let titleRegex: NSRegularExpression?
    let order: Int

    var requiresTitle: Bool {
        rule.titleSubstring?.isEmpty == false || titleRegex != nil
    }

    var requiresDynamicReevaluation: Bool {
        rule.hasAdvancedMatchers
    }

    func matchesApp(bundleId: String?, appName: String?) -> Bool {
        if let requiredBundleId = nonEmpty(rule.bundleId),
           requiredBundleId.caseInsensitiveCompare(bundleId ?? "") != .orderedSame
        {
            return false
        }
        if let appNameSubstring = nonEmpty(rule.appNameSubstring) {
            guard let appName,
                  appName.localizedCaseInsensitiveContains(appNameSubstring)
            else {
                return false
            }
        }
        return true
    }

    func canApplyExplicitly(to facts: WindowRuleFacts) -> Bool {
        switch source {
        case .builtIn("steamClient"):
            facts.ax.attributeFetchSucceeded
        case .user,
             .builtIn:
            true
        }
    }

    func outranks(_ other: CompiledWindowRule) -> Bool {
        rule.specificity > other.rule.specificity
            || (rule.specificity == other.rule.specificity && order < other.order)
    }

    var explicitlyIncludesNonstandardSurface: Bool {
        rule.effectiveLayoutAction != .auto
            && nonEmpty(rule.axRole) != nil
            && nonEmpty(rule.axSubrole) != nil
    }

    func matches(_ facts: WindowRuleFacts) -> Bool {
        guard matchesApp(bundleId: facts.ax.bundleId, appName: facts.appName) else { return false }

        if let titleSubstring = nonEmpty(rule.titleSubstring) {
            guard let title = facts.ax.title,
                  title.localizedCaseInsensitiveContains(titleSubstring)
            else {
                return false
            }
        }

        if let titleRegex {
            guard let title = facts.ax.title else { return false }
            let range = NSRange(title.startIndex..., in: title)
            guard titleRegex.firstMatch(in: title, range: range) != nil else {
                return false
            }
        }

        if let axRole = nonEmpty(rule.axRole), facts.ax.role != axRole {
            return false
        }

        if let axSubrole = nonEmpty(rule.axSubrole), facts.ax.subrole != axSubrole {
            return false
        }

        return true
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static let finderQuickLookSubrole = "Quick Look"

    static func compile(
        rule: AppRule,
        source: Source,
        order: Int,
        invalidRegexMessagesByRuleId: inout [UUID: String]
    ) -> CompiledWindowRule? {
        let titleRegex: NSRegularExpression?
        if let pattern = rule.titleRegex, !pattern.isEmpty {
            do {
                titleRegex = try NSRegularExpression(pattern: pattern)
            } catch {
                invalidRegexMessagesByRuleId[rule.id] = error.localizedDescription
                return nil
            }
        } else {
            titleRegex = nil
        }

        return CompiledWindowRule(
            rule: rule,
            source: source,
            titleRegex: titleRegex,
            order: order
        )
    }

    static func makeBuiltInRules() -> [CompiledWindowRule] {
        var rules: [CompiledWindowRule] = []

        for (index, bundleId) in DefaultFloatingApps.bundleIds.sorted().enumerated() {
            let rule = AppRule(
                bundleId: bundleId,
                layout: .float
            )
            rules.append(
                CompiledWindowRule(
                    rule: rule,
                    source: .builtIn("defaultFloatingApp"),
                    titleRegex: nil,
                    order: index
                )
            )
        }

        for subrole in [kAXStandardWindowSubrole as String, kAXUnknownSubrole as String] {
            rules.append(
                CompiledWindowRule(
                    rule: AppRule(
                        bundleId: "com.valvesoftware.steam.helper",
                        axRole: kAXWindowRole as String,
                        axSubrole: subrole,
                        layout: .tile
                    ),
                    source: .builtIn("steamClient"),
                    titleRegex: nil,
                    order: rules.count
                )
            )
        }

        rules.append(
            CompiledWindowRule(
                rule: AppRule(
                    bundleId: "com.apple.finder",
                    axRole: kAXWindowRole as String,
                    axSubrole: finderQuickLookSubrole,
                    layout: .float
                ),
                source: .builtIn("finderQuickLook"),
                titleRegex: nil,
                order: rules.count
            )
        )

        return rules
    }
}
