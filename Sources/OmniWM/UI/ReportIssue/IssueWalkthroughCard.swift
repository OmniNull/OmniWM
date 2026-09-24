// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct IssueWalkthroughCard: View {
    let onDismiss: () -> Void

    private struct Step: Identifiable {
        let id: Int
        let icon: String
        let title: String
        let detail: String
    }

    private let steps: [Step] = [
        Step(
            id: 1,
            icon: "record.circle",
            title: String(localized: "Record a trace"),
            detail: String(
                localized: "Click \"Record a Trace\" below, then reproduce the bug so OmniWM captures what happened."
            )
        ),
        Step(
            id: 2,
            icon: "arrow.uturn.backward",
            title: String(localized: "Come back here"),
            detail: String(
                localized: "Stop & Save the recording, then return — anything you typed stays saved as a draft."
            )
        ),
        Step(
            id: 3,
            icon: "text.alignleft",
            title: String(localized: "Describe it"),
            detail: String(localized: "Fill in what happened. Expected behavior and steps are optional but help a lot.")
        ),
        Step(
            id: 4,
            icon: "paperplane",
            title: String(localized: "Submit"),
            detail: String(
                localized: "OmniWM creates one fresh diagnostic log with any evidence you selected, then opens GitHub."
            )
        )
    ]

    var body: some View {
        Section {
            ForEach(steps) { step in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(step.id). \(step.title)")
                            .font(.callout.weight(.semibold))
                        Text(step.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: step.icon)
                        .foregroundStyle(.tint)
                }
            }
            Button("Got it") {
                onDismiss()
            }
            .controlSize(.small)
        } header: {
            Text("How reporting works")
        }
    }
}
