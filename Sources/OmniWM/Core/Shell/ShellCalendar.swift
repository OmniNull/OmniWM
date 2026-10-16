// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

enum ShellCalendarCommand: Equatable, Sendable {
    case authorize
    case settings
    case open(event: String?)
    case month(delta: Int)

    init?(words: [String]) {
        switch words {
        case ["authorize"]: self = .authorize
        case ["settings"]: self = .settings
        case ["open"]: self = .open(event: nil)
        case let words where words.count == 2 && words[0] == "open": self = .open(event: words[1])
        case ["month", "next"]: self = .month(delta: 1)
        case ["month", "previous"]: self = .month(delta: -1)
        case ["month", "today"]: self = .month(delta: 0)
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

    func write(into writer: inout ShellValueWriter) {
        writer.map(3)
        writer.key("access")
        writer.string(access)
        writer.key("events")
        writer.array(events.count)
        for event in events {
            writer.map(10)
            writer.key("id")
            writer.string(event.id)
            writer.key("title")
            writer.string(event.title)
            writer.key("calendar")
            writer.string(event.calendar)
            writer.key("color")
            writer.string(event.color)
            writer.key("start")
            writer.number(event.start)
            writer.key("end")
            writer.number(event.end)
            writer.key("allDay")
            writer.bool(event.allDay)
            writer.key("location")
            event.location.map { writer.string($0) } ?? writer.null()
            writer.key("time")
            writer.string(event.time)
            writer.key("day")
            writer.string(event.day)
        }
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
