// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct DiagnosticsHealthSection: View {
    let issues: [DiagnosticsIssue]

    @ViewBuilder
    var body: some View {
        Section("Health") {
            if issues.isEmpty {
                Label("No issues detected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(issues) { issue in
                    issueRow(issue)
                }
            }
        }
    }

    @ViewBuilder
    private func issueRow(_ issue: DiagnosticsIssue) -> some View {
        let isCritical = issue.severity == .critical
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 8) {
                    if let urlString = issue.systemSettingsURLString {
                        Button("Open Settings") {
                            openSystemSettings(urlString)
                        }
                        .accessibilityLabel("Open System Settings for \(issue.localizedTitle)")
                    }
                    if issue.revealsConfigFolder {
                        Button("Reveal Config Folder") {
                            revealConfigFolder()
                        }
                        .accessibilityLabel("Reveal config folder for \(issue.localizedTitle)")
                    }
                }
                .controlSize(.small)
            } label: {
                Label(
                    issue.localizedTitle,
                    systemImage: isCritical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(isCritical ? .red : .orange)
            }
            Text(issue.localizedMessage)
                .font(.callout)
            SettingsCaption(issue.localizedRemediation)
        }
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealConfigFolder() {
        let directory = SettingsFilePersistence.defaultDirectoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
