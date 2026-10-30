// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import EventKit
import Foundation

struct ShellCalendarDay: Equatable, Sendable {
    let value: String
    private let year: Int
    private let month: Int
    private let day: Int

    init?(_ value: String) {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48 ... 57).contains($0.element) }),
              let year = Int(value.prefix(4)), year > 0,
              let month = Int(value.dropFirst(5).prefix(2)), let day = Int(value.suffix(2))
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year, components.month == month, components.day == day else { return nil }
        self.value = value
        self.year = year
        self.month = month
        self.day = day
    }

    func date(in calendar: Calendar) -> Date? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.date(from: DateComponents(year: year, month: month, day: day))
    }
}

enum ShellCalendarCommand: Equatable, Sendable {
    case authorize
    case settings
    case open(event: String?)
    case month(delta: Int)
    case day(String)

    init?(words: [String]) {
        switch words {
        case ["authorize"]: self = .authorize
        case ["settings"]: self = .settings
        case ["open"]: self = .open(event: nil)
        case let words where words.count == 2 && words[0] == "open": self = .open(event: words[1])
        case ["month", "next"]: self = .month(delta: 1)
        case ["month", "previous"]: self = .month(delta: -1)
        case ["month", "today"]: self = .month(delta: 0)
        case let words where words.count == 2 && words[0] == "day" && ShellCalendarDay(words[1]) != nil:
            self = .day(words[1])
        default: return nil
        }
    }
}

struct ShellCalendarEvent: Equatable, Sendable {
    let id: String
    let title: String
    let calendar: String
    let color: String
    let start: Double
    let end: Double
    let allDay: Bool
    let location: String?
    let time: String
    let day: String
}

struct ShellCalendarMonth: Equatable, Sendable {
    let title: String
    let year: Int
    let month: Int
    let days: Int
    let offset: Int
    let today: Int
    let weekdays: [String]
    let marked: [Int]
}

struct ShellCalendar: Equatable, Sendable {
    var access = "notDetermined"
    var events: [ShellCalendarEvent] = []
    var month: ShellCalendarMonth?
    var selectedDay: String?
    var reminders: ShellReminders?

    func write(into writer: inout ShellValueWriter) {
        writer.map(5)
        writer.key("access")
        writer.string(access)
        writer.key("events")
        writer.array(events.count)
        for event in events { event.write(into: &writer) }
        writer.key("selectedDay")
        selectedDay.map { writer.string($0) } ?? writer.null()
        writer.key("reminders")
        reminders.map { $0.write(into: &writer) } ?? writer.null()
        writer.key("month")
        guard let month else { return writer.null() }
        writer.map(8)
        writer.key("title")
        writer.string(month.title)
        writer.key("year")
        writer.number(Double(month.year))
        writer.key("month")
        writer.number(Double(month.month))
        writer.key("days")
        writer.number(Double(month.days))
        writer.key("offset")
        writer.number(Double(month.offset))
        writer.key("today")
        writer.number(Double(month.today))
        writer.key("weekdays")
        writer.array(month.weekdays.count)
        month.weekdays.forEach { writer.string($0) }
        writer.key("marked")
        writer.array(month.marked.count)
        month.marked.forEach { writer.number(Double($0)) }
    }
}

extension ShellCalendarEvent {
    fileprivate func write(into writer: inout ShellValueWriter) {
        writer.map(10)
        writer.key("id")
        writer.string(id)
        writer.key("title")
        writer.string(title)
        writer.key("calendar")
        writer.string(calendar)
        writer.key("color")
        writer.string(color)
        writer.key("start")
        writer.number(start)
        writer.key("end")
        writer.number(end)
        writer.key("allDay")
        writer.bool(allDay)
        writer.key("location")
        location.map { writer.string($0) } ?? writer.null()
        writer.key("time")
        writer.string(time)
        writer.key("day")
        writer.string(day)
    }
}

extension CalendarReader {
    nonisolated static func name(of status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: "full"
        case .writeOnly: "writeOnly"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "notDetermined"
        }
    }

    struct Operations: Sendable {
        let eventAccess: @Sendable () -> EKAuthorizationStatus
        let reminderAccess: @Sendable () -> EKAuthorizationStatus
        let events: @Sendable (DateInterval) -> [ShellCalendarEvent]
        let reminders: @Sendable (DateInterval?) async -> ShellReminders
        let saveReminder: @Sendable (ShellReminderDraft) throws -> Void
    }

    static func markedDays(_ events: [ShellCalendarEvent], in month: DateInterval, calendar: Calendar) -> Set<Int> {
        var marked: Set<Int> = []
        for event in events {
            var day = max(calendar.startOfDay(for: Date(timeIntervalSince1970: event.start)), month.start)
            let until = max(min(Date(timeIntervalSince1970: event.end), month.end), day.addingTimeInterval(1))
            while day < until {
                marked.insert(calendar.component(.day, from: day))
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return marked
    }
}
