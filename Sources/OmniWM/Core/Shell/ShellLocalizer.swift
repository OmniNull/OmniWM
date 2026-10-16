// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost

enum ShellLocalizer {
    enum Argument: Equatable {
        case number(Double)
        case text(String)
    }

    static let table = "Shell"

    static let callback: omni_localizer = { _, key, keyLength, arguments, count, out, capacity in
        guard let key, let out else { return 0 }
        let name = String(decoding: UnsafeRawBufferPointer(start: key, count: keyLength), as: UTF8.self)
        let values = (0 ..< count).map { index -> Argument in
            let argument = arguments![index]
            guard argument.kind == 1 else { return .number(argument.number) }
            return .text(String(
                decoding: UnsafeRawBufferPointer(start: argument.text, count: argument.length),
                as: UTF8.self
            ))
        }
        return copy(string(name, values), into: out, capacity: capacity)
    }

    static func copy(_ text: String, into out: UnsafeMutablePointer<CChar>, capacity: Int) -> Int {
        let utf8 = Array(text.utf8)
        var length = min(utf8.count, capacity)
        while length > 0, length < utf8.count, utf8[length] & 0xC0 == 0x80 {
            length -= 1
        }
        utf8.withUnsafeBufferPointer { _ = memcpy(out, $0.baseAddress, length) }
        return length
    }

    static func string(_ key: String, _ arguments: [Argument], bundle: Bundle = .module) -> String {
        let missing = "\u{1}"
        let template = bundle.localizedString(forKey: key, value: missing, table: table)
        guard template != missing else { return key }
        return format(template, arguments)
    }

    static func format(_ template: String, _ arguments: [Argument]) -> String {
        var result = ""
        var next = 0
        var scalars = template.unicodeScalars[...]
        while let scalar = scalars.popFirst() {
            guard scalar == "%" else {
                result.unicodeScalars.append(scalar)
                continue
            }
            if scalars.first == "%" {
                scalars.removeFirst()
                result.append("%")
                continue
            }
            var position: Int?
            let digits = scalars.prefix { CharacterSet.decimalDigits.contains($0) }
            if !digits.isEmpty, scalars.dropFirst(digits.count).first == "$" {
                position = Int(String(String.UnicodeScalarView(digits))).map { $0 - 1 }
                scalars.removeFirst(digits.count + 1)
            }
            let modifiers = scalars.prefix { "-+#0 '.123456789hlqLztj".unicodeScalars.contains($0) }
            scalars.removeFirst(modifiers.count)
            guard let conversion = scalars.popFirst() else { break }
            let index = position ?? next
            if position == nil {
                next += 1
            }
            let flags = String(String.UnicodeScalarView(modifiers.filter { !"hlqLztj".unicodeScalars.contains($0) }))
            result += render(conversion, flags: flags, index < arguments.count ? arguments[index] : nil)
        }
        return result
    }

    private static func render(_ conversion: Unicode.Scalar, flags: String, _ argument: Argument?) -> String {
        switch conversion {
        case "@":
            switch argument {
            case let .text(text)?: return text
            case let .number(number)?: return number == number.rounded() && abs(number) < 1e15
                ? String(Int64(number)) : String(number)
            case nil: return ""
            }
        case "d",
             "i":
            return String(format: "%\(flags)lld", locale: .current, integer(argument))
        case "u",
             "x",
             "X",
             "o":
            return String(format: "%\(flags)ll\(conversion)", locale: .current, UInt64(clamping: integer(argument)))
        case "f",
             "F",
             "e",
             "E",
             "g",
             "G",
             "a",
             "A":
            return String(format: "%\(flags)\(conversion)", locale: .current, number(argument))
        default:
            return ""
        }
    }

    private static func number(_ argument: Argument?) -> Double {
        switch argument {
        case let .number(number)?: number
        case let .text(text)?: Double(text) ?? 0
        case nil: 0
        }
    }

    private static func integer(_ argument: Argument?) -> Int64 {
        let value = number(argument).rounded(.towardZero)
        guard value.isFinite else { return 0 }
        return Int64(max(min(value, 9.2e18), -9.2e18))
    }
}
