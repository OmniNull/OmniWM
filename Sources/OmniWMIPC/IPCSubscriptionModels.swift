// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public enum IPCSubscriptionChannel: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case focus
    case workspaceBar = "workspace-bar"
    case activeWorkspace = "active-workspace"
    case focusedMonitor = "focused-monitor"
    case windowsChanged = "windows-changed"
    case displayChanged = "display-changed"
    case layoutChanged = "layout-changed"
    case shellWidgets = "shell-widgets"
}

public enum IPCEventKind: String, Codable, Equatable, Sendable {
    case event
}

public struct IPCSubscribeRequest: Codable, Equatable, Sendable {
    public let channels: [IPCSubscriptionChannel]
    public let allChannels: Bool
    public let sendInitial: Bool

    public init(
        channels: [IPCSubscriptionChannel],
        allChannels: Bool = false,
        sendInitial: Bool = true
    ) {
        self.channels = channels
        self.allChannels = allChannels
        self.sendInitial = sendInitial
    }
}

public struct IPCSubscribeResult: Codable, Equatable, Sendable {
    public let channels: [IPCSubscriptionChannel]

    public init(channels: [IPCSubscriptionChannel]) {
        self.channels = channels
    }
}

public struct IPCEventEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let kind: IPCEventKind
    public let channel: IPCSubscriptionChannel
    public let ok: Bool
    public let status: IPCResponseStatus
    public let code: IPCErrorCode?
    public let result: IPCResult

    public init(
        version: Int = OmniWMIPCProtocol.version,
        id: String,
        kind: IPCEventKind = .event,
        channel: IPCSubscriptionChannel,
        ok: Bool = true,
        status: IPCResponseStatus = .success,
        code: IPCErrorCode? = nil,
        result: IPCResult
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.channel = channel
        self.ok = ok
        self.status = status
        self.code = code
        self.result = result
    }

    public static func success(
        id: String,
        channel: IPCSubscriptionChannel,
        status: IPCResponseStatus = .success,
        result: IPCResult
    ) -> IPCEventEnvelope {
        IPCEventEnvelope(
            id: id,
            channel: channel,
            ok: true,
            status: status,
            result: result
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case kind
        case channel
        case ok
        case status
        case code
        case result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(IPCEventKind.self, forKey: .kind)
        channel = try container.decode(IPCSubscriptionChannel.self, forKey: .channel)
        ok = try container.decode(Bool.self, forKey: .ok)
        status = try container.decode(IPCResponseStatus.self, forKey: .status)
        code = try container.decodeIfPresent(IPCErrorCode.self, forKey: .code)
        result = try container.decode(IPCResult.self, forKey: .result)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(channel, forKey: .channel)
        try container.encode(ok, forKey: .ok)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encode(result, forKey: .result)
    }
}
