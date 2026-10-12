// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension IPCRect {
    init(_ rect: CGRect) {
        self.init(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }
}

extension IPCWorkspaceRef {
    @MainActor
    init(descriptor: WorkspaceDescriptor, settings: SettingsStore) {
        self.init(
            id: descriptor.id.uuidString,
            rawName: descriptor.name,
            displayName: settings.workspaces.displayName(for: descriptor.name),
            number: WorkspaceIDPolicy.workspaceNumber(from: descriptor.name)
        )
    }
}

extension IPCDisplayRef {
    init(monitor: Monitor) {
        self.init(
            id: Self.identifier(monitor.id),
            name: monitor.name,
            isMain: monitor.isMain
        )
    }

    static func identifier(_ id: Monitor.ID) -> String {
        "display:\(id.displayId)"
    }
}

extension IPCWindowOpaqueID {
    static func encode(token: WindowToken, sessionToken: String) -> String {
        encode(pid: token.pid, windowId: token.windowId, sessionToken: sessionToken)
    }
}

extension IPCAppRef {
    init?(appInfo: AppInfoCache.AppInfo?) {
        guard let appInfo, let name = appInfo.name else { return nil }
        self.init(name: name, bundleId: appInfo.bundleId)
    }
}

extension IPCWindowMode {
    init(mode: TrackedWindowMode) {
        switch mode {
        case .tiling:
            self = .tiling
        case .floating:
            self = .floating
        }
    }
}

extension IPCLayoutReason {
    init(reason: LayoutReason) {
        switch reason {
        case .standard:
            self = .standard
        case .nativeFullscreen:
            self = .nativeFullscreen
        }
    }
}

extension IPCManualWindowOverride {
    init(override: ManualWindowOverride) {
        switch override {
        case .forceTile:
            self = .forceTile
        case .forceFloat:
            self = .forceFloat
        }
    }
}

extension IPCHiddenReason {
    init(hiddenState: HiddenState, isInactiveTabMember: Bool) {
        switch hiddenState.reason {
        case .workspaceInactive:
            self = .workspaceInactive
        case .layoutTransient:
            self = isInactiveTabMember ? .tabInactive : .layoutTransient
        case .scratchpad:
            self = .scratchpad
        }
    }
}

extension IPCColumnViewport {
    init(relation: NiriColumnViewportRelation) {
        switch relation {
        case .before:
            self = .before
        case .intersecting:
            self = .intersecting
        case .after:
            self = .after
        }
    }
}

extension IPCWorkspaceLayout {
    init(layout: LayoutType) {
        switch layout {
        case .defaultLayout:
            self = .defaultLayout
        case .niri:
            self = .niri
        case .dwindle:
            self = .dwindle
        }
    }
}

extension IPCResult {
    @MainActor
    init(query: IPCQueryRequest, queryRouter: IPCQueryRouter) {
        switch query.name {
        case .workspaceBar:
            self.init(workspaceBar: queryRouter.workspaceBarResult())
        case .activeWorkspace:
            self.init(activeWorkspace: queryRouter.activeWorkspaceResult())
        case .focusedMonitor:
            self.init(focusedMonitor: queryRouter.focusedMonitorResult())
        case .apps:
            self.init(apps: queryRouter.appsResult())
        case .metrics:
            self.init(metrics: queryRouter.metricsResult())
        case .focusedWindow:
            self.init(focusedWindow: queryRouter.focusedWindowResult())
        case .windows:
            self.init(windows: queryRouter.windowsResult(query))
        case .workspaces:
            self.init(workspaces: queryRouter.workspacesResult(query))
        case .displays:
            self.init(displays: queryRouter.displaysResult(query))
        case .rules:
            self.init(rules: queryRouter.rulesResult())
        case .ruleActions:
            self.init(ruleActions: queryRouter.ruleActionsResult())
        case .queries:
            self.init(queries: queryRouter.queriesResult())
        case .commands:
            self.init(commands: queryRouter.commandsResult())
        case .subscriptions:
            self.init(subscriptions: queryRouter.subscriptionsResult())
        case .capabilities:
            self.init(capabilities: queryRouter.capabilitiesResult())
        }
    }

    @MainActor
    init(channel: IPCSubscriptionChannel, queryRouter: IPCQueryRouter) {
        switch channel {
        case .focus:
            self.init(focusedWindow: queryRouter.focusedWindowResult())
        case .workspaceBar:
            self.init(workspaceBar: queryRouter.workspaceBarResult())
        case .activeWorkspace:
            self.init(activeWorkspace: queryRouter.activeWorkspaceResult())
        case .focusedMonitor:
            self.init(focusedMonitor: queryRouter.focusedMonitorResult())
        case .windowsChanged:
            self.init(windows: queryRouter.windowsResult(IPCQueryRequest(name: .windows)))
        case .displayChanged:
            self.init(displays: queryRouter.displaysResult(IPCQueryRequest(name: .displays)))
        case .layoutChanged:
            self.init(workspaces: queryRouter.workspacesResult(IPCQueryRequest(name: .workspaces)))
        }
    }
}

extension IPCResponse {
    init(failing request: IPCRequest, code: IPCErrorCode, result: IPCResult? = nil) {
        self = .failure(
            id: request.id,
            kind: IPCResponseKind(requestKind: request.kind),
            code: code,
            result: result
        )
    }
}
