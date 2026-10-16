// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellResourceStore {
    func httpBody(
        _ resource: ShellResourceID,
        owner: ShellServiceOwner,
        operation: ShellResourceOperation
    ) throws -> [UInt8] {
        guard operation.isActive else { throw ShellHTTPFailure("cancelled") }
        let pin = try retain([resource], owner: owner)
        defer { release(pin) }
        guard let value = pin.values.first else { throw ShellHTTPFailure("resource_unavailable") }
        return try resourceBytes(value, limit: ShellHTTPService.byteLimit, operation: operation)
    }

    func resourceBytes(_ value: Value, limit: Int, operation: ShellResourceOperation) throws -> [UInt8] {
        let bytes: [UInt8]
        switch value {
        case let .file(url):
            guard try fileSize(url) <= UInt64(limit) else { throw ShellHTTPFailure("body_too_large") }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var data: [UInt8] = []
            while true {
                guard operation.isActive else { throw ShellHTTPFailure("cancelled") }
                let chunk = try file.read(upToCount: min(64 << 10, limit - data.count + 1)) ?? Data()
                guard chunk.count <= limit - data.count else { throw ShellHTTPFailure("body_too_large") }
                if chunk.isEmpty { break }
                data.append(contentsOf: chunk)
            }
            bytes = data
        case let .text(text):
            guard text.utf8.count <= limit else { throw ShellHTTPFailure("body_too_large") }
            bytes = Array(text.utf8)
        case let .url(url):
            guard url.absoluteString.utf8.count <= limit else { throw ShellHTTPFailure("body_too_large") }
            bytes = Array(url.absoluteString.utf8)
        }
        guard operation.isActive else { throw ShellHTTPFailure("cancelled") }
        return bytes
    }
}
