// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    var diagnosticsIssueCount = 0

    var body: some View {
        List(selection: $selection) {
            ForEach(SettingsSectionGroup.allCases) { group in
                Section(group.displayName) {
                    ForEach(group.sections) { section in
                        Label(section.displayName, systemImage: section.icon)
                            .badge(badge(for: section))
                            .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
    }

    private func badge(for section: SettingsSection) -> Text? {
        guard section == .diagnostics, diagnosticsIssueCount > 0 else { return nil }
        return Text(diagnosticsIssueCount.formatted())
    }
}
