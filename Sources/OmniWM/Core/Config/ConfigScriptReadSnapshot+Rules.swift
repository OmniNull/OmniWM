// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

extension WMController {
    func appendScriptRules(to output: inout ConfigScriptSnapshotWriter) {
        output.appendRows(settings.ruleSet.savedScriptRows)
    }
}

extension ConfigScriptSnapshotWriter.CachedRows {
    static func savedRules(_ rules: borrowing [AppRule]) -> Self {
        guard !rules.isEmpty else { return .empty }
        var writer = ConfigScriptSnapshotWriter()
        writer.start(tag: UInt8(OMNI_CONFIG_SECTION_RULES))
        let regexErrors = runtimeRegexErrors(in: rules)
        for (index, rule) in rules.enumerated() {
            let stored = writer.row { row in
                let report = rule.savedReport(runtimeRegexError: regexErrors[rule.id])
                return row.writeSavedRule(report, position: UInt16(index + 1))
            }
            if !stored { break }
        }
        return writer.cachedRows()
    }

    private static func runtimeRegexErrors(in rules: borrowing [AppRule]) -> [UUID: String] {
        var errors: [UUID: String] = [:]
        let rows = rules.span
        for index in rows.indices {
            let rule = rows[index]
            guard let pattern = rule.titleRegex, !pattern.isEmpty, rule.hasIdentifyingMatcher, rule.hasEffect
            else { continue }
            do {
                _ = try CompiledWindowRule.compileTitleRegex(pattern)
            } catch {
                errors[rule.id] = error.localizedDescription
            }
        }
        return errors
    }
}

extension ConfigScriptSnapshotWriter {
    fileprivate mutating func writeSavedRule(_ report: borrowing SavedAppRuleReport, position: UInt16) -> Bool {
        let rule = report.rule
        guard string(rule.id), count(position), string(rule.bundleId), string(rule.appNameSubstring),
              string(rule.titleSubstring), string(rule.titleRegex), string(rule.axRole), string(rule.axSubrole),
              string(rule.effectiveLayoutAction.rawValue), string(rule.assignToWorkspace),
              writeRuleFlagsAndNumbers(rule, valid: report.isValid), flag(UInt8(report.specificity)),
              string(report.invalidRegexMessage), flag(UInt8(report.validationMessages.count))
        else { return false }
        for message in report.validationMessages where !string(message) { return false }
        return true
    }

    private mutating func writeRuleFlagsAndNumbers(_ rule: borrowing AppRule, valid: Bool) -> Bool {
        var flags = valid ? UInt8(OMNI_CONFIG_RULE_VALID) : 0
        if let allWindows = rule.assignToWorkspaceForAllWindows {
            flags |= UInt8(OMNI_CONFIG_RULE_ASSIGN_ALL_PRESENT)
            if allWindows { flags |= UInt8(OMNI_CONFIG_RULE_ASSIGN_ALL) }
        }
        let numbers: InlineArray<4, (UInt8, Double?)> = [
            (UInt8(OMNI_CONFIG_RULE_INITIAL_SPAN), rule.initialContainerPrimarySpan),
            (UInt8(OMNI_CONFIG_RULE_MIN_WIDTH), rule.minWidth),
            (UInt8(OMNI_CONFIG_RULE_MIN_HEIGHT), rule.minHeight),
            (UInt8(OMNI_CONFIG_RULE_SCRATCHPAD), rule.scratchpad.flatMap { Double(exactly: $0) })
        ]
        for index in numbers.indices where numbers[index].1 != nil {
            flags |= numbers[index].0
        }
        guard flag(flags) else { return false }
        for index in numbers.indices {
            if let number = numbers[index].1, !detailValue(number.bitPattern) { return false }
        }
        return true
    }
}
