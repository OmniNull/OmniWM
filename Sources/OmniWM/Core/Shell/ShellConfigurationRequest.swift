// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellConfigurationRequest: Sendable {
    let id: ShellServiceID
    let operation: ShellIslandLayout.Operation

    init(id: ShellServiceID, bytes: [UInt8]) throws {
        guard let fields = try ShellServiceValue.decode(bytes, byteLimit: 65536).fields,
              let op = fields["op"]?.string else { throw ShellServiceValue.Failure() }
        self.id = id
        func string(_ key: String) throws -> String {
            guard let value = fields[key]?.string else { throw ShellServiceValue.Failure() }
            return value
        }
        switch op {
        case "add":
            guard let values = fields["options"]?.fields else { throw ShellServiceValue.Failure() }
            var options: [String: ShellComponentValue] = [:]
            for (key, value) in values {
                guard let value = value.componentValue else { throw ShellServiceValue.Failure() }
                options[key] = value
            }
            operation = try .add(widget: string("widget"), options: options)
        case "remove": operation = try .remove(id: string("id"))
        case "move":
            guard let value = fields["index"]?.number, value >= 1, value <= 64,
                  value.rounded(.towardZero) == value
            else {
                throw ShellServiceValue.Failure()
            }
            operation = try .move(id: string("id"), index: Int(value))
        case "enable":
            guard let value = fields["enabled"]?.boolean else { throw ShellServiceValue.Failure() }
            operation = try .enable(id: string("id"), value: value)
        case "set":
            guard let value = fields["value"]?.componentValue else { throw ShellServiceValue.Failure() }
            operation = try .set(id: string("id"), key: string("key"), value: value)
        case "rootSetting":
            guard let value = fields["value"]?.componentValue else { throw ShellServiceValue.Failure() }
            operation = try .rootSetting(key: string("key"), value: value)
        default: throw ShellServiceValue.Failure()
        }
    }

    static func completion(
        id: ShellServiceID,
        instance: String? = nil,
        revision: UInt64 = 0,
        error: String? = nil
    ) -> ShellServiceCompletion {
        var writer = ShellValueWriter()
        writer.map(2 + (instance == nil ? 0 : 1) + (error == nil ? 0 : 1))
        writer.key("ok")
        writer.bool(error == nil)
        writer.key("revision")
        writer.number(Double(revision))
        if let instance {
            writer.key("id")
            writer.string(instance)
        }
        if let error {
            writer.key("error")
            writer.string(error)
        }
        return ShellServiceCompletion(id: id, revision: revision, payload: writer.bytes)
    }
}
