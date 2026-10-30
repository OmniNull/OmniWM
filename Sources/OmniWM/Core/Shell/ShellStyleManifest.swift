// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

struct ShellStyleManifest: Equatable, Sendable {
    static let fileName = "style.toml"
    static let format = 1
    static let api = 1
    private static let release = #"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z"#
    private static let keys: Set = [
        "format", "name", "version", "api", "minOmniWM", "author", "license", "tags", "title", "summary",
        "description", "previews", "barEffect"
    ]

    let name: String
    let version: String
    let minimumOmniWM: String?
    let author: String?
    let license: String?
    let tags: [String]
    let title: String
    let summary: String
    let description: String?
    let previews: [String]
    let barEffect: ShellBarEffect?

    static func load(in folder: URL, appVersion: ReleaseVersion? = Bundle.main.releaseVersion) throws -> Self? {
        try table(at: folder.appendingPathComponent(fileName), name: fileName)
            .map { try Self($0, appVersion: appVersion) }
    }

    static func parse(_ data: Data, appVersion: ReleaseVersion? = Bundle.main.releaseVersion) throws -> Self {
        let table: [String: TOMLNode]
        do {
            table = try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        } catch {
            throw failure(error.localizedDescription)
        }
        return try Self(table, appVersion: appVersion)
    }

    static func problem(in folder: URL) -> String? {
        do {
            _ = try load(in: folder)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func table(at file: URL, name: String) throws -> [String: TOMLNode]? {
        do {
            guard let data = try SettingsFileAccess.existingData(at: file) else { return nil }
            guard data.count <= ShellWidgetSourceLoader.sourceLimit else { throw CocoaError(.fileReadTooLarge) }
            return try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        } catch {
            throw ShellScriptFailure(kind: .compile, message: "\(name): \(error.localizedDescription)")
        }
    }

    init(_ table: [String: TOMLNode], appVersion: ReleaseVersion?) throws {
        let format = try Self.integer(table["format"], key: "format")
        guard format == Self.format else {
            throw Self
                .failure(format > Self.format ? "needs a newer version of OmniWM" : "format must be \(Self.format)")
        }
        if let key = table.keys.sorted().first(where: { !Self.keys.contains($0) }) {
            throw Self.failure("unknown key \(key)")
        }
        let api = try Self.integer(table["api"], key: "api")
        guard api == Self.api else {
            throw Self.failure("was made for style API \(api); this OmniWM supports style API \(Self.api)")
        }
        name = try Self.string(table["name"], key: "name")
        guard ShellConfig.isName(name) else { throw Self.failure("name must be a folder name") }
        version = try Self.string(table["version"], key: "version")
        guard Self.isRelease(version) else { throw Self.failure("version must look like 1.2.3") }
        minimumOmniWM = try Self.optionalString(table["minOmniWM"], key: "minOmniWM")
        if let minimumOmniWM {
            guard Self.isRelease(minimumOmniWM), let minimum = ReleaseVersion(minimumOmniWM) else {
                throw Self.failure("minOmniWM must look like 1.2.3")
            }
            if let appVersion, appVersion < minimum { throw Self.failure("needs OmniWM \(minimumOmniWM) or later") }
        }
        author = try Self.optionalString(table["author"], key: "author")
        license = try Self.optionalString(table["license"], key: "license")
        tags = try Self.strings(table["tags"], key: "tags")
        title = try Self.string(table["title"], key: "title")
        summary = try Self.string(table["summary"], key: "summary")
        description = try Self.optionalString(table["description"], key: "description")
        previews = try Self.strings(table["previews"], key: "previews")
        guard previews.allSatisfy(ShellConfig.isName) else { throw Self.failure("previews must be file names") }
        barEffect = try table["barEffect"].map(ShellBarEffect.init)
    }

    private static func isRelease(_ text: String) -> Bool {
        text.range(of: release, options: .regularExpression) != nil
    }

    static func failure(_ problem: String) -> ShellScriptFailure {
        ShellScriptFailure(kind: .compile, message: "\(fileName): \(problem)")
    }

    private static func integer(_ node: TOMLNode?, key: String) throws -> Int {
        guard case let .integer(value)? = node, let integer = Int(exactly: value) else {
            throw failure("\(key) must be an integer")
        }
        return integer
    }

    private static func string(_ node: TOMLNode?, key: String) throws -> String {
        guard let value = try optionalString(node, key: key), !value.isEmpty else {
            throw failure("\(key) must be a nonempty string")
        }
        return value
    }

    private static func optionalString(_ node: TOMLNode?, key: String) throws -> String? {
        guard let node else { return nil }
        guard case let .string(value) = node else { throw failure("\(key) must be a string") }
        return value
    }

    private static func strings(_ node: TOMLNode?, key: String) throws -> [String] {
        guard let node else { return [] }
        guard case let .array(values) = node else { throw failure("\(key) must be a list of strings") }
        return try values.map { value in
            guard case let .string(string) = value else { throw failure("\(key) must be a list of strings") }
            return string
        }
    }
}

struct ShellBarEffect: Equatable, Sendable {
    private static let place = "[barEffect]"

    let title: String
    let values: [ShellComponentOption]

    init(_ node: TOMLNode) throws {
        guard case let .table(table) = node else { throw ShellStyleManifest.failure("\(Self.place) must be a table") }
        if let key = table.keys.sorted().first(where: { !["title", "values"].contains($0) }) {
            throw ShellStyleManifest.failure("\(Self.place) has unknown key \(key)")
        }
        guard case let .string(title)? = table["title"], !title.isEmpty else {
            throw ShellStyleManifest.failure("\(Self.place) title must be a nonempty string")
        }
        guard case let .array(entries)? = table["values"], (1 ... ShellBarShader.valueCount).contains(entries.count)
        else {
            throw ShellStyleManifest.failure("\(Self.place) values must list 1 to \(ShellBarShader.valueCount) options")
        }
        self.title = title
        values = try entries.enumerated().map { index, entry in
            let option = try ShellComponentCatalog.option(entry, key: "\(index)", widget: Self.place)
            guard option.kind == .number else {
                throw ShellStyleManifest.failure("\(Self.place) values must be number options")
            }
            return option
        }
    }
}

struct ShellStyle: Equatable, Sendable {
    let name: String
    var manifest: ShellStyleManifest?
    var strings = ShellStrings.empty
    var receipt: ShellStyleInstaller.Receipt?
    var problem: String?

    static func styles(in shellDirectory: URL) -> [Self] {
        ShellProfiles.names(in: shellDirectory).map { load($0, in: shellDirectory) }
    }

    static func load(_ profile: String, in shellDirectory: URL) -> Self {
        var style = Self(name: profile)
        let folder = shellDirectory.appendingPathComponent(profile, isDirectory: true)
        do {
            style.receipt = try ShellStyleInstaller.receipt(in: folder)
            style.manifest = try ShellStyleManifest.load(in: folder)
            style.strings = try ShellStrings.load(ShellConfig.directories(for: profile, in: shellDirectory))
        } catch {
            style.problem = error.localizedDescription
        }
        return style
    }
}
