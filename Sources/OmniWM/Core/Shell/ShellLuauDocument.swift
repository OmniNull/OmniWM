// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellLuauConfirmation: LocalizedError, Sendable {
    let url: URL
    let message: String
    fileprivate let target: URL
    fileprivate let files: SettingsFileVersions
    fileprivate let changes: [([String], SettingsLuauValue?)]
    fileprivate let replacement: Data

    var errorDescription: String? {
        message
    }

    func checkCurrent() throws {
        guard files.isCurrent, try SettingsFileAccess.settingsTarget(for: url) == target else {
            throw SettingsLuauError(message: "The shell files changed. Try the edit again.")
        }
    }
}

struct ShellLuauDocument {
    struct LoadFailure: LocalizedError {
        let files: SettingsFileVersions
        let reason: any Error
        var errorDescription: String? {
            reason.localizedDescription
        }
    }

    @TaskLocal static var approved: ShellLuauConfirmation?
    #if DEBUG
        @TaskLocal static var onEvaluate: (@Sendable (URL) -> Void)?
    #endif
    private let table: LuauTableDocument
    private let entry: URL?
    private let packageRoot: URL?
    var value: SettingsLuauValue {
        table.sourceValue
    }

    var source: Data {
        table.source
    }

    private(set) var files: SettingsFileVersions

    init(_ source: Data, at entry: URL? = nil, packageRoot: URL? = nil) throws {
        let root = try packageRoot.map(SettingsFileAccess.canonicalURL)
        #if DEBUG
            if let entry { Self.onEvaluate?(entry) }
        #endif
        let input = LuauTableDocument.read(
            source,
            at: entry,
            filename: entry?.lastPathComponent ?? "shell.luau",
            packageRoot: root,
            shellNumbers: true
        )
        do { table = try LuauTableDocument(input) }
        catch { throw LoadFailure(files: input.modules, reason: error) }
        guard case .record = table.sourceValue else {
            throw SettingsLuauError(
                message: "\(entry?.lastPathComponent ?? "shell.luau"): expected a table with named keys."
            )
        }
        self.entry = entry
        self.packageRoot = root
        files = input.modules
    }

    static func load(at url: URL, packageRoot: URL? = nil) throws -> Self {
        let target = try SettingsFileAccess.settingsTarget(for: url)
        let contents = try SettingsFileAccess.readContents(at: target, maximumBytes: ConfigScriptLoader.sourceLimit)
        var document = try Self(contents.data, at: url, packageRoot: packageRoot)
        document.files[url] = .target(contents.fingerprint)
        return document
    }

    func editing(_ changes: [([String], SettingsLuauValue?)]) throws -> (source: Data, question: String?) {
        let patch = try prepare(changes)
        return (patch.source, patch.question)
    }

    private struct Patch {
        let source: Data
        let question: String?
        let dependencies: SettingsFileVersions
    }

    private func prepare(_ changes: [([String], SettingsLuauValue?)]) throws -> Patch {
        var desired = value
        for (path, value) in changes {
            try desired.putShellValue(value, at: path[...])
        }
        guard !desired.representsSameTable(as: value) else { return Patch(
            source: source,
            question: nil,
            dependencies: files
        ) }
        let patch = try table.edit(from: value, to: desired)
        let candidate = try Self(patch.source, at: entry, packageRoot: packageRoot)
        guard candidate.files.isCurrent,
              files.isCurrent
        else { throw SettingsLuauError(message: "A shell helper changed during the edit. Try again.") }
        let dependencies = files.merging(candidate.files) { original, _ in original }
        guard let question = patch.question else { return Patch(
            source: patch.source,
            question: nil,
            dependencies: dependencies
        ) }

        for (path, expected) in changes {
            let actual = path.reduce(Optional(candidate.value)) { $0?[$1] }
            guard actual?.representsSameTable(as: expected) ?? (expected == nil) else {
                throw SettingsLuauError(
                    message: "The replacement does not produce the requested value for \(path.joined(separator: ".")). Edit shell.luau directly."
                )
            }
        }
        let additional = SettingsValueChange.between(patch.expected ?? desired, candidate.value, rows: .positions)
            .filter { change in
                guard let old = change.old, let new = change.value else { return true }
                return !old.representsSameTable(as: new)
            }
        guard !additional.isEmpty else { return Patch(
            source: patch.source,
            question: question,
            dependencies: dependencies
        ) }
        return Patch(
            source: patch.source,
            question: question + "\n\nOther settings calculated by this code will also change:\n" + additional
                .map(\.summary)
                .joined(separator: "\n"),
            dependencies: dependencies
        )
    }

    @discardableResult
    static func write(
        _ changes: [([String], SettingsLuauValue?)],
        in shellDirectory: URL,
        writeFile: (@Sendable (Data, URL) throws -> Void)? = nil
    ) throws -> Bool {
        let url = shellDirectory.appendingPathComponent("shell.luau")
        let request: ShellLuauConfirmation
        if let approved {
            guard approved.url == url, approved.changes.elementsEqual(changes, by: ==) else {
                throw SettingsLuauError(message: "The shell edit changed. Review the new values before saving.")
            }
            request = approved
        } else {
            let target = try SettingsFileAccess.settingsTarget(for: url)
            let version = ConfigScriptFileVersion(at: url)
            var document: Self
            if case .unresolved(nil, Int(ENOENT)) = version {
                document = try Self(Data("return {}\n".utf8), at: url)
                document.files[url] = version
            } else {
                document = try load(at: url)
            }
            let patch = try document.prepare(changes)
            guard patch.source != document.source else { return false }
            request = ShellLuauConfirmation(
                url: url,
                message: patch.question ?? "",
                target: target,
                files: patch.dependencies,
                changes: changes,
                replacement: patch.source
            )
            if patch.question != nil { throw request }
        }
        try request.checkCurrent()
        try SettingsFileAccess.ensureDirectoryExists(at: shellDirectory)
        if let writeFile { try writeFile(request.replacement, request.target) }
        else if request.files[url]?.targetFingerprint == nil { try SettingsFileAccess.createAtomically(
            request.replacement,
            at: request.target
        ) } else { try SettingsFileAccess.writeAtomically(request.replacement, at: request.target) }
        return true
    }
}

extension SettingsLuauValue {
    fileprivate mutating func putShellValue(_ value: Self?, at path: ArraySlice<String>) throws {
        guard let key = path.first, case var .record(fields) = self else {
            throw SettingsLuauError(message: "The shell setting at \(path.joined(separator: ".")) could not be edited.")
        }
        if path.count == 1 { fields[key] = value }
        else if fields[key] != nil || value != nil {
            var child = fields[key] ?? .record([:])
            try child.putShellValue(value, at: path.dropFirst())
            fields[key] = value == nil && child == .record([:]) ? nil : child
        }
        self = .record(fields)
    }

    fileprivate func representsSameTable(as other: Self?) -> Bool {
        guard let other else { return false }
        switch (self, other) {
        case let (.record(fields), .list(rows)),
             let (.list(rows), .record(fields)):
            return fields.isEmpty && rows.isEmpty
        case let (.record(lhs), .record(rhs)):
            return lhs.count == rhs.count && lhs.allSatisfy { key, value in value.representsSameTable(as: rhs[key]) }
        case let (.list(lhs), .list(rhs)):
            return lhs.elementsEqual(rhs) { $0.representsSameTable(as: $1) }
        default: return self == other
        }
    }
}
