// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public struct IPCQueriesQueryResult: Codable, Equatable, Sendable {
    public let queries: [IPCQueryDescriptor]

    public init(queries: [IPCQueryDescriptor]) {
        self.queries = queries
    }
}

public struct IPCRuleActionsQueryResult: Codable, Equatable, Sendable {
    public let ruleActions: [IPCRuleActionDescriptor]

    public init(ruleActions: [IPCRuleActionDescriptor]) {
        self.ruleActions = ruleActions
    }
}

public struct IPCCommandsQueryResult: Codable, Equatable, Sendable {
    public let commands: [IPCCommandDescriptor]
    public let workspaceActions: [IPCWorkspaceActionDescriptor]
    public let windowActions: [IPCWindowActionDescriptor]
    public let windowMarkActions: [IPCWindowMarkActionDescriptor]

    public init(
        commands: [IPCCommandDescriptor],
        workspaceActions: [IPCWorkspaceActionDescriptor],
        windowActions: [IPCWindowActionDescriptor],
        windowMarkActions: [IPCWindowMarkActionDescriptor] = []
    ) {
        self.commands = commands
        self.workspaceActions = workspaceActions
        self.windowActions = windowActions
        self.windowMarkActions = windowMarkActions
    }

    private enum CodingKeys: String, CodingKey {
        case commands
        case workspaceActions
        case windowActions
        case windowMarkActions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commands = try container.decode([IPCCommandDescriptor].self, forKey: .commands)
        workspaceActions = try container.decode([IPCWorkspaceActionDescriptor].self, forKey: .workspaceActions)
        windowActions = try container.decode([IPCWindowActionDescriptor].self, forKey: .windowActions)
        windowMarkActions = try container.decodeIfPresent(
            [IPCWindowMarkActionDescriptor].self,
            forKey: .windowMarkActions
        ) ?? []
    }
}

public struct IPCSubscriptionsQueryResult: Codable, Equatable, Sendable {
    public let subscriptions: [IPCSubscriptionDescriptor]

    public init(subscriptions: [IPCSubscriptionDescriptor]) {
        self.subscriptions = subscriptions
    }
}

public struct IPCCapabilitiesQueryResult: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let appVersion: String?
    public let authorizationRequired: Bool
    public let windowIdScope: String
    public let queries: [IPCQueryDescriptor]
    public let commands: [IPCCommandDescriptor]
    public let captureActions: [IPCCaptureActionDescriptor]
    public let ruleActions: [IPCRuleActionDescriptor]
    public let workspaceActions: [IPCWorkspaceActionDescriptor]
    public let windowActions: [IPCWindowActionDescriptor]
    public let windowMarkActions: [IPCWindowMarkActionDescriptor]
    public let subscriptions: [IPCSubscriptionDescriptor]

    public init(
        protocolVersion: Int = OmniWMIPCProtocol.version,
        appVersion: String?,
        authorizationRequired: Bool,
        windowIdScope: String,
        queries: [IPCQueryDescriptor],
        commands: [IPCCommandDescriptor],
        captureActions: [IPCCaptureActionDescriptor],
        ruleActions: [IPCRuleActionDescriptor],
        workspaceActions: [IPCWorkspaceActionDescriptor],
        windowActions: [IPCWindowActionDescriptor],
        windowMarkActions: [IPCWindowMarkActionDescriptor] = [],
        subscriptions: [IPCSubscriptionDescriptor]
    ) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.authorizationRequired = authorizationRequired
        self.windowIdScope = windowIdScope
        self.queries = queries
        self.commands = commands
        self.captureActions = captureActions
        self.ruleActions = ruleActions
        self.workspaceActions = workspaceActions
        self.windowActions = windowActions
        self.windowMarkActions = windowMarkActions
        self.subscriptions = subscriptions
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case appVersion
        case authorizationRequired
        case windowIdScope
        case queries
        case commands
        case captureActions
        case ruleActions
        case workspaceActions
        case windowActions
        case windowMarkActions
        case subscriptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        authorizationRequired = try container.decode(Bool.self, forKey: .authorizationRequired)
        windowIdScope = try container.decode(String.self, forKey: .windowIdScope)
        queries = try container.decode([IPCQueryDescriptor].self, forKey: .queries)
        commands = try container.decode([IPCCommandDescriptor].self, forKey: .commands)
        captureActions = try container.decode([IPCCaptureActionDescriptor].self, forKey: .captureActions)
        ruleActions = try container.decode([IPCRuleActionDescriptor].self, forKey: .ruleActions)
        workspaceActions = try container.decode([IPCWorkspaceActionDescriptor].self, forKey: .workspaceActions)
        windowActions = try container.decode([IPCWindowActionDescriptor].self, forKey: .windowActions)
        windowMarkActions = try container.decodeIfPresent(
            [IPCWindowMarkActionDescriptor].self,
            forKey: .windowMarkActions
        ) ?? []
        subscriptions = try container.decode([IPCSubscriptionDescriptor].self, forKey: .subscriptions)
    }
}
