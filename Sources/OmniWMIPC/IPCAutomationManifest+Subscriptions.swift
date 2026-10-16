// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCAutomationManifest {
    public static let subscriptionDescriptors: [IPCSubscriptionDescriptor] = [
        .init(channel: .focus, summary: "Focused window snapshot updates.", resultKind: .focusedWindow),
        .init(
            channel: .workspaceBar,
            summary: "Workspace bar projection updates.",
            resultKind: .workspaceBar
        ),
        .init(
            channel: .activeWorkspace,
            summary: "Interaction monitor and active workspace updates.",
            resultKind: .activeWorkspace
        ),
        .init(
            channel: .focusedMonitor,
            summary: "Focused monitor updates for the current interaction target.",
            resultKind: .focusedMonitor
        ),
        .init(
            channel: .windowsChanged,
            summary: "Managed window inventory updates.",
            resultKind: .windows
        ),
        .init(
            channel: .displayChanged,
            summary: "Display state updates.",
            resultKind: .displays
        ),
        .init(
            channel: .layoutChanged,
            summary: "Workspace layout updates.",
            resultKind: .workspaces
        ),
        .init(
            channel: .shellWidgets,
            summary: "Luau shell widget load and failure updates.",
            resultKind: .shellWidgets
        )
    ]

    public static func expandedChannels(for request: IPCSubscribeRequest) -> [IPCSubscriptionChannel] {
        let channels = request.allChannels ? IPCSubscriptionChannel.allCases : request.channels
        var seen: Set<IPCSubscriptionChannel> = []
        return channels.filter { seen.insert($0).inserted }
    }
}
