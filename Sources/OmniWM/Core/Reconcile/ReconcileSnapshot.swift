// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum WindowLifecyclePhase: String, Codable, Equatable {
    case tiled
    case floating
    case hidden
    case offscreen
    case replacing
    case nativeFullscreen
    case destroyed
}

struct ObservedWindowState: Equatable {
    var frame: CGRect?
    var workspaceId: WorkspaceDescriptor.ID?
    var monitorId: Monitor.ID?
    var isVisible: Bool
    var isNativeFullscreen: Bool
    var isMinimized = false
    var isNativeWithdrawn = false

    var isNativeSuppressed: Bool {
        isMinimized || isNativeWithdrawn
    }

    static func initial(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?
    ) -> ObservedWindowState {
        ObservedWindowState(
            frame: nil,
            workspaceId: workspaceId,
            monitorId: monitorId,
            isVisible: true,
            isNativeFullscreen: false
        )
    }
}

struct DesiredWindowState: Equatable {
    var workspaceId: WorkspaceDescriptor.ID?
    var monitorId: Monitor.ID?
    var disposition: TrackedWindowMode?
    var floatingFrame: CGRect?
    var rescueEligible: Bool

    static func initial(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        disposition: TrackedWindowMode
    ) -> DesiredWindowState {
        DesiredWindowState(
            workspaceId: workspaceId,
            monitorId: monitorId,
            disposition: disposition,
            floatingFrame: nil,
            rescueEligible: disposition == .floating
        )
    }

    var summary: String {
        var parts: [String] = []
        if let workspaceId {
            parts.append("workspace=\(workspaceId.uuidString)")
        }
        if let disposition {
            parts.append("mode=\(disposition)")
        }
        if rescueEligible {
            parts.append("rescue=true")
        }
        return parts.joined(separator: ",")
    }
}

struct DisplayFingerprint: Hashable, Equatable, Codable, Sendable {
    let displayUUID: String?
    let displayId: CGDirectDisplayID
    let name: String
    let anchorPoint: CGPoint
    let frameSize: CGSize

    init(monitor: Monitor) {
        displayUUID = monitor.displayUUID
        displayId = monitor.displayId
        name = monitor.name
        anchorPoint = monitor.workspaceAnchorPoint
        frameSize = monitor.frame.size
    }

    private enum CodingKeys: String, CodingKey {
        case displayUUID, displayId, name, anchorPoint, frameSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayUUID = try DisplayUUID.decode(from: container, forKey: .displayUUID)
        displayId = try container.decode(CGDirectDisplayID.self, forKey: .displayId)
        name = try container.decode(String.self, forKey: .name)
        anchorPoint = try container.decode(CGPoint.self, forKey: .anchorPoint)
        frameSize = try container.decode(CGSize.self, forKey: .frameSize)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(displayUUID, forKey: .displayUUID)
        try container.encode(displayId, forKey: .displayId)
        try container.encode(name, forKey: .name)
        try container.encode(anchorPoint, forKey: .anchorPoint)
        try container.encode(frameSize, forKey: .frameSize)
    }
}

struct TopologyProfile: Hashable, Equatable, Codable, Sendable {
    let displays: [DisplayFingerprint]

    init(monitors: [Monitor]) {
        self.init(sortedMonitors: Monitor.sortedByPosition(monitors))
    }

    init(sortedMonitors: [Monitor]) {
        displays = sortedMonitors.map(DisplayFingerprint.init)
    }

    func containsDisplay(_ displayId: CGDirectDisplayID) -> Bool {
        for index in displays.indices where displays[index].displayId == displayId {
            return true
        }
        return false
    }
}

struct RestoreIntent: Equatable {
    let topologyProfile: TopologyProfile
    var workspaceId: WorkspaceDescriptor.ID
    var preferredMonitor: DisplayFingerprint?
    var floatingFrame: CGRect?
    var normalizedFloatingOrigin: CGPoint?
    var restoreToFloating: Bool
    var rescueEligible: Bool
    var niriPlacement: PersistedNiriPlacement?
    var detachedNiriContainerSizingState: NiriContainerSizingState?
    var dwindlePlacement: PersistedDwindlePlacement?
}

enum ReplacementCorrelation {
    enum Reason: String, Equatable {
        case managedReplacement
        case nativeFullscreen
        case manualRekey
    }
}

struct ReconcileWindowSnapshot: Equatable {
    let token: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let mode: TrackedWindowMode
    let lifecyclePhase: WindowLifecyclePhase
    let observedState: ObservedWindowState
    let desiredState: DesiredWindowState
    let restoreWorkspaceId: WorkspaceDescriptor.ID?
    let lifetimeAuthority: ManagedWindowLifetimeAuthority

    init(
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        lifecyclePhase: WindowLifecyclePhase,
        observedState: ObservedWindowState,
        desiredState: DesiredWindowState,
        restoreWorkspaceId: WorkspaceDescriptor.ID?,
        lifetimeAuthority: ManagedWindowLifetimeAuthority = .axTopLevelInventory
    ) {
        self.token = token
        self.workspaceId = workspaceId
        self.mode = mode
        self.lifecyclePhase = lifecyclePhase
        self.observedState = observedState
        self.desiredState = desiredState
        self.restoreWorkspaceId = restoreWorkspaceId
        self.lifetimeAuthority = lifetimeAuthority
    }
}

struct ReconcileSnapshot: Equatable {
    let topologyProfile: TopologyProfile
    let focusSession: FocusSessionSnapshot
    let windows: [ReconcileWindowSnapshot]
    var viewports: [WorkspaceDescriptor.ID: ViewportState] = [:]
    var layouts: [WorkspaceDescriptor.ID: LayoutTopology] = [:]

    var selectedManagedToken: WindowToken? {
        focusSession.selectedManagedToken
    }

    var nativeManagedFocusToken: WindowToken? {
        focusSession.nativeFocusOwner.managedToken
    }

    var interactionMonitorId: Monitor.ID? {
        focusSession.interactionMonitorId
    }

    var previousInteractionMonitorId: Monitor.ID? {
        focusSession.previousInteractionMonitorId
    }
}
