// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import TOML

extension ShellConfig {
    static func weatherLocation(
        _ table: [String: TOMLNode],
        _ problems: inout [String]
    ) -> ShellWeatherLocation? {
        let fahrenheit: Bool
        switch table["units"] {
        case nil,
             .string("celsius")?: fahrenheit = false
        case .string("fahrenheit")?: fahrenheit = true
        default:
            report("shell.toml: [weather] units must be \"celsius\" or \"fahrenheit\"", &problems)
            return nil
        }
        let refresh = Duration.seconds(min(max(5, number(table["refresh"]) ?? 15), 24 * 60) * 60)
        if case let .string(city)? = table["city"], !city.trimmingCharacters(in: .whitespaces).isEmpty {
            return ShellWeatherLocation(place: .city(city), fahrenheit: fahrenheit, refresh: refresh)
        }
        guard let latitude = number(table["latitude"]), let longitude = number(table["longitude"]),
              (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude)
        else {
            report("shell.toml: [weather] needs city, or latitude and longitude", &problems)
            return nil
        }
        return ShellWeatherLocation(
            place: .coordinates(latitude: latitude, longitude: longitude),
            fahrenheit: fahrenheit,
            refresh: refresh
        )
    }

    static func number(_ node: TOMLNode?) -> Double? {
        switch node {
        case let .float(value)?: value
        case let .integer(value)?: Double(value)
        default: nil
        }
    }

    static func encode(_ node: TOMLNode, into writer: inout ShellValueWriter) {
        switch node {
        case let .string(value): writer.string(value)
        case let .integer(value): writer.number(Double(value))
        case let .float(value): writer.number(value)
        case let .boolean(value): writer.bool(value)
        case let .array(values):
            writer.array(values.count)
            for value in values {
                encode(value, into: &writer)
            }
        case let .table(entries):
            writer.map(entries.count)
            for key in entries.keys.sorted() {
                writer.key(key)
                if let value = entries[key] {
                    encode(value, into: &writer)
                }
            }
        case .offsetDateTime,
             .localDateTime,
             .localDate,
             .localTime:
            writer.string(String(describing: node))
        }
    }
}
