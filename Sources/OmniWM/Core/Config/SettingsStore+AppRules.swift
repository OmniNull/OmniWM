// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension SettingsStore {
    var appRulesRevision: UInt64 {
        ruleSet.snapshot.revision
    }

    var appRulesDiagnosticSnapshot: WindowClassificationRulesSnapshot {
        ruleSet.snapshot
    }

    var effectiveAppRules: [AppRule] {
        ruleSet.effective
    }
}
