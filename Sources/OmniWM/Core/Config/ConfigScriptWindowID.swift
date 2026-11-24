// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct ConfigScriptSession: Equatable, Sendable {
    let id: UInt128

    static func random() -> Self {
        Self(id: .random(in: .min ... .max))
    }
}

enum ConfigScriptWindowID {
    static let sessionDigits = UInt128.bitWidth / 4
    static let separator = UInt8(ascii: ".")
    static let maximumLength = sessionDigits + 1 + UInt32.max.description.utf8.count + 1
        + UInt.max.description.utf8.count

    static func withBytes<Result>(
        _ token: WindowToken,
        session: ConfigScriptSession,
        _ body: (UnsafeRawBufferPointer) -> Result
    ) -> Result {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: maximumLength) { buffer in
            var count = 0
            var shift = UInt128.bitWidth
            repeat {
                shift -= 4
                buffer[count] = hexDigit(UInt8(truncatingIfNeeded: session.id >> shift) & 0xF)
                count += 1
            } while shift > 0
            buffer[count] = separator
            count += 1
            count = appendDecimal(UInt(UInt32(bitPattern: token.pid)), to: buffer, at: count)
            buffer[count] = separator
            count += 1
            count = appendDecimal(UInt(bitPattern: token.windowId), to: buffer, at: count)
            return body(UnsafeRawBufferPointer(rebasing: UnsafeMutableRawBufferPointer(buffer)[..<count]))
        }
    }

    static func string(_ token: WindowToken, session: ConfigScriptSession) -> String {
        withBytes(token, session: session) { String(decoding: $0, as: UTF8.self) }
    }

    static func decode(_ bytes: UnsafeRawBufferPointer) -> (session: ConfigScriptSession, token: WindowToken)? {
        guard bytes.count > sessionDigits + 1, bytes.count <= maximumLength else { return nil }
        var session: UInt128 = 0
        for index in 0 ..< sessionDigits {
            guard let value = hexValue(bytes[index]) else { return nil }
            session = session << 4 | UInt128(value)
        }
        var cursor = sessionDigits
        guard bytes[cursor] == separator else { return nil }
        cursor += 1
        guard let pid = decimal(bytes, from: &cursor, limit: UInt(UInt32.max)),
              cursor < bytes.count, bytes[cursor] == separator
        else { return nil }
        cursor += 1
        guard let window = decimal(bytes, from: &cursor, limit: .max), cursor == bytes.count else { return nil }
        return (
            ConfigScriptSession(id: session),
            WindowToken(pid: Int32(bitPattern: UInt32(pid)), windowId: Int(bitPattern: window))
        )
    }

    static func decode(_ text: String) -> (session: ConfigScriptSession, token: WindowToken)? {
        var text = text
        return text.withUTF8 { decode(UnsafeRawBufferPointer($0)) }
    }

    private static func hexDigit(_ value: UInt8) -> UInt8 {
        value < 10 ? UInt8(ascii: "0") + value : UInt8(ascii: "a") + value - 10
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    private static func appendDecimal(
        _ value: UInt,
        to buffer: UnsafeMutableBufferPointer<UInt8>,
        at start: Int
    ) -> Int {
        var digits = 1
        var scale: UInt = 1
        while value / scale >= 10 {
            scale *= 10
            digits += 1
        }
        var remaining = value
        for offset in 0 ..< digits {
            buffer[start + offset] = UInt8(ascii: "0") + UInt8(remaining / scale)
            remaining %= scale
            scale /= 10
        }
        return start + digits
    }

    private static func decimal(_ bytes: UnsafeRawBufferPointer, from cursor: inout Int, limit: UInt) -> UInt? {
        let start = cursor
        var value: UInt = 0
        while cursor < bytes.count, bytes[cursor] >= UInt8(ascii: "0"), bytes[cursor] <= UInt8(ascii: "9") {
            let (scaled, overflow) = value.multipliedReportingOverflow(by: 10)
            let (sum, carry) = scaled.addingReportingOverflow(UInt(bytes[cursor] - UInt8(ascii: "0")))
            guard !overflow, !carry, sum <= limit else { return nil }
            value = sum
            cursor += 1
        }
        guard cursor > start, bytes[start] != UInt8(ascii: "0") || cursor - start == 1 else { return nil }
        return value
    }
}

extension Monitor.ID {
    var scriptIdentifier: String {
        String(displayId)
    }
}
