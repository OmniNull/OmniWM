// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
    mutating func shellRequestProfile(_ name: borrowing String) throws {
        begin(123)
        var first = true
        self.key("key", &first)
        try self.value(name)
        self.key("name", &first)
        try self.value("profile")
        end(125)
    }

    mutating func shellRequestTheme(_ name: borrowing String, _ scheme: borrowing String?) throws {
        begin(123)
        var first = true
        self.key("key", &first)
        try self.value(name)
        self.key("name", &first)
        try self.value("theme")
        switch scheme {
        case let fieldValue?:
            self.key("value", &first)
            try self.value(fieldValue)
        case nil:
            break
        }
        end(125)
    }

    mutating func shellRequestEject(_ widget: borrowing String) throws {
        begin(123)
        var first = true
        self.key("name", &first)
        try self.value("eject")
        self.key("widget", &first)
        try self.value(widget)
        end(125)
    }

    mutating func shellRequestInitialize(_ widget: borrowing String) throws {
        begin(123)
        var first = true
        self.key("name", &first)
        try self.value("init")
        self.key("widget", &first)
        try self.value(widget)
        end(125)
    }

    mutating func shellRequestTrigger(
        _ widget: borrowing String,
        _ name: borrowing String,
        _ text: borrowing String?
    ) throws {
        begin(123)
        var first = true
        self.key("key", &first)
        try self.value(name)
        self.key("name", &first)
        try self.value("trigger")
        switch text {
        case let fieldValue?:
            self.key("value", &first)
            try self.value(fieldValue)
        case nil:
            break
        }
        self.key("widget", &first)
        try self.value(widget)
        end(125)
    }

    mutating func value(_ value: borrowing IPCShellRequest) throws {
        switch value {
        case let .set(key, text):
            try shellRequestSet(key, text)
        case let .unset(key):
            try shellRequestUnset(key)
        case let .toggle(widget):
            try shellRequestToggle(widget)
        case let .profile(name):
            try shellRequestProfile(name)
        case let .theme(name, scheme):
            try shellRequestTheme(name, scheme)
        case let .eject(widget):
            try shellRequestEject(widget)
        case let .initialize(widget):
            try shellRequestInitialize(widget)
        case let .trigger(widget, name, text):
            try shellRequestTrigger(widget, name, text)
        }
    }

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
        switch value.payload {
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
        self.key("version", &first)
        try self.value(value.version)
        end(125)
    }
}
