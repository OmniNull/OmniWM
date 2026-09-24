// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct MonitorSetupMouseWarpStep: View {
    @Binding var mouseWarpEnabled: Bool
    let animationsEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MonitorSetupExplanation(
                title: String(localized: "Let the pointer follow your real desk"),
                text: String(
                    localized: "The macOS staircase leaves only corner contact between displays. Mouse Warp uses your OmniWM arrangement to move the pointer across the matching display edge."
                )
            )

            MonitorSetupMouseWarpIllustration(
                animationsEnabled: animationsEnabled
            )

            MonitorSetupCard {
                Toggle(isOn: $mouseWarpEnabled) {
                    HStack(spacing: 8) {
                        Text("Mouse Warp")
                        MonitorSetupBadge(text: String(localized: "Recommended"))
                    }
                }

                Text(
                    "When the pointer reaches a display edge, OmniWM moves it to the matching edge of the neighboring display."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                if !mouseWarpEnabled {
                    Label(
                        "With the macOS staircase, the pointer may not move naturally between displays without Mouse Warp.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }

            MonitorSetupCard {
                Label("Ready to apply", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                LabeledContent("Routing") {
                    Text("Custom — matches your desk")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Workspace Homes") {
                    Text("Every display covered")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Mouse Warp") {
                    Text(mouseWarpEnabled ? String(localized: "On") : String(localized: "Off"))
                        .foregroundStyle(.secondary)
                }
                Text("Cursor containment and other advanced options remain available in Monitors settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MonitorSetupMouseWarpIllustration: View {
    let animationsEnabled: Bool

    @State private var warped = false

    var body: some View {
        MonitorSetupCard {
            ZStack(alignment: .topLeading) {
                monitor(x: 20, label: String(localized: "Display 1"))
                monitor(x: 365, label: String(localized: "Display 2"))

                Path { path in
                    path.move(to: CGPoint(x: 305, y: 90))
                    path.addLine(to: CGPoint(x: 375, y: 90))
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))

                Image(systemName: "cursorarrow")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .shadow(radius: 2)
                    .offset(x: !animationsEnabled || warped ? 370 : 275, y: 70)
                    .animation(
                        animationsEnabled ? .smooth(duration: 0.9) : nil,
                        value: warped
                    )
            }
            .frame(height: 165)
            .accessibilityHidden(true)
            .task {
                guard animationsEnabled else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                warped = true
            }

            Text("At the right edge of Display 1, the pointer appears at the left edge of Display 2.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func monitor(x: CGFloat, label: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.12))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.35))
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 285, height: 150)
        .offset(x: x)
    }
}

private struct MonitorSetupBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}
