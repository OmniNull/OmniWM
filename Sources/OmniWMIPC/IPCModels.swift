// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public enum OmniWMIPCProtocol {
    public static let version = 16
}

public struct IPCNoPayload: Codable, Equatable, Sendable {
    public init() {}
}

public enum IPCRequestKind: String, Codable, Equatable, Sendable {
    case ping
    case version
    case command
    case capture
    case query
    case rule
    case workspace
    case window
    case windowMark = "window-mark"
    case subscribe
}

public enum IPCResponseKind: String, Codable, Equatable, Sendable {
    case ping
    case version
    case command
    case capture
    case query
    case rule
    case workspace
    case window
    case windowMark = "window-mark"
    case subscribe
    case error

    public init(requestKind: IPCRequestKind) {
        switch requestKind {
        case .ping:
            self = .ping
        case .version:
            self = .version
        case .command:
            self = .command
        case .capture:
            self = .capture
        case .query:
            self = .query
        case .rule:
            self = .rule
        case .workspace:
            self = .workspace
        case .window:
            self = .window
        case .windowMark:
            self = .windowMark
        case .subscribe:
            self = .subscribe
        }
    }
}

public enum IPCResponseStatus: String, Codable, Equatable, Sendable {
    case success
    case executed
    case ignored
    case error
    case subscribed
}

public enum IPCErrorCode: String, Codable, Equatable, Sendable, Error {
    case invalidRequest = "invalid_request"
    case invalidArguments = "invalid_arguments"
    case protocolMismatch = "protocol_mismatch"
    case disabled = "ignored_disabled"
    case overviewOpen = "ignored_overview"
    case layoutMismatch = "layout_mismatch"
    case unauthorized = "unauthorized"
    case staleWindowId = "stale_window_id"
    case notFound = "not_found"
    case noChange = "no_change"
    case windowActionFailed = "window_action_failed"
    case workspaceAssignmentConflict = "workspace_assignment_conflict"
    case workspaceStateConflict = "workspace_state_conflict"
    case captureStateConflict = "capture_state_conflict"
    case staleMark = "stale_mark"
    case unknownMark = "unknown_mark"
    case noFocusedWindow = "no_focused_window"
    case selfSummon = "self_summon"
    case hiddenWindow = "hidden_window"
    case unsupportedLayout = "unsupported_layout"
    case duplicateMark = "duplicate_mark"
    case invalidMark = "invalid_mark"
    case internalError = "internal_error"
}

public enum IPCDirection: String, Codable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

public enum IPCResizeAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public enum IPCWindowMode: String, Codable, Equatable, Sendable {
    case tiling
    case floating
}

public enum IPCWorkspaceLayout: String, Codable, Equatable, Sendable {
    case defaultLayout = "default"
    case niri
    case dwindle
}

public enum IPCHiddenReason: String, Codable, Equatable, Sendable {
    case workspaceInactive = "workspace-inactive"
    case tabInactive = "tab-inactive"
    case layoutTransient = "layout-transient"
    case scratchpad
}

public enum IPCLayoutReason: String, Codable, Equatable, Sendable {
    case standard
    case nativeFullscreen = "native-fullscreen"
}

public enum IPCManualWindowOverride: String, Codable, Equatable, Sendable {
    case forceTile = "force-tile"
    case forceFloat = "force-float"
}

public enum IPCDisplayOrientation: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public enum IPCRuleLayout: String, Codable, Equatable, Sendable {
    case auto
    case tile
    case float
}

public enum IPCResizeOperation: String, Codable, Equatable, Sendable {
    case grow
    case shrink
}

public struct IPCWorkspaceRef: Codable, Equatable, Sendable {
    public let id: String
    public let rawName: String
    public let displayName: String
    public let number: Int?

    public init(id: String, rawName: String, displayName: String, number: Int?) {
        self.id = id
        self.rawName = rawName
        self.displayName = displayName
        self.number = number
    }
}

public struct IPCDisplayRef: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isMain: Bool

    public init(id: String, name: String, isMain: Bool) {
        self.id = id
        self.name = name
        self.isMain = isMain
    }
}

public struct IPCAppRef: Codable, Equatable, Sendable {
    public let name: String
    public let bundleId: String?

    public init(name: String, bundleId: String?) {
        self.name = name
        self.bundleId = bundleId
    }
}

public struct IPCWorkspaceWindowCounts: Codable, Equatable, Sendable {
    public let total: Int
    public let tiled: Int
    public let floating: Int
    public let scratchpad: Int

    public init(total: Int, tiled: Int, floating: Int, scratchpad: Int) {
        self.total = total
        self.tiled = tiled
        self.floating = floating
        self.scratchpad = scratchpad
    }
}

public struct IPCSize: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct IPCRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
