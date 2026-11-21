// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct AppThemeDiffLine: Equatable, Identifiable {
    enum Kind: Equatable {
        case context
        case removed
        case added
        case gap
    }

    let id: Int
    let kind: Kind
    let text: String
}

struct AppThemeChange: Equatable, Identifiable, Sendable {
    let url: URL
    let display: String
    let before: String?
    let after: String
    var beforeDigest: String?
    var note: String?

    var id: String {
        url.path
    }

    var diff: [AppThemeDiffLine] {
        AppThemeDiff.lines(before: before ?? "", after: after)
    }
}

enum AppThemeDiff {
    static let context = 2

    static func lines(before: String, after: String) -> [AppThemeDiffLine] {
        let old = split(before)
        let new = split(after)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
        {
            suffix += 1
        }
        var kinds: [(AppThemeDiffLine.Kind, String)] = []
        let leading = max(0, prefix - context)
        if leading > 0 { kinds.append((.gap, "")) }
        kinds += old[leading ..< prefix].map { (.context, $0) }
        kinds += old[prefix ..< old.count - suffix].map { (.removed, $0) }
        kinds += new[prefix ..< new.count - suffix].map { (.added, $0) }
        let trailingEnd = min(old.count, old.count - suffix + context)
        kinds += old[(old.count - suffix) ..< trailingEnd].map { (.context, $0) }
        if trailingEnd < old.count { kinds.append((.gap, "")) }
        return kinds.enumerated().map { AppThemeDiffLine(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }

    private static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

enum AppThemeGhosttyStatus: Equatable {
    case selected
    case notSelected
    case overridden(String)
    case unreadable(String)
}

enum AppThemeGhosttySelection {
    struct LoadedFile {
        let url: URL
        let contents: Result<(data: Data, text: String), any Error>
    }

    struct Plan: Equatable {
        let url: URL
        let before: String?
        let after: String
    }

    static let marker = "# Added by OmniWM app theming: follow OmniWM’s palette in light and dark"
    private static let includeDepth = 10

    static func candidates(configHome: URL, home: URL) -> [URL] {
        let support = home.appendingPathComponent(
            "Library/Application Support/com.mitchellh.ghostty",
            isDirectory: true
        )
        let xdg = configHome.appendingPathComponent("ghostty", isDirectory: true)
        return [
            xdg.appendingPathComponent("config.ghostty"),
            xdg.appendingPathComponent("config"),
            support.appendingPathComponent("config.ghostty"),
            support.appendingPathComponent("config")
        ]
    }

    static func loadedFiles(
        configHome: URL,
        home: URL,
        display: (URL) -> String = { $0.path }
    ) -> [LoadedFile] {
        var files: [LoadedFile] = []
        func visit(_ url: URL, depth: Int) {
            guard depth < includeDepth, !files.contains(where: { $0.url == url }) else { return }
            do {
                let name = display(url)
                guard let data = try AppThemeFileWriter.read(url, display: name) else { return }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw AppThemeEngineError.notText(name)
                }
                files.append(LoadedFile(url: url, contents: .success((data, text))))
                for include in includes(in: text, of: url, home: home) {
                    visit(include, depth: depth + 1)
                }
            } catch {
                files.append(LoadedFile(url: url, contents: .failure(error)))
            }
        }
        for candidate in candidates(configHome: configHome, home: home) {
            visit(candidate, depth: 0)
        }
        return files
    }

    static func includes(in text: String, of file: URL, home: URL) -> [URL] {
        text.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("config-file") else { return nil }
            let rest = trimmed.dropFirst("config-file".count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { return nil }
            var value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""),
               value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if value.hasPrefix("?") { value.removeFirst() }
            guard !value.isEmpty else { return nil }
            if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
            if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
            return file.deletingLastPathComponent().appendingPathComponent(value)
        }
    }

    static func isThemeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("theme") else { return false }
        return trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    static func selectsOmniWM(_ line: String) -> Bool {
        guard isThemeLine(line), let equals = line.firstIndex(of: "=") else { return false }
        let entries = line[line.index(after: equals)...].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return Set(entries) == ["light:omniwm-light", "dark:omniwm-dark"]
    }

    static func status(_ files: [(url: URL, text: String)]) -> AppThemeGhosttyStatus {
        let themes = files.flatMap { file in
            file.text.components(separatedBy: "\n").filter(isThemeLine).map { (file.url, $0) }
        }
        guard let last = themes.last else { return .notSelected }
        if selectsOmniWM(last.1) { return .selected }
        return themes.contains { selectsOmniWM($0.1) } ? .overridden(last.0.path) : .notSelected
    }

    static func plan(_ files: [(url: URL, text: String)], fallback: URL) -> [Plan] {
        guard status(files) != .selected else { return [] }
        let hasSelection = files.contains { $0.text.components(separatedBy: "\n").contains(where: selectsOmniWM) }
        let target = files.last { $0.text.components(separatedBy: "\n").contains(where: isThemeLine) }?.url
            ?? files.first?.url ?? fallback
        var seen = Set<URL>()
        let unique = files.filter { seen.insert($0.url).inserted }
        var plans = unique.compactMap { file -> Plan? in
            let after = edited(file.text, adding: !hasSelection && file.url == target)
            return after == file.text ? nil : Plan(url: file.url, before: file.text, after: after)
        }
        if !hasSelection, !files.contains(where: { $0.url == target }) {
            plans.append(Plan(url: target, before: nil, after: edited("", adding: true)))
        }
        return plans
    }

    static func edited(_ text: String, adding: Bool) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        let conflicting = lines.contains { isThemeLine($0) && !selectsOmniWM($0) }
        guard adding || conflicting else { return text }
        lines = lines.map { isThemeLine($0) && !selectsOmniWM($0) ? "# " + $0 : $0 }
        if adding {
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            lines += [marker, AppThemeBuiltIn.ghosttyThemeLine]
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
