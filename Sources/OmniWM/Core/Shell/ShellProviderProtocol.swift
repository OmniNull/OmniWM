// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellProviderIdentity: Hashable, Sendable {
    let owner: ShellServiceOwner
    let incarnation: UInt64
}

enum ShellProviderProtocol {
    static let lineLimit = 65_536

    struct Failure: Error, Equatable, LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    enum Message: Equatable, Sendable {
        case state(topic: String, value: Data)
        case event(name: String, value: Data)
        case result(id: String, ok: Bool, value: Data, attachments: Data?)
    }

    static func validToken(_ token: String) -> Bool {
        let bytes = token.utf8
        guard (1 ... 64).contains(bytes.count), let first = bytes.first, letter(first) else { return false }
        return bytes.allSatisfy { letter($0) || (48 ... 57).contains($0) || $0 == 95 || $0 == 46 || $0 == 45 }
    }

    static func request(_ token: String) -> UInt64? {
        guard token.first == "r", token.count > 1 else { return nil }
        let digits = token.dropFirst()
        guard digits.utf8.allSatisfy({ (48 ... 57).contains($0) }) else { return nil }
        guard digits.count == 1 || digits.first != "0" else { return nil }
        return UInt64(digits)
    }

    static func action(id: UInt64, name: String, arguments: Data) throws -> Data {
        guard validToken(name) else { throw Failure(message: "Invalid provider action name") }
        var result = Data("[\"action\",\"r\(id)\",\"\(name)\",".utf8)
        guard result.count + arguments.count + 2 <= lineLimit else {
            throw Failure(message: "Provider action exceeds 65536 bytes")
        }
        result.append(arguments)
        result.append(contentsOf: [93, 10])
        return result
    }

    static func classify(_ bytes: [UInt8]) throws -> Message {
        var start = 0
        var end = bytes.count
        while start < end, whitespace(bytes[start]) { start += 1 }
        while end > start, whitespace(bytes[end - 1]) { end -= 1 }
        guard start < end, bytes[start] == 91, bytes[end - 1] == 93 else {
            throw Failure(message: "Provider line must be a JSON array")
        }
        let fields = try fields(bytes, from: start + 1, to: end - 1)
        guard fields.count >= 2 else { throw Failure(message: "Provider line has missing fields") }
        let kind = try token(bytes, range: fields[0])
        let name = try token(bytes, range: fields[1])
        switch kind {
        case "state":
            guard fields.count == 3 else { throw Failure(message: "State requires topic and value") }
            return .state(topic: name, value: Data(bytes[fields[2]]))
        case "event":
            guard fields.count == 2 || fields.count == 3 else {
                throw Failure(message: "Event requires name and optional value")
            }
            return .event(name: name, value: fields.count == 3 ? Data(bytes[fields[2]]) : Data("null".utf8))
        case "result":
            guard (3 ... 5).contains(fields.count) else {
                throw Failure(message: "Result requires id, success, optional value and metadata")
            }
            let success = bytes[fields[2]]
            let ok: Bool
            if success.elementsEqual([116, 114, 117, 101]) { ok = true }
            else if success.elementsEqual([102, 97, 108, 115, 101]) { ok = false }
            else { throw Failure(message: "Result success must be true or false") }
            guard ok || fields.count == 4 else {
                throw Failure(message: "Failed result requires a message and no metadata")
            }
            return .result(
                id: name, ok: ok,
                value: fields.count >= 4 ? Data(bytes[fields[3]]) : Data("null".utf8),
                attachments: fields.count == 5 ? Data(bytes[fields[4]]) : nil
            )
        default:
            throw Failure(message: "Unknown provider message kind")
        }
    }

    private static func fields(_ bytes: [UInt8], from start: Int, to end: Int) throws -> [Range<Int>] {
        var result: [Range<Int>] = []
        var fieldStart = start
        var depth = 0
        var string = ShellJSONQuoteState()
        for index in start ..< end {
            let byte = bytes[index]
            if string.consume(byte) { continue }
            if byte == 91 || byte == 123 {
                depth += 1
            } else if byte == 93 || byte == 125 {
                depth -= 1
                guard depth >= 0 else { throw Failure(message: "Unbalanced provider value") }
            } else if byte == 44, depth == 0 {
                guard result.count < 4 else { throw Failure(message: "Too many provider fields") }
                result.append(try trimmed(bytes, range: fieldStart ..< index))
                fieldStart = index + 1
            }
        }
        guard !string.quoted, depth == 0 else { throw Failure(message: "Unterminated provider value") }
        result.append(try trimmed(bytes, range: fieldStart ..< end))
        return result
    }

    private static func trimmed(_ bytes: [UInt8], range: Range<Int>) throws -> Range<Int> {
        var start = range.lowerBound
        var end = range.upperBound
        while start < end, whitespace(bytes[start]) { start += 1 }
        while end > start, whitespace(bytes[end - 1]) { end -= 1 }
        guard start < end else { throw Failure(message: "Empty provider field") }
        return start ..< end
    }

    private static func token(_ bytes: [UInt8], range: Range<Int>) throws -> String {
        guard (3 ... 66).contains(range.count), bytes[range.lowerBound] == 34, bytes[range.upperBound - 1] == 34 else {
            throw Failure(message: "Provider header must be an unescaped ASCII token")
        }
        let content = bytes[(range.lowerBound + 1) ..< (range.upperBound - 1)]
        let value = String(decoding: content, as: UTF8.self)
        guard validToken(value) else { throw Failure(message: "Invalid provider header token") }
        return value
    }

    private static func letter(_ byte: UInt8) -> Bool {
        (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
    }

    private static func whitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 13 || byte == 10
    }
}

struct ShellProviderLineFramer {
    struct Capture: Equatable, Sendable {
        var id: UInt64 = 0
        var completedLines: UInt64 = 0
        var framingFailures: UInt64 = 0

        var detail: String {
            "utility=provider_framer completed_lines=\(completedLines) framing_failures=\(framingFailures)"
        }
    }

    private var partial: [UInt8] = []
    private(set) var failure: ShellProviderProtocol.Failure?
    private var capture = Capture()

    mutating func captureBegin(_ id: UInt64) {
        guard id != 0, capture.id != id else { return }
        capture = Capture(id: id)
    }

    mutating func captureEnd(_ id: UInt64) -> Capture? {
        guard id != 0, capture.id == id else { return nil }
        defer { capture = Capture() }
        return capture
    }

    mutating func reset() {
        partial.removeAll(keepingCapacity: false)
        failure = nil
    }

    var bufferedBytes: Int {
        partial.count
    }

    mutating func consume(
        _ bytes: UnsafeRawBufferPointer,
        receive: (ShellProviderProtocol.Message) throws -> Void
    ) throws {
        if let failure { throw failure }
        do {
            for byte in bytes {
                if byte == 10 {
                    if capture.id != 0 { capture.completedLines &+= 1 }
                    let message: ShellProviderProtocol.Message
                    do { message = try ShellProviderProtocol.classify(partial) }
                    catch {
                        if capture.id != 0 { capture.framingFailures &+= 1 }
                        throw error
                    }
                    partial.removeAll(keepingCapacity: true)
                    try receive(message)
                } else {
                    guard partial.count < ShellProviderProtocol.lineLimit - 1 else {
                        if capture.id != 0 { capture.framingFailures &+= 1 }
                        throw ShellProviderProtocol.Failure(message: "Provider line exceeds 65536 bytes")
                    }
                    partial.append(byte)
                }
            }
        } catch let error as ShellProviderProtocol.Failure {
            failure = error
            partial.removeAll(keepingCapacity: false)
            throw error
        }
    }

    mutating func finish() throws {
        if let failure { throw failure }
        guard partial.isEmpty else {
            if capture.id != 0 { capture.framingFailures &+= 1 }
            let error = ShellProviderProtocol.Failure(message: "Provider ended with an incomplete line")
            failure = error
            partial.removeAll(keepingCapacity: false)
            throw error
        }
    }
}
