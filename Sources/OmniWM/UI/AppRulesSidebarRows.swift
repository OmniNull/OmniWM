// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ConfigScriptRule {
    var sourceLocation: String {
        "\(source):\(line)"
    }
}

struct AppRulesSidebarRows {
    let rules: [AppRule]
    let scriptRules: [ConfigScriptRule]
    let configuredIDs: Set<UUID>

    init(rules: [AppRule], scriptRules: [ConfigScriptRule], search: String) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            self.rules = rules
            self.scriptRules = scriptRules
        } else {
            self.rules = rules.filter { Self.matches($0, query) }
            self.scriptRules = scriptRules.filter {
                $0.sourceLocation.localizedCaseInsensitiveContains(query) || Self.matches($0.rule, query)
            }
        }
        configuredIDs = self.scriptRules.isEmpty ? [] : Set(rules.map(\.id))
    }

    private static func matches(_ rule: AppRule, _ query: String) -> Bool {
        if rule.displayLabel.localizedCaseInsensitiveContains(query) { return true }
        return [
            rule.appNameSubstring,
            rule.titleSubstring,
            rule.titleRegex,
            rule.axRole,
            rule.axSubrole,
            rule.assignToWorkspace,
            rule.layout?.rawValue
        ]
        .contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}
