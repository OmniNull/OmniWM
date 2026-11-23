// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellConfig {
    static func layer(
        in directory: URL,
        packageRoot: URL?,
        files: inout Set<URL>,
        _ problems: inout [String]
    ) -> [String: SettingsLuauValue]? {
        let url = directory.appendingPathComponent("shell.luau")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return decode(url, packageRoot: packageRoot, files: &files, &problems)
    }

    static func decode(
        _ url: URL,
        packageRoot: URL?,
        files: inout Set<URL>,
        _ problems: inout [String]
    ) -> [String: SettingsLuauValue]? {
        do {
            let document = try ShellLuauDocument.load(at: url, packageRoot: packageRoot)
            files.formUnion(document.files.keys.filter { $0 != url })
            guard case let .record(values) = document.value else {
                throw SettingsLuauError(message: "Return a table with named fields.")
            }
            return values
        } catch {
            if let failure = error as? ShellLuauDocument.LoadFailure {
                files.formUnion(failure.files.keys.filter { $0 != url })
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
            report("shell.luau: [weather] units must be \"celsius\" or \"fahrenheit\"", &problems)
            return nil
        }
        let refresh = Duration.seconds(min(max(5, number(table["refresh"]) ?? 15), 24 * 60) * 60)
        if case let .string(city)? = table["city"], !city.trimmingCharacters(in: .whitespaces).isEmpty {
            return ShellWeatherLocation(place: .city(city), fahrenheit: fahrenheit, refresh: refresh)
        }
        guard let latitude = number(table["latitude"]), let longitude = number(table["longitude"]),
              (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude)
        else {
            report("shell.luau: [weather] needs city, or latitude and longitude", &problems)
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
