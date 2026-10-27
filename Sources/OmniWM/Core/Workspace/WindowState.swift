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
    case quake
}

struct HiddenState: Equatable {
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
             .scratchpad,
             .quake:
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

struct WindowState: Equatable {
    var token: WindowToken
    var axRef: AXWindowRef
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
        self.token = token
        self.axRef = axRef
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
