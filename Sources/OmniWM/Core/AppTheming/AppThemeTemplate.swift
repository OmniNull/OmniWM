// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum AppThemeTemplateError: Error, Equatable, LocalizedError {
    case unknownPlaceholder(String, line: Int)
    case unterminatedPlaceholder(line: Int)
    case tooLarge(bytes: Int)

    var errorDescription: String? {
        switch self {
        case let .unknownPlaceholder(name, line):
            String(localized: "Line \(line): unknown placeholder {{\(name)}}")
        case let .unterminatedPlaceholder(line):
            String(localized: "Line \(line): a placeholder opened with {{ is not closed with }} on the same line")
        case let .tooLarge(bytes):
            String(localized: "The template is \(bytes) bytes; templates are limited to 1 MB")
        }
    }
}

enum AppThemeTemplate {
    static let maximumBytes = 1_048_576
    static let formats = ["hex", "hex_stripped", "rgb", "rgba", "red", "green", "blue", "alpha"]
    static let variants = ["default", "light", "dark"]

    static var colorNames: [String] {
        ShellRole.allCases.map { "\($0)" } + (0 ..< 16).map { "ansi\($0)" }
            + AppThemeBase16.slots
    }

    static func render(_ template: String, palette: AppThemePalette, dark: Bool) throws -> String {
        let bytes = template.utf8.count
        guard bytes <= maximumBytes else { throw AppThemeTemplateError.tooLarge(bytes: bytes) }
        var output = ""
        output.reserveCapacity(bytes)
        var rest = Substring(template)
        var line = 1
        while let open = rest.range(of: "{{") {
            let escaped = open.lowerBound > rest.startIndex && rest[rest.index(before: open.lowerBound)] == "\\"
            let literal = rest[rest.startIndex ..< (escaped ? rest.index(before: open.lowerBound) : open.lowerBound)]
            output += literal
            line += literal.count { $0 == "\n" }
            rest = rest[open.upperBound...]
            if escaped {
                output += "{{"
                continue
            }
            let lineEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
            guard let close = rest[..<lineEnd].range(of: "}}") else {
                throw AppThemeTemplateError.unterminatedPlaceholder(line: line)
            }
            let name = rest[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let value = value(of: name, palette: palette, dark: dark) else {
                throw AppThemeTemplateError.unknownPlaceholder(name, line: line)
            }
            output += value
            rest = rest[close.upperBound...]
        }
        output += rest
        return output
    }

    static func value(of name: String, palette: AppThemePalette, dark: Bool) -> String? {
        if name == "mode" { return dark ? "dark" : "light" }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "colors" else { return nil }
        let isDark: Bool
        switch parts[2] {
        case "default": isDark = dark
        case "light": isDark = false
        case "dark": isDark = true
        default: return nil
        }
        guard let color = color(named: String(parts[1]), in: palette.scheme(dark: isDark)) else { return nil }
        return format(color, as: String(parts[3]))
    }

    private static func color(named name: String, in scheme: AppThemePalette.Scheme) -> AppThemeColor? {
        if name.hasPrefix("ansi"), let index = Int(name.dropFirst(4)), String(index) == name.dropFirst(4),
           scheme.ansi.indices.contains(index)
        {
            return scheme.ansi[index]
        }
        if let color = scheme.base16[name] {
            return color
        }
        return ShellRole(name: name).flatMap { scheme.roles[$0] }
    }

    private static func format(_ color: AppThemeColor, as format: String) -> String? {
        switch format {
        case "hex": color.hex
        case "hex_stripped": color.hexStripped
        case "rgb": "rgb(\(color.red), \(color.green), \(color.blue))"
        case "rgba": "rgba(\(color.red), \(color.green), \(color.blue), \(color.alphaText))"
        case "red": String(color.red)
        case "green": String(color.green)
        case "blue": String(color.blue)
        case "alpha": color.alphaText
        default: nil
        }
    }
}
