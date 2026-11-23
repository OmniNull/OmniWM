// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import SwiftUI

struct AdvancedMatchersEditor: View {
    @Binding var draft: AppRuleDraft
    var row: String?
    let regexError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCaption(localized: "Narrow a rule to specific windows within an app.")

            Picker("Title Match", selection: $draft.titleMatcherMode) {
                ForEach(TitleMatcherMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .settingsField(.appRules, row: row, leaf: "titleRegex", "titleSubstring")

            switch draft.titleMatcherMode {
            case .none:
                EmptyView()
            case .substring:
                TextField("Title contains", text: $draft.titleSubstring)
                    .textFieldStyle(.roundedBorder)
                    .settingsField(.appRules, row: row, leaf: "titleSubstring")
            case .regex:
                TextField("Title regex", text: $draft.titleRegex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .settingsField(.appRules, row: row, leaf: "titleRegex")
                if let regexError {
                    Text("Title regex is invalid: \(regexError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Toggle("AX Role", isOn: $draft.axRoleEnabled)
                .settingsField(.appRules, row: row, leaf: "axRole")
            if draft.axRoleEnabled {
                TextField("e.g. AXWindow", text: $draft.axRole)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .settingsField(.appRules, row: row, leaf: "axRole")
            }

            Toggle("AX Subrole", isOn: $draft.axSubroleEnabled)
                .settingsField(.appRules, row: row, leaf: "axSubrole")
            if draft.axSubroleEnabled {
                TextField("e.g. AXStandardWindow", text: $draft.axSubrole)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .settingsField(.appRules, row: row, leaf: "axSubrole")
            }
        }
        .padding(.vertical, 4)
    }
}
