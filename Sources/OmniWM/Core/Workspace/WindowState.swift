// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct ManagedReplacementMetadata: Equatable, Sendable {
    var bundleId: String?
    var workspaceId: WorkspaceDescriptor.ID
    var mode: TrackedWindowMode
    var role: String?
    var subrole: String?
    var title: String?
    var windowLevel: Int32?
    var parentWindowId: UInt32?
    var frame: CGRect?
    var transientWindowServerEvidence = false
    var degradedWindowServerChildEvidence = false
    var readOnlyAdmissionFrame: CGRect?

    func mergingNonNilValues(from overlay: ManagedReplacementMetadata) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: overlay.bundleId ?? bundleId,
            workspaceId: overlay.workspaceId,
            mode: overlay.mode,
            role: overlay.role ?? role,
            subrole: overlay.subrole ?? subrole,
            title: overlay.title ?? title,
            windowLevel: overlay.windowLevel ?? windowLevel,
            parentWindowId: overlay.parentWindowId ?? parentWindowId,
            frame: overlay.frame ?? frame,
            transientWindowServerEvidence: transientWindowServerEvidence || overlay.transientWindowServerEvidence,
            degradedWindowServerChildEvidence: degradedWindowServerChildEvidence
                || overlay.degradedWindowServerChildEvidence
        )
    }
}

enum LayoutReason: Codable, Equatable {
    case standard
    case nativeFullscreen
}

enum ManagedWindowLifetimeAuthority: Equatable, Sendable {
    case axTopLevelInventory
    case directLifecycle
}

enum HiddenReason: Equatable {
    case workspaceInactive
    case layoutTransient(HideSide)
    case scratchpad
}

struct HiddenState: Equatable {
    static func proportionalPosition(topLeft: CGPoint, in frame: CGRect) -> CGPoint {
        let width = max(1, frame.width)
        let height = max(1, frame.height)
        let x = (topLeft.x - frame.minX) / width
        let y = (frame.maxY - topLeft.y) / height
        return CGPoint(x: min(max(0, x), 1), y: min(max(0, y), 1))
    }

    let proportionalPosition: CGPoint
    let referenceMonitorId: Monitor.ID?
    let reason: HiddenReason

    var workspaceInactive: Bool {
        if case .workspaceInactive = reason {
            return true
        }
        return false
    }

    var offscreenSide: HideSide? {
        if case let .layoutTransient(side) = reason {
            return side
        }
        return nil
    }

    var isScratchpad: Bool {
        if case .scratchpad = reason {
            return true
        }
        return false
    }

    var restoresViaFloatingState: Bool {
        switch reason {
        case .workspaceInactive,
             .scratchpad:
            true
        case .layoutTransient:
            false
        }
    }

    init(
        proportionalPosition: CGPoint,
        referenceMonitorId: Monitor.ID?,
        reason: HiddenReason
    ) {
        self.proportionalPosition = proportionalPosition
        self.referenceMonitorId = referenceMonitorId
        self.reason = reason
    }

    init(
        proportionalPosition: CGPoint,
        referenceMonitorId: Monitor.ID?,
        workspaceInactive: Bool,
        offscreenSide: HideSide? = nil
    ) {
        self.proportionalPosition = proportionalPosition
        self.referenceMonitorId = referenceMonitorId
        if workspaceInactive {
            reason = .workspaceInactive
        } else if let offscreenSide {
            reason = .layoutTransient(offscreenSide)
        } else {
            reason = .scratchpad
        }
    }
}

struct FloatingState: Equatable {
    var lastFrame: CGRect
    var normalizedOrigin: CGPoint?
    var referenceMonitorId: Monitor.ID?
    var restoreToFloating: Bool
}

enum HostedWindowRole: Equatable, Sendable {
    case main
    case sheet(parent: WindowToken, declarationID: String)
    case utility(parent: WindowToken, declarationID: String)

    var parent: WindowToken? {
        switch self {
        case .main: nil
        case let .sheet(parent, _),
             let .utility(parent, _): parent
        }
    }

    var declarationID: String? {
        switch self {
        case .main: nil
        case let .sheet(_, id),
             let .utility(_, id): id
        }
    }

    var isSheet: Bool {
        switch self {
        case .sheet: true
        case .main,
             .utility: false
        }
    }
}

struct HostedWindowMetadata: Equatable, Sendable {
    let appId: String
    let title: String
    let minimumSize: CGSize
    var icon = "app"
    var instanceID = UUID()
    var rootID = UUID()
    var role = HostedWindowRole.main
    var admitsFloating = false
}

extension HostedWindowMetadata {
    static let settingsAppID = Bundle.main.bundleIdentifier ?? "com.barut.OmniWM"
    static let settingsIcon = "gearshape"
}

enum WindowTarget: Equatable, Sendable {
    case external(AXWindowRef)
    case hosted(HostedWindowMetadata)

    var axRef: AXWindowRef? {
        guard case let .external(reference) = self else { return nil }
        return reference
    }

    var hostedMetadata: HostedWindowMetadata? {
        guard case let .hosted(metadata) = self else { return nil }
        return metadata
    }
}

struct WindowState: Equatable {
    var token: WindowToken
    var target: WindowTarget

    var axRef: AXWindowRef? {
        target.axRef
    }

    var workspaceId: WorkspaceDescriptor.ID
    var mode: TrackedWindowMode
    var lifecyclePhase: WindowLifecyclePhase
    var observedState: ObservedWindowState
    var desiredState: DesiredWindowState
    var restoreIntent: RestoreIntent?
    var managedReplacementMetadata: ManagedReplacementMetadata?
    var floatingState: FloatingState?
    var manualLayoutOverride: ManualWindowOverride?
    var ruleEffects: ManagedWindowRuleEffects = .none
    var admissionHints: ManagedWindowAdmissionHints = .none
    var lifetimeAuthority: ManagedWindowLifetimeAuthority
    var hiddenState: HiddenState?
    var layoutReason: LayoutReason = .standard

    var pid: pid_t {
        token.pid
    }

    var windowId: Int {
        token.windowId
    }

    init(
        token: WindowToken,
        axRef: AXWindowRef,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        managedReplacementMetadata: ManagedReplacementMetadata?,
        ruleEffects: ManagedWindowRuleEffects,
        admissionHints: ManagedWindowAdmissionHints,
        lifetimeAuthority: ManagedWindowLifetimeAuthority = .axTopLevelInventory
    ) {
        self.init(
            token: token,
            target: .external(axRef),
            workspaceId: workspaceId,
            mode: mode,
            managedReplacementMetadata: managedReplacementMetadata,
            ruleEffects: ruleEffects,
            admissionHints: admissionHints,
            lifetimeAuthority: lifetimeAuthority
        )
    }

    init(
        token: WindowToken,
        target: WindowTarget,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        managedReplacementMetadata: ManagedReplacementMetadata?,
        ruleEffects: ManagedWindowRuleEffects,
        admissionHints: ManagedWindowAdmissionHints,
        lifetimeAuthority: ManagedWindowLifetimeAuthority = .axTopLevelInventory
    ) {
        self.token = token
        self.target = target
        self.workspaceId = workspaceId
        self.mode = mode
        lifecyclePhase = mode == .floating ? .floating : .tiled
        observedState = .initial(
            workspaceId: workspaceId,
            monitorId: nil
        )
        desiredState = .initial(
            workspaceId: workspaceId,
            monitorId: nil,
            disposition: mode
        )
        self.managedReplacementMetadata = managedReplacementMetadata
        self.ruleEffects = ruleEffects
        self.admissionHints = admissionHints
        self.lifetimeAuthority = lifetimeAuthority
    }
}
