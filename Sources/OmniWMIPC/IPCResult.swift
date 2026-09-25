// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public enum IPCResultKind: String, Codable, Equatable, Sendable {
    case pong
    case version
    case capture
    case workspaceBar = "workspace-bar"
    case activeWorkspace = "active-workspace"
    case focusedMonitor = "focused-monitor"
    case apps
    case focusedWindow = "focused-window"
    case windows
    case workspaces
    case displays
    case rules
    case ruleActions = "rule-actions"
    case queries
    case commands
    case subscriptions
    case capabilities
    case subscribed
    case windowMarks = "window-marks"
    case metrics
}

public struct IPCPingResult: Codable, Equatable, Sendable {
    public let message: String

    public init(message: String = "pong") {
        self.message = message
    }
}

public struct IPCVersionResult: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let appVersion: String?
    public let gitHash: String?
    public let buildConfiguration: String?
    public let executableSHA256: String?

    public init(
        protocolVersion: Int = OmniWMIPCProtocol.version,
        appVersion: String?,
        gitHash: String? = nil,
        buildConfiguration: String? = nil,
        executableSHA256: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.gitHash = gitHash
        self.buildConfiguration = buildConfiguration
        self.executableSHA256 = executableSHA256
    }
}

public struct IPCResult: Codable, Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case pong(IPCPingResult)
        case version(IPCVersionResult)
        case capture(IPCCaptureResult)
        case workspaceBar(IPCWorkspaceBarQueryResult)
        case activeWorkspace(IPCActiveWorkspaceQueryResult)
        case focusedMonitor(IPCFocusedMonitorQueryResult)
        case apps(IPCAppsQueryResult)
        case focusedWindow(IPCFocusedWindowQueryResult)
        case windows(IPCWindowsQueryResult)
        case workspaces(IPCWorkspacesQueryResult)
        case displays(IPCDisplaysQueryResult)
        case rules(IPCRulesQueryResult)
        case ruleActions(IPCRuleActionsQueryResult)
        case queries(IPCQueriesQueryResult)
        case commands(IPCCommandsQueryResult)
        case subscriptions(IPCSubscriptionsQueryResult)
        case capabilities(IPCCapabilitiesQueryResult)
        case subscribed(IPCSubscribeResult)
        case windowMarks(IPCWindowMarksResult)
        case metrics(IPCMetricsQueryResult)
    }

    public let kind: IPCResultKind
    public let payload: Payload

    public init(kind: IPCResultKind, payload: Payload) {
        self.kind = kind
        self.payload = payload
    }

    public init(pong: IPCPingResult) {
        self.init(kind: .pong, payload: .pong(pong))
    }

    public init(version: IPCVersionResult) {
        self.init(kind: .version, payload: .version(version))
    }

    public init(capture: IPCCaptureResult) {
        self.init(kind: .capture, payload: .capture(capture))
    }

    public init(workspaceBar: IPCWorkspaceBarQueryResult) {
        self.init(kind: .workspaceBar, payload: .workspaceBar(workspaceBar))
    }

    public init(activeWorkspace: IPCActiveWorkspaceQueryResult) {
        self.init(kind: .activeWorkspace, payload: .activeWorkspace(activeWorkspace))
    }

    public init(focusedMonitor: IPCFocusedMonitorQueryResult) {
        self.init(kind: .focusedMonitor, payload: .focusedMonitor(focusedMonitor))
    }

    public init(apps: IPCAppsQueryResult) {
        self.init(kind: .apps, payload: .apps(apps))
    }

    public init(focusedWindow: IPCFocusedWindowQueryResult) {
        self.init(kind: .focusedWindow, payload: .focusedWindow(focusedWindow))
    }

    public init(windows: IPCWindowsQueryResult) {
        self.init(kind: .windows, payload: .windows(windows))
    }

    public init(workspaces: IPCWorkspacesQueryResult) {
        self.init(kind: .workspaces, payload: .workspaces(workspaces))
    }

    public init(displays: IPCDisplaysQueryResult) {
        self.init(kind: .displays, payload: .displays(displays))
    }

    public init(rules: IPCRulesQueryResult) {
        self.init(kind: .rules, payload: .rules(rules))
    }

    public init(ruleActions: IPCRuleActionsQueryResult) {
        self.init(kind: .ruleActions, payload: .ruleActions(ruleActions))
    }

    public init(queries: IPCQueriesQueryResult) {
        self.init(kind: .queries, payload: .queries(queries))
    }

    public init(commands: IPCCommandsQueryResult) {
        self.init(kind: .commands, payload: .commands(commands))
    }

    public init(subscriptions: IPCSubscriptionsQueryResult) {
        self.init(kind: .subscriptions, payload: .subscriptions(subscriptions))
    }

    public init(capabilities: IPCCapabilitiesQueryResult) {
        self.init(kind: .capabilities, payload: .capabilities(capabilities))
    }

    public init(subscribed: IPCSubscribeResult) {
        self.init(kind: .subscribed, payload: .subscribed(subscribed))
    }

    public init(windowMarks: IPCWindowMarksResult) {
        self.init(kind: .windowMarks, payload: .windowMarks(windowMarks))
    }

    public init(metrics: IPCMetricsQueryResult) {
        self.init(kind: .metrics, payload: .metrics(metrics))
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(IPCResultKind.self, forKey: .kind)

        switch kind {
        case .pong:
            payload = .pong(try container.decode(IPCPingResult.self, forKey: .payload))
        case .version:
            payload = .version(try container.decode(IPCVersionResult.self, forKey: .payload))
        case .capture:
            payload = .capture(try container.decode(IPCCaptureResult.self, forKey: .payload))
        case .workspaceBar:
            payload = .workspaceBar(try container.decode(IPCWorkspaceBarQueryResult.self, forKey: .payload))
        case .activeWorkspace:
            payload = .activeWorkspace(try container.decode(IPCActiveWorkspaceQueryResult.self, forKey: .payload))
        case .focusedMonitor:
            payload = .focusedMonitor(try container.decode(IPCFocusedMonitorQueryResult.self, forKey: .payload))
        case .apps:
            payload = .apps(try container.decode(IPCAppsQueryResult.self, forKey: .payload))
        case .focusedWindow:
            payload = .focusedWindow(try container.decode(IPCFocusedWindowQueryResult.self, forKey: .payload))
        case .windows:
            payload = .windows(try container.decode(IPCWindowsQueryResult.self, forKey: .payload))
        case .workspaces:
            payload = .workspaces(try container.decode(IPCWorkspacesQueryResult.self, forKey: .payload))
        case .displays:
            payload = .displays(try container.decode(IPCDisplaysQueryResult.self, forKey: .payload))
        case .rules:
            payload = .rules(try container.decode(IPCRulesQueryResult.self, forKey: .payload))
        case .ruleActions:
            payload = .ruleActions(try container.decode(IPCRuleActionsQueryResult.self, forKey: .payload))
        case .queries:
            payload = .queries(try container.decode(IPCQueriesQueryResult.self, forKey: .payload))
        case .commands:
            payload = .commands(try container.decode(IPCCommandsQueryResult.self, forKey: .payload))
        case .subscriptions:
            payload = .subscriptions(try container.decode(IPCSubscriptionsQueryResult.self, forKey: .payload))
        case .capabilities:
            payload = .capabilities(try container.decode(IPCCapabilitiesQueryResult.self, forKey: .payload))
        case .subscribed:
            payload = .subscribed(try container.decode(IPCSubscribeResult.self, forKey: .payload))
        case .windowMarks:
            payload = .windowMarks(try container.decode(IPCWindowMarksResult.self, forKey: .payload))
        case .metrics:
            payload = .metrics(try container.decode(IPCMetricsQueryResult.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)

        switch payload {
        case let .pong(payload):
            try container.encode(payload, forKey: .payload)
        case let .version(payload):
            try container.encode(payload, forKey: .payload)
        case let .capture(payload):
            try container.encode(payload, forKey: .payload)
        case let .workspaceBar(payload):
            try container.encode(payload, forKey: .payload)
        case let .activeWorkspace(payload):
            try container.encode(payload, forKey: .payload)
        case let .focusedMonitor(payload):
            try container.encode(payload, forKey: .payload)
        case let .apps(payload):
            try container.encode(payload, forKey: .payload)
        case let .focusedWindow(payload):
            try container.encode(payload, forKey: .payload)
        case let .windows(payload):
            try container.encode(payload, forKey: .payload)
        case let .workspaces(payload):
            try container.encode(payload, forKey: .payload)
        case let .displays(payload):
            try container.encode(payload, forKey: .payload)
        case let .rules(payload):
            try container.encode(payload, forKey: .payload)
        case let .ruleActions(payload):
            try container.encode(payload, forKey: .payload)
        case let .queries(payload):
            try container.encode(payload, forKey: .payload)
        case let .commands(payload):
            try container.encode(payload, forKey: .payload)
        case let .subscriptions(payload):
            try container.encode(payload, forKey: .payload)
        case let .capabilities(payload):
            try container.encode(payload, forKey: .payload)
        case let .subscribed(payload):
            try container.encode(payload, forKey: .payload)
        case let .windowMarks(payload):
            try container.encode(payload, forKey: .payload)
        case let .metrics(payload):
            try container.encode(payload, forKey: .payload)
        }
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let kind: IPCResponseKind
    public let ok: Bool
    public let status: IPCResponseStatus
    public let code: IPCErrorCode?
    public let result: IPCResult?

    public init(
        version: Int = OmniWMIPCProtocol.version,
        id: String,
        kind: IPCResponseKind,
        ok: Bool,
        status: IPCResponseStatus,
        code: IPCErrorCode? = nil,
        result: IPCResult? = nil
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.ok = ok
        self.status = status
        self.code = code
        self.result = result
    }

    public static func success(
        id: String,
        kind: IPCResponseKind,
        status: IPCResponseStatus = .success,
        result: IPCResult? = nil
    ) -> IPCResponse {
        IPCResponse(id: id, kind: kind, ok: true, status: status, result: result)
    }

    public static func failure(
        id: String,
        kind: IPCResponseKind,
        status: IPCResponseStatus = .error,
        code: IPCErrorCode,
        result: IPCResult? = nil
    ) -> IPCResponse {
        IPCResponse(id: id, kind: kind, ok: false, status: status, code: code, result: result)
    }
}
