// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public struct IPCRequestEnvelope: Decodable, Sendable {
    public let version: Int
    public let id: String?
    public let kind: String?
    public let authorizationToken: String?
}

public struct IPCRequest: Codable, Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case none(IPCNoPayload)
        case command(IPCCommandRequest)
        case capture(IPCCaptureRequest)
        case query(IPCQueryRequest)
        case rule(IPCRuleRequest)
        case workspace(IPCWorkspaceRequest)
        case window(IPCWindowRequest)
        case windowMark(IPCWindowMarkRequest)
        case subscribe(IPCSubscribeRequest)
    }

    public let version: Int
    public let id: String
    public let kind: IPCRequestKind
    public let authorizationToken: String?
    public let payload: Payload

    public init(
        version: Int = OmniWMIPCProtocol.version,
        id: String,
        kind: IPCRequestKind,
        authorizationToken: String? = nil,
        payload: Payload
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.authorizationToken = authorizationToken
        self.payload = payload
    }

    public init(id: String, command: IPCCommandRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .command, authorizationToken: authorizationToken, payload: .command(command))
    }

    public init(id: String, capture: IPCCaptureRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .capture, authorizationToken: authorizationToken, payload: .capture(capture))
    }

    public init(id: String, query: IPCQueryRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .query, authorizationToken: authorizationToken, payload: .query(query))
    }

    public init(id: String, rule: IPCRuleRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .rule, authorizationToken: authorizationToken, payload: .rule(rule))
    }

    public init(id: String, workspace: IPCWorkspaceRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .workspace, authorizationToken: authorizationToken, payload: .workspace(workspace))
    }

    public init(id: String, window: IPCWindowRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .window, authorizationToken: authorizationToken, payload: .window(window))
    }

    public init(id: String, windowMark: IPCWindowMarkRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .windowMark, authorizationToken: authorizationToken, payload: .windowMark(windowMark))
    }

    public init(id: String, subscribe: IPCSubscribeRequest, authorizationToken: String? = nil) {
        self.init(id: id, kind: .subscribe, authorizationToken: authorizationToken, payload: .subscribe(subscribe))
    }

    public init(id: String, kind: IPCRequestKind, authorizationToken: String? = nil) {
        self.init(id: id, kind: kind, authorizationToken: authorizationToken, payload: .none(.init()))
    }

    public func authorizing(with token: String?) -> IPCRequest {
        IPCRequest(
            version: version,
            id: id,
            kind: kind,
            authorizationToken: token,
            payload: payload
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case kind
        case authorizationToken
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(IPCRequestKind.self, forKey: .kind)
        authorizationToken = try container.decodeIfPresent(String.self, forKey: .authorizationToken)

        switch kind {
        case .ping,
             .version:
            payload = .none(try container.decodeIfPresent(IPCNoPayload.self, forKey: .payload) ?? .init())
        case .command:
            payload = .command(try container.decode(IPCCommandRequest.self, forKey: .payload))
        case .capture:
            payload = .capture(try container.decode(IPCCaptureRequest.self, forKey: .payload))
        case .query:
            payload = .query(try container.decode(IPCQueryRequest.self, forKey: .payload))
        case .rule:
            payload = .rule(try container.decode(IPCRuleRequest.self, forKey: .payload))
        case .workspace:
            payload = .workspace(try container.decode(IPCWorkspaceRequest.self, forKey: .payload))
        case .window:
            payload = .window(try container.decode(IPCWindowRequest.self, forKey: .payload))
        case .windowMark:
            payload = .windowMark(try container.decode(IPCWindowMarkRequest.self, forKey: .payload))
        case .subscribe:
            payload = .subscribe(try container.decode(IPCSubscribeRequest.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(authorizationToken, forKey: .authorizationToken)

        switch payload {
        case let .none(payload):
            try container.encode(payload, forKey: .payload)
        case let .command(payload):
            try container.encode(payload, forKey: .payload)
        case let .capture(payload):
            try container.encode(payload, forKey: .payload)
        case let .query(payload):
            try container.encode(payload, forKey: .payload)
        case let .rule(payload):
            try container.encode(payload, forKey: .payload)
        case let .workspace(payload):
            try container.encode(payload, forKey: .payload)
        case let .window(payload):
            try container.encode(payload, forKey: .payload)
        case let .windowMark(payload):
            try container.encode(payload, forKey: .payload)
        case let .subscribe(payload):
            try container.encode(payload, forKey: .payload)
        }
    }
}
