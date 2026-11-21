// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum ShellNotificationTrace {
    struct Record: Sendable {
        let time: TimeInterval
        let event: String
        let target: UUID?
        let fields: String
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Shell Notification Trace",
        capacity: 1024,
        formatter: { record in
            let target = record.target.map { " target=\($0.uuidString.lowercased())" } ?? ""
            return String(format: "t=%.6f", record.time) + " ev=\(record.event)\(target) \(record.fields)"
        }
    )

    static func record(_ event: StaticString, target: UUID? = nil, fields: @autoclosure () -> String = "") {
        guard shared.isActive else { return }
        shared.record(Record(
            time: ProcessInfo.processInfo.systemUptime,
            event: event.description,
            target: target,
            fields: RuntimeTraceLimits.boundedString(fields(), maxBytes: 1024)
        ))
    }

    static func snapshotSummary(_ value: ShellNotificationsData) -> String {
        var summary = "state=\(value.state) complete=\(value.complete) items=\(value.items.count) apps=\(value.apps.count)"
        summary += " membershipComplete=\(value.membershipComplete) metadataComplete=\(value.metadataComplete)"
        if !value.issues.isEmpty {
            summary += " issues=" + value.issues.map { "\($0.scope.rawValue):\($0.reason.rawValue)" }
                .joined(separator: ",")
        }
        if let action = value.action?.fields, let id = action["id"]?.string {
            let target = UUID(uuidString: id)
            let retained = target != nil && value.items.contains {
                $0.fields?["id"]?.string.flatMap(UUID.init(uuidString:)) == target
                    && $0.fields?["bundle"]?.string == action["bundle"]?.string
            }
            summary += " action=\(action["kind"]?.string ?? "none") outcome=\(action["state"]?.string ?? "none")"
                + " target=\(id) targetRetained=\(value.membershipComplete ? String(retained) : "unknown")"
        }
        return summary
    }
}
