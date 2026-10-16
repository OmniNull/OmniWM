// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreFoundation
import Foundation

enum ShellHTTPResponse {
    static let envelopeLimit = (4 << 20) + (64 << 10) + 2048
    static let errorLimit = 1024

    static func headersFit(_ headers: [String: String]) -> Bool {
        var remaining = ShellHTTPService.headerLimit - 5
        for (key, value) in headers {
            let count = 9 + key.utf8.count + value.utf8.count
            guard count <= remaining else { return false }
            remaining -= count
        }
        return true
    }

    static func boundedError(_ error: String) -> String {
        var bytes = Array(error.utf8.prefix(errorLimit))
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }

    static func failure(_ error: String) -> [UInt8] {
        encode(status: 0, headers: [:], body: Data(), response: .text, error: error)
    }

    static func encode(
        status: Int, headers: [String: String], body: Data, response: ShellHTTPRequest.Response,
        error: String?, decodeJSON: @Sendable (Data) throws -> [UInt8] = json
    ) -> [UInt8] {
        var failure = error.map(boundedError)
        let validHeaders = headersFit(headers)
        let headers = validHeaders ? headers : [:]
        if !validHeaders { failure = "response_headers_too_large" }
        var value: [UInt8]?
        var field: String?
        if failure == nil {
            do {
                guard body.count <= ShellHTTPService.byteLimit else { throw ShellHTTPFailure("response_too_large") }
                var writer = ShellValueWriter()
                switch response {
                case .bytes:
                    writer.string(bytes: body)
                    value = writer.bytes
                    field = "bytes"
                case .text:
                    guard let text = String(data: body, encoding: .utf8) else { throw ShellHTTPFailure("invalid_utf8") }
                    writer.string(text)
                    value = writer.bytes
                    field = "text"
                case .json:
                    let decoded = try decodeJSON(body)
                    guard decoded.count <= ShellHTTPService.byteLimit
                    else { throw ShellHTTPFailure("decoded_response_too_large") }
                    value = decoded
                    field = "json"
                }
                if !(200 ..< 300).contains(status) { failure = "http_status" }
            } catch {
                failure = (error as? ShellHTTPFailure)?.code ?? "invalid_json"
            }
        }
        var writer = ShellValueWriter()
        writer.map(3 + (failure == nil ? 0 : 1) + (value == nil ? 0 : 1))
        writer.key("ok")
        writer.bool(failure == nil && (200 ..< 300).contains(status))
        writer.key("status")
        writer.number(Double(status))
        writer.key("headers")
        writer.map(headers.count)
        for (key, value) in headers { writer.key(key)
            writer.string(value)
        }
        if let failure { writer.key("error")
            writer.string(boundedError(failure))
        }
        if let field, let value { writer.key(field)
            writer.encoded(value)
        }
        return writer.bytes
    }

    static func json(_ data: Data) throws -> [UInt8] {
        guard data.count <= ShellHTTPService.byteLimit else { throw ShellHTTPFailure("response_too_large") }
        guard String(data: data, encoding: .utf8) != nil else { throw ShellHTTPFailure("invalid_json") }
        var depth = 0
        var string = ShellJSONQuoteState()
        for byte in data {
            if string.consume(byte) { continue }
            if byte == 91 || byte == 123 {
                depth += 1
                guard depth <= 64 else { throw ShellHTTPFailure("invalid_json") }
            } else if byte == 93 || byte == 125 { depth -= 1 }
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw ShellHTTPFailure("invalid_json") }
        var encoder = JSONWire()
        try encoder.append(object, depth: 0)
        return encoder.writer.bytes
    }

    private struct JSONWire {
        var writer = ShellValueWriter()

        mutating func reserve(_ count: Int) throws {
            guard count <= ShellHTTPService.byteLimit - writer.bytes.count else {
                throw ShellHTTPFailure("decoded_response_too_large")
            }
        }

        mutating func append(_ object: Any, depth: Int) throws {
            guard depth <= 64 else { throw ShellHTTPFailure("invalid_json") }
            switch object {
            case is NSNull:
                try reserve(1)
                writer.null()
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    try reserve(1)
                    writer.bool(number.boolValue)
                } else {
                    let value = number.doubleValue
                    guard value.isFinite else { throw ShellHTTPFailure("invalid_json") }
                    try reserve(9)
                    writer.number(value)
                }
            case let string as String:
                try reserve(5 + string.utf8.count)
                writer.string(string)
            case let array as [Any]:
                try reserve(5)
                writer.array(array.count)
                for element in array { try append(element, depth: depth + 1) }
            case let map as [String: Any]:
                try reserve(5)
                writer.map(map.count)
                for (key, value) in map {
                    try reserve(4 + key.utf8.count)
                    writer.key(key)
                    try append(value, depth: depth + 1)
                }
            default:
                throw ShellHTTPFailure("invalid_json")
            }
        }
    }
}

struct ShellJSONQuoteState {
    private(set) var quoted = false
    private var escaped = false

    mutating func consume(_ byte: UInt8) -> Bool {
        guard quoted else {
            guard byte == 34 else { return false }
            quoted = true
            return true
        }
        if escaped { escaped = false }
        else if byte == 92 { escaped = true }
        else if byte == 34 { quoted = false }
        return true
    }
}
