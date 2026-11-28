// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct EffectiveAppRules {
    private var scriptRules: [AppRule] = []
    private(set) var effective: [AppRule]
    private(set) var snapshot: WindowClassificationRulesSnapshot
    private(set) var savedScriptRows: ConfigScriptSnapshotWriter.CachedRows

    init(configured: [AppRule]) {
        effective = configured
        snapshot = WindowClassificationRulesSnapshot(revision: 0, rules: configured)
        savedScriptRows = .savedRules(configured)
    }

    mutating func setConfiguredRules(_ configured: [AppRule]) {
        savedScriptRows = .savedRules(configured)
        refresh(configured: configured)
    }

    mutating func setScriptRules(_ rules: [AppRule], configured: [AppRule]) -> Bool {
        guard scriptRules != rules else { return false }
        scriptRules = rules
        return refresh(configured: configured)
    }

    @discardableResult
    private mutating func refresh(configured: [AppRule]) -> Bool {
        var merged = configured
        if configured.isEmpty {
            merged = scriptRules
        } else if !scriptRules.isEmpty {
            let configuredIDs = Set(configured.map(\.id))
            merged.append(contentsOf: scriptRules.lazy.filter { !configuredIDs.contains($0.id) })
        }
        guard merged != effective else { return false }
        effective = merged
        snapshot = WindowClassificationRulesSnapshot(revision: snapshot.revision &+ 1, rules: merged)
        return true
    }
}
