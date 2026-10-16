// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct SettingsSidebar: View {
    @Bindable var navigation: SettingsNavigationModel
    var diagnosticsIssueCount = 0

    var body: some View {
        VStack(spacing: 0) {
            SettingsSearchField(text: $navigation.searchText)
                .frame(height: 28)
                .padding(10)
            sidebarList
        }
    }

    private var sidebarList: some View {
        List(selection: Binding(
            get: { navigation.section },
            set: { navigation.section = $0 }
        )) {
            if navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ForEach(SettingsSectionGroup.allCases) { group in
                    Section(group.displayName) {
                        ForEach(group.sections) { section in
                            Label(section.displayName, systemImage: section.icon)
                                .badge(badge(for: section))
                                .tag(section)
                        }
                    }
                }
            } else {
                let results = SettingsSearchIndex.results(for: navigation.searchText)
                ForEach(results) { result in
                    Button {
                        navigation.request(result.route)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.title).foregroundStyle(.primary)
                            Text(result.context).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if results.isEmpty {
                    Text("No matching settings").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func badge(for section: SettingsSection) -> Text? {
        guard section == .diagnostics, diagnosticsIssueCount > 0 else { return nil }
        return Text(diagnosticsIssueCount.formatted())
    }
}
