// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct KeyboardFocusTarget {
    let token: WindowToken
    let axRef: AXWindowRef
    let workspaceId: WorkspaceDescriptor.ID?
    let isManaged: Bool

    var pid: pid_t {
        token.pid
    }

    var windowId: Int {
        token.windowId
    }
}

extension KeyboardFocusTarget: Equatable {
    static func == (lhs: KeyboardFocusTarget, rhs: KeyboardFocusTarget) -> Bool {
        lhs.token == rhs.token
            && lhs.workspaceId == rhs.workspaceId
            && lhs.isManaged == rhs.isManaged
    }
}

enum ManagedFocusOrigin: Equatable {
    case keyboardOrProgrammatic
    case pointerSelection
    case pointerHover
    case focusFollowsMouse

    var allowsMouseToFocusedWarp: Bool {
        self == .keyboardOrProgrammatic
    }

    var preservesViewportOnActivation: Bool {
        self == .pointerHover || self == .focusFollowsMouse
    }

    func merged(with origin: ManagedFocusOrigin) -> ManagedFocusOrigin {
        mergeRank >= origin.mergeRank ? self : origin
    }

    private var mergeRank: Int {
        switch self {
        case .keyboardOrProgrammatic: 3
        case .pointerSelection: 2
        case .pointerHover: 1
        case .focusFollowsMouse: 0
        }
    }
}

struct ManagedFocusRequest: Equatable {
    enum Phase: Equatable, Sendable {
        case awaitingSameAppActivation(sourceToken: WindowToken, isRetry: Bool = false)
        case awaitingConfirmation
    }

    enum Status: Equatable {
        case pending
        case confirmed
    }

    let requestId: UInt64
    var token: WindowToken
    var workspaceId: WorkspaceDescriptor.ID
    var origin: ManagedFocusOrigin
    var phase: Phase
    var retryCount: Int = 0
    var lastActivationSource: ActivationEventSource?
    var status: Status = .pending
}
