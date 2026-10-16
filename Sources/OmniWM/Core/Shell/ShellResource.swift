// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellResourceID: Hashable, Codable, Sendable {
    let value: UUID

    init(_ value: UUID = UUID()) {
        self.value = value
    }

    var string: String {
        value.uuidString
    }
}

struct ShellResourceToken: Hashable, Codable, Sendable {
    let value: UUID

    init(_ value: UUID = UUID()) {
        self.value = value
    }

    var string: String {
        value.uuidString
    }
}

struct ShellResourceDescriptor: Equatable, Sendable {
    let id: ShellResourceID
    let name: String
    let kind: String
    let uti: String
}

struct ShellResourceMetadata: Equatable, Sendable {
    enum State: String, Sendable { case pending, ready, failed }
    enum Persistence: Equatable, Sendable {
        case pending(ShellResourceToken)
        case durable(ShellResourceToken)
        case failed(ShellResourceToken, String)
    }

    let descriptor: ShellResourceDescriptor
    var state: State = .pending
    var size: UInt64?
    var error: String?
    var revision: UInt64 = 0
    var persistence: Persistence?
}

struct ShellResourceFailure: Error, Equatable, CustomStringConvertible, Sendable {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

struct ShellResourceLeaseKey: Hashable, Sendable {
    let id: ShellServiceID
    let incarnation: UInt64
}

struct ShellResourcePersistenceRequest: Sendable {
    let id: ShellServiceID
    let resource: ShellResourceID
    let token: ShellResourceToken
    let namespace: ShellStoreNamespace
}

struct ShellResourcePersistenceResult: Sendable {
    let id: ShellServiceID
    let token: ShellResourceToken
    let error: String?
}

struct ShellResourceFile: Equatable, Sendable {
    let name: String
    let url: URL
}

struct ShellResourceOutput: Equatable, Sendable {
    let name: String
    let path: String
}
