// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

final class ShellStrings: Equatable, Sendable {
    static let empty = ShellStrings([:])
    static let folder = "strings"
    static let fallbackLocalization = "en"
    static let appLocalization = Bundle.module.preferredLocalizations.first ?? fallbackLocalization

    let table: [String: String]

    init(_ table: [String: String]) {
        self.table = table
    }

    subscript(key: String) -> String? {
        table[key]
    }

    func title(_ key: String, locale: Locale = .current) -> String {
        table[key] ?? String(localized: LocalizedStringResource(
            String.LocalizationValue(key), table: ShellLocalizer.table, locale: locale,
            bundle: .atURL(Bundle.module.bundleURL)
        ))
    }

    static func == (lhs: ShellStrings, rhs: ShellStrings) -> Bool {
        lhs === rhs || lhs.table == rhs.table
    }

    static func localizations(_ localization: String) -> [String] {
        let language = Locale(identifier: localization).language.languageCode?.identifier ?? localization
        var seen: Set<String> = []
        return [localization, language, fallbackLocalization].filter { seen.insert($0).inserted }
    }

    static func files(_ directories: [URL], localization: String = appLocalization) -> [URL] {
        localizations(localization).flatMap { code in
            directories.map { $0.appendingPathComponent("\(folder)/\(code).toml") }
        }
    }

    static func load(_ directories: [URL], localization: String = appLocalization) throws -> ShellStrings {
        var table: [String: String] = [:]
        for file in files(directories, localization: localization) {
            for (key, value) in try entries(file) where table[key] == nil {
                table[key] = value
            }
        }
        return table.isEmpty ? .empty : ShellStrings(table)
    }

    private static func entries(_ file: URL) throws -> [String: String] {
        let name = "\(folder)/\(file.lastPathComponent)"
        guard let nodes = try ShellStyleManifest.table(at: file, name: name) else { return [:] }
        return try nodes.mapValues { node in
            guard case let .string(value) = node else {
                throw ShellScriptFailure(kind: .compile, message: "\(name): every value must be a string")
            }
            return value
        }
    }
}
