// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import EventKit

enum ShellRemindersCommand: Equatable, Sendable {
    case authorize
    case settings
    case complete(id: String)

    init?(words: [String]) {
        switch words {
        case ["authorize"]: self = .authorize
        case ["settings"]: self = .settings
        case let words where words.count == 2 && words[0] == "complete" && !words[1].isEmpty:
            self = .complete(id: words[1])
        default: return nil
        }
    }
}

struct ShellReminder: Equatable, Sendable {
    let id: String
    let title: String
    let list: String
    let color: String
    let due: Double?
    let allDay: Bool
    let priority: Int
    let canComplete: Bool

    func precedes(_ other: Self) -> Bool {
        if due != other.due { return (due ?? .infinity) < (other.due ?? .infinity) }
        if priority != other.priority {
            return (priority == 0 ? 10 : priority) < (other.priority == 0 ? 10 : other.priority)
        }
        return id < other.id
    }
}

struct ShellReminders: Equatable, Sendable {
    static let limit = 100

    var access = "notDetermined"
    var items: [ShellReminder] = []
    var total = 0
    var error: String?

    static func bounded(_ values: some Sequence<ShellReminder>) -> Self {
        var result = Self(access: "full")
        result.items.reserveCapacity(limit)
        for item in values {
            result.total += 1
            if result.items.count == limit, let last = result.items.last, !item.precedes(last) { continue }
            let index = result.items.firstIndex { item.precedes($0) } ?? result.items.endIndex
            result.items.insert(item, at: index)
            if result.items.count > limit { result.items.removeLast() }
        }
        return result
    }

    func write(into writer: inout ShellValueWriter) {
        writer.map(5)
        writer.key("access")
        writer.string(access)
        writer.key("items")
        writer.array(items.count)
        for item in items {
            writer.map(8)
            writer.key("id")
            writer.string(item.id)
            writer.key("title")
            writer.string(item.title)
            writer.key("list")
            writer.string(item.list)
            writer.key("color")
            writer.string(item.color)
            writer.key("due")
            item.due.map { writer.number($0) } ?? writer.null()
            writer.key("allDay")
            writer.bool(item.allDay)
            writer.key("priority")
            writer.number(Double(item.priority))
            writer.key("canComplete")
            writer.bool(item.canComplete)
        }
        writer.key("total")
        writer.number(Double(total))
        writer.key("truncated")
        writer.bool(total > items.count)
        writer.key("error")
        error.map { writer.string($0) } ?? writer.null()
    }
}

struct ShellReminderResult: Equatable, Sendable {
    let error: String?
    var ok: Bool {
        error == nil
    }

    static let success = Self(error: nil)

    static func complete(
        id: String,
        access: EKAuthorizationStatus,
        save: (String) throws -> Void
    ) -> Self {
        guard !id.isEmpty else { return Self(error: "invalid_reminder") }
        guard access == .fullAccess else { return Self(error: "access_\(CalendarReader.name(of: access))") }
        do {
            try save(id)
            return .success
        } catch let error as ShellReminderError {
            return Self(error: error.rawValue)
        } catch {
            return Self(error: "save_failed: \(String(error.localizedDescription.prefix(512)))")
        }
    }
}

enum ShellReminderError: String, Error {
    case missing = "reminder_not_found"
    case readOnly = "reminder_read_only"
}
