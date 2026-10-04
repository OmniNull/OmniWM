// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

@MainActor
struct WorkspaceBarNotificationBadge: View {
    let bundleId: String?
    let iconSize: CGFloat

    @Environment(WorkspaceBarBadgeService.self) private var badges: WorkspaceBarBadgeService?

    var body: some View {
        if let badges, badges.mode != .off, let label = badges.label(for: bundleId), !label.isEmpty {
            Group {
                if badges.mode == .dot {
                    Circle()
                        .fill(Color(nsColor: .systemRed))
                        .frame(width: max(6, iconSize * 0.35), height: max(6, iconSize * 0.35))
                } else {
                    ViewThatFits(in: .horizontal) {
                        Text(verbatim: label).fixedSize()
                        Text(verbatim: "…")
                            .font(.system(size: max(4, iconSize * 0.23), weight: .semibold))
                            .fixedSize()
                    }
                    .font(.system(size: max(5, iconSize * 0.35), weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, iconSize < 20 ? 1 : 3)
                    .frame(
                        minWidth: max(6, iconSize * 0.45),
                        minHeight: max(8, iconSize * 0.55)
                    )
                    .background(Color(nsColor: .systemRed), in: Capsule())
                    .frame(maxWidth: max(6, iconSize - 6), alignment: .leading)
                }
            }
            .fixedSize()
            .offset(x: -4, y: -max(2, iconSize * 0.12))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

@MainActor
struct WorkspaceBarBadgeAccessibility: ViewModifier {
    let windows: ArraySlice<WorkspaceBarWindowItem>
    let value: String
    let help: String

    @Environment(WorkspaceBarBadgeService.self) private var badges: WorkspaceBarBadgeService?

    func body(content: Content) -> some View {
        let labels = badgeLabels
        content
            .accessibilityValue(([value] + labels).filter { !$0.isEmpty }.joined(separator: ", "))
            .help(([help] + labels).joined(separator: ", "))
    }

    private var badgeLabels: [String] {
        guard let badges, badges.mode != .off else { return [] }
        return windows.compactMap { window in
            guard let label = badges.label(for: window.bundleId), !label.isEmpty else { return nil }
            return String(localized: "\(window.appName) notification badge: \(label)")
        }
    }
}
