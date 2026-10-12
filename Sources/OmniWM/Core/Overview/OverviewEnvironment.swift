// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore

enum OverviewHotkeyDisposition: Equatable {
    case inactive
    case handled
    case blocked
}

enum OverviewPhysicalHotkeyAction: Equatable {
    case dismissSelection
    case activateSelection
    case closeSelection
}

@MainActor
struct OverviewEnvironment {
    var frontmostApplicationPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var currentProcessID: () -> pid_t = { getpid() }
    var activateOmniWM: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    var activateApplication: (pid_t) -> Void = { pid in
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    var addLocalEventMonitor: (
        NSEvent.EventTypeMask,
        @escaping (NSEvent) -> NSEvent?
    ) -> Any? = { mask, handler in
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    var removeEventMonitor: (Any) -> Void = { monitor in
        NSEvent.removeMonitor(monitor)
    }

    var notificationCenter: NotificationCenter = .default
    var schedulePostCloseHandoff: (@escaping @MainActor () -> Void) -> Void = { handoff in
        Task { @MainActor in
            await Task.yield()
            handoff()
        }
    }

    var windowTitle: (WindowState) -> String? = { entry in
        AXWindowService.titlePreferFast(windowId: UInt32(entry.windowId))
    }

    var windowFrame: (WindowState) -> CGRect? = { entry in
        AXWindowService.framePreferFast(entry.axRef)
    }

    var onThumbnailCaptureStarted: () -> Void = {}
    var onCachedProjectionRefreshed: (Set<WorkspaceDescriptor.ID>) -> Void = { _ in }
}

struct DwindleOverviewWorkspaceProjection {
    struct Group {
        let id: DwindleTileId
        let tokens: [WindowToken]
        let activeToken: WindowToken
    }

    let eligibleTokens: Set<WindowToken>
    let frames: [WindowToken: CGRect]
    let groups: [Group]

    init(
        engine: DwindleLayoutEngine,
        workspaceId: WorkspaceDescriptor.ID,
        eligibleTokens: Set<WindowToken>
    ) {
        self.eligibleTokens = eligibleTokens

        var frames = engine.currentFrames(in: workspaceId).filter { eligibleTokens.contains($0.key) }
        var groups: [Group] = []

        for snapshot in engine.groupedTileSnapshots(in: workspaceId) {
            let tokens = snapshot.members.compactMap { eligibleTokens.contains($0.token) ? $0.token : nil }
            guard let firstToken = tokens.first else { continue }
            let frame = snapshot.contentFrame ?? snapshot.tileFrame
            if let frame {
                for token in tokens {
                    frames[token] = frame
                }
            }
            if tokens.count > 1 {
                groups.append(Group(
                    id: snapshot.id,
                    tokens: tokens,
                    activeToken: tokens.contains(snapshot.activeToken) ? snapshot.activeToken : firstToken
                ))
            }
        }
        self.frames = frames
        self.groups = groups
    }

    func includes(_ token: WindowToken) -> Bool {
        eligibleTokens.contains(token)
    }
}

extension OverviewController {
    enum OverviewDismissReason {
        case cancel
        case selection
        case workspaceActivation
        case externalDeactivation

        var shouldRestorePreviousApplication: Bool {
            switch self {
            case .cancel:
                true
            case .selection,
                 .workspaceActivation,
                 .externalDeactivation:
                false
            }
        }
    }
}
