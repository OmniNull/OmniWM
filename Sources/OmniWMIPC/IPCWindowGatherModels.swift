// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public struct IPCWindowGatherRequest: Codable, Equatable, Sendable {
    public let windowIds: [String]
    public let workspaceTarget: WorkspaceTarget

    public init(windowIds: [String], workspaceTarget: WorkspaceTarget) {
        self.windowIds = windowIds
        self.workspaceTarget = workspaceTarget
    }
}

public enum IPCWindowGatherOutcome: String, Codable, Equatable, Sendable {
    case gathered
    case unchanged
    case refused
}

public enum IPCWindowGatherWindowStatus: String, Codable, Equatable, Sendable {
    case moved
    case unchanged
    case blocked
    case refused
    case unresolved
}

public enum IPCWindowGatherReason: String, Codable, Equatable, Sendable {
    case invalidWindowId = "invalid_window_id"
    case staleWindowId = "stale_window_id"
    case duplicateWindow = "duplicate_window"
    case notFound = "not_found"
    case scratchpad
    case nativeFullscreen = "native_fullscreen"
    case appHidden = "app_hidden"
    case minimized
    case nativeWithdrawn = "native_withdrawn"
    case floating
    case unsupportedLayout = "unsupported_layout"
    case layoutConflict = "layout_conflict"
    case layoutFullscreen = "layout_fullscreen"
    case noWindows = "no_windows"
    case destinationNotFound = "destination_not_found"
    case invalidDestination = "invalid_destination"
    case windowRefused = "window_refused"
    case doesNotFit = "does_not_fit"
    case stalePlan = "stale_plan"
}

public struct IPCWindowGatherWindowResult: Codable, Equatable, Sendable {
    public let windowId: String
    public let status: IPCWindowGatherWindowStatus
    public let reason: IPCWindowGatherReason?

    public init(windowId: String, status: IPCWindowGatherWindowStatus, reason: IPCWindowGatherReason? = nil) {
        self.windowId = windowId
        self.status = status
        self.reason = reason
    }
}

public struct IPCWindowGatherResult: Codable, Equatable, Sendable {
    public let outcome: IPCWindowGatherOutcome
    public let workspace: IPCWorkspaceRef?
    public let reason: IPCWindowGatherReason?
    public let windows: [IPCWindowGatherWindowResult]
    public let moved: [String]
    public let relayoutWorkspaces: [IPCWorkspaceRef]
    public let modelCommitted: Bool
    public let relayoutRequested: Bool

    public init(
        outcome: IPCWindowGatherOutcome,
        workspace: IPCWorkspaceRef?,
        reason: IPCWindowGatherReason? = nil,
        windows: [IPCWindowGatherWindowResult],
        moved: [String] = [],
        relayoutWorkspaces: [IPCWorkspaceRef] = []
    ) {
        self.outcome = outcome
        self.workspace = workspace
        self.reason = reason
        self.windows = windows
        self.moved = moved
        self.relayoutWorkspaces = relayoutWorkspaces
        modelCommitted = outcome == .gathered
        relayoutRequested = outcome == .gathered
    }
}

public struct IPCWindowGatherActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let summary: String
    public let arguments: [String]

    public init(path: String, summary: String, arguments: [String]) {
        self.path = path
        self.summary = summary
        self.arguments = arguments
    }
}
