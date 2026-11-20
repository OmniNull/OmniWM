// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
    mutating func value(_ value: borrowing IPCSubscribeRequest) throws {
        begin(123)
        var first = true
        self.key("allChannels", &first)
        try self.value(value.allChannels)
        self.key("channels", &first)
        try self.value(value.channels)
        self.key("sendInitial", &first)
        try self.value(value.sendInitial)
        end(125)
    }

    mutating func value(_ value: borrowing IPCRequest.Payload) throws {
        switch value {
        case let .none(payload):
            try self.value(payload)
        case let .command(payload):
            try self.value(payload)
        case let .capture(payload):
            try self.value(payload)
        case let .query(payload):
            try self.value(payload)
        case let .rule(payload):
            try self.value(payload)
        case let .workspace(payload):
            try self.value(payload)
        case let .window(payload):
            try self.value(payload)
        case let .windowMark(payload):
            try self.value(payload)
        case let .windowGather(payload):
            try self.value(payload)
        case let .shell(payload):
            try self.value(payload)
        case let .subscribe(payload):
            try self.value(payload)
        }
    }

    mutating func value(_ value: borrowing IPCRequest) throws {
        begin(123)
        var first = true
        if let fieldValue = value.authorizationToken {
            self.key("authorizationToken", &first)
            try self.value(fieldValue)
        }
        self.key("id", &first)
        try self.value(value.id)
        self.key("kind", &first)
        try self.value(value.kind)
        self.key("payload", &first)
        try self.value(value.payload)
        self.key("version", &first)
        try self.value(value.version)
        end(125)
    }
}
