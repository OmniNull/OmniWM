// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct MonitorSetupLaunchSection: View {
    let isComplete: Bool
    let onOpen: () -> Void

    var body: some View {
        Section("Guided Setup") {
            HStack(alignment: .center, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isComplete
                            ? String(localized: "Multi-monitor setup is complete")
                            : String(localized: "Set up multiple displays"))
                            .fontWeight(.medium)
                        Text(
                            isComplete
                                ? String(localized: "Run the guide again after moving, replacing, or adding a display.")
                                :
                                String(
                                    localized: "Follow four guided steps for display placement, workspace homes, and Mouse Warp."
                                )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: isComplete
                        ? "checkmark.circle.fill"
                        : "sparkles")
                        .foregroundStyle(
                            isComplete ? Color.green : Color.accentColor
                        )
                }

                Spacer()

                Button("Run Monitor Setup…", action: onOpen)
            }
        }
    }
}
