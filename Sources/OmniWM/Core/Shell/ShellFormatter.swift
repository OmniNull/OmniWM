// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost
import Synchronization

enum ShellFormatter {
    private static let dates = Mutex<[String: DateFormatter]>([:])
    private static let dateLimit = 32

    static let callback: omni_formatter =
        { _, kind, value, digits, pattern, patternLength, zone, zoneLength, out, capacity in
            guard let out else { return 0 }
            let text = { (start: UnsafePointer<CChar>?, count: Int) in
                start.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: count), as: UTF8.self) }
            }
            let result: String? = switch UInt32(kind) {
            case OMNI_FORMAT_DATE: date(
                    value,
                    template: text(pattern, patternLength) ?? "",
                    zone: text(zone, zoneLength)
                )
            case OMNI_FORMAT_OFFSET: offset(value, zone: text(zone, zoneLength)).map(String.init)
            default: string(kind: UInt32(kind), value, digits: Int(digits))
            }
            return result.map { ShellLocalizer.copy($0, into: out, capacity: capacity) } ?? 0
        }

    static func date(_ seconds: Double, template: String, zone: String?, locale: Locale = .current) -> String? {
        guard let timeZone = timeZone(zone), !template.isEmpty else { return nil }
        let key = "\(locale.identifier)\u{0}\(template)\u{0}\(timeZone.identifier)"
        return dates.withLock { cache in
            if cache[key] == nil {
                if cache.count >= dateLimit {
                    cache.removeAll()
                }
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.timeZone = timeZone
                formatter.setLocalizedDateFormatFromTemplate(template)
                cache[key] = formatter
            }
            return cache[key]?.string(from: Date(timeIntervalSince1970: seconds))
        }
    }

    static func offset(_ seconds: Double, zone: String?) -> Int? {
        timeZone(zone)?.secondsFromGMT(for: Date(timeIntervalSince1970: seconds))
    }

    private static func timeZone(_ zone: String?) -> TimeZone? {
        guard let zone else { return .current }
        return TimeZone(identifier: zone)
    }

    static func string(kind: UInt32, _ value: Double, digits: Int, locale: Locale = .current) -> String {
        switch kind {
        case OMNI_FORMAT_PERCENT:
            return value.formatted(.percent.precision(.fractionLength(digits)).locale(locale))
        case OMNI_FORMAT_MEMORY,
             OMNI_FORMAT_FILE:
            guard value.isFinite, abs(value) < 9e18 else { return "—" }
            let formatter = ByteCountFormatter()
            formatter.countStyle = kind == OMNI_FORMAT_FILE ? .file : .memory
            formatter.allowsNonnumericFormatting = false
            return formatter.string(fromByteCount: Int64(value.rounded()))
        default:
            return value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        }
    }
}
