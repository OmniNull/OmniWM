// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellConfig {
    struct SourceFiles {
        private(set) var helpers: Set<URL> = []
        var versions: SettingsFileVersions?

        mutating func observe(_ url: URL) {
            versions?[url] = ConfigScriptFileVersion(at: url)
        }

        mutating func exists(_ url: URL) -> Bool {
            guard versions != nil else { return FileManager.default.fileExists(atPath: url.path) }
            let version = ConfigScriptFileVersion(at: url)
            versions?[url] = version
            return version.targetFingerprint != nil
        }

        mutating func record(_ files: SettingsFileVersions, entry: URL) {
            helpers.formUnion(files.keys.filter { $0 != entry })
            versions?.merge(files) { original, _ in original }
        }
    }

    static func resolve(shellDirectory: URL, problems: inout [String], inputs: inout SourceFiles) -> ShellConfig {
        if let config = load(shellDirectory, problems: &problems, inputs: &inputs) { return config }
        inputs.versions = nil
        problems = []
        return load(shellDirectory, skippingBrokenLayers: true, problems: &problems) ?? ShellConfig()
    }

    static func load(
        _ shellDirectory: URL,
        profile: String? = nil,
        skippingBrokenLayers: Bool,
        problems: inout [String],
        onFailure: (Set<URL>) -> Void = { _ in }
    ) -> ShellConfig? {
        var inputs = SourceFiles()
        let config = load(
            shellDirectory,
            profile: profile,
            skippingBrokenLayers: skippingBrokenLayers,
            problems: &problems,
            inputs: &inputs
        )
        if config == nil { onFailure(inputs.helpers) }
        return config
    }

    static func layer(
        in directory: URL,
        packageRoot: URL?,
        files: inout SourceFiles,
        _ problems: inout [String]
    ) -> [String: SettingsLuauValue]? {
        let url = directory.appendingPathComponent("shell.luau")
        guard files.exists(url) else { return [:] }
        return decode(url, packageRoot: packageRoot, files: &files, &problems)
    }

    static func decode(
        _ url: URL,
        packageRoot: URL?,
        files: inout SourceFiles,
        _ problems: inout [String]
    ) -> [String: SettingsLuauValue]? {
        do {
            let document = try ShellLuauDocument.load(at: url, packageRoot: packageRoot)
            files.record(document.files, entry: url)
            guard case let .record(values) = document.value else {
                throw SettingsLuauError(message: "Return a table with named fields.")
            }
            return values
        } catch {
            if let failure = error as? ShellLuauDocument.LoadFailure {
                files.record(failure.files, entry: url)
            }
            let name = "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
            report("\(name): \(error.localizedDescription)", &problems)
            return nil
        }
    }

    static func weatherLocation(
        _ table: [String: SettingsLuauValue],
        _ problems: inout [String]
    ) -> ShellWeatherLocation? {
        let fahrenheit: Bool
        switch table["units"] {
        case nil,
             .string("celsius")?: fahrenheit = false
        case .string("fahrenheit")?: fahrenheit = true
        default:
            report("shell.luau: weather.units must be \"celsius\" or \"fahrenheit\"", &problems)
            return nil
        }
        let refresh = Duration.seconds(min(max(5, number(table["refresh"]) ?? 15), 24 * 60) * 60)
        if case let .string(city)? = table["city"], !city.trimmingCharacters(in: .whitespaces).isEmpty {
            return ShellWeatherLocation(place: .city(city), fahrenheit: fahrenheit, refresh: refresh)
        }
        guard let latitude = number(table["latitude"]), let longitude = number(table["longitude"]),
              (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude)
        else {
            report("shell.luau: weather needs city, or latitude and longitude", &problems)
            return nil
        }
        return ShellWeatherLocation(
            place: .coordinates(latitude: latitude, longitude: longitude),
            fahrenheit: fahrenheit,
            refresh: refresh
        )
    }

    static func number(_ node: SettingsLuauValue?) -> Double? {
        switch node {
        case let .number(value)?: value
        case let .integer(value)?: Double(value)
        default: nil
        }
    }

    static func encode(_ node: SettingsLuauValue, into writer: inout ShellValueWriter) {
        switch node {
        case let .string(value): writer.string(value)
        case let .integer(value): writer.number(Double(value))
        case let .number(value): writer.number(value)
        case let .boolean(value): writer.bool(value)
        case let .list(values):
            writer.array(values.count)
            for value in values {
                encode(value, into: &writer)
            }
        case let .record(entries):
            writer.map(entries.count)
            for key in entries.keys.sorted() {
                writer.key(key)
                if let value = entries[key] {
                    encode(value, into: &writer)
                }
            }
        }
    }
}

extension SettingsLuauValue {
    var shellArray: [Self]? {
        switch self {
        case let .list(values): values
        case let .record(values) where values.isEmpty: []
        default: nil
        }
    }
}
