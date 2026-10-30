// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import EventKit
import Foundation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class ShellCalendarDayTests: XCTestCase {
    func testDayAndAddCommandsRequireStrictDatesAndBoundedText() {
        XCTAssertEqual(ShellCalendarCommand(words: ["day", "2024-02-29"]), .day("2024-02-29"))
        XCTAssertEqual(ShellCalendarCommand(words: ["month", "today"]), .month(delta: 0))
        XCTAssertEqual(ShellRemindersCommand(words: ["add", "Call", "mom"]), .add(text: "Call mom"))
        for value in [
            "2023-02-29",
            "2024-04-31",
            "2024-13-01",
            "2024-00-01",
            "0000-01-01",
            "2024-1-01",
            "2024-01-1",
            "2024-01-01x"
        ] {
            XCTAssertNil(ShellCalendarDay(value), value)
            XCTAssertNil(ShellCalendarCommand(words: ["day", value]), value)
        }
        XCTAssertNil(ShellCalendarCommand(words: ["day", "2024-02-29", "extra"]))
        XCTAssertNil(ShellRemindersCommand(words: ["add"]))
        XCTAssertNil(ShellRemindersCommand(words: ["add", "  "]))
        XCTAssertNil(ShellRemindersCommand(words: ["add", String(repeating: "x", count: 4097)]))
    }

    func testLeadingTimeUsesTheSelectedDayAndNoTimeIsAllDay() throws {
        let calendar = utc()
        let day = try date("2024-02-29", calendar: calendar)
        let timed = try XCTUnwrap(ShellReminderDraft("3:30pm Call mom", day: day, calendar: calendar))
        XCTAssertEqual(timed.title, "Call mom")
        XCTAssertFalse(timed.allDay)
        XCTAssertEqual(timed.due.year, 2024)
        XCTAssertEqual(timed.due.month, 2)
        XCTAssertEqual(timed.due.day, 29)
        XCTAssertEqual(timed.due.hour, 15)
        XCTAssertEqual(timed.due.minute, 30)
        let allDay = try XCTUnwrap(ShellReminderDraft("Call mom", day: day, calendar: calendar))
        XCTAssertTrue(allDay.allDay)
        XCTAssertEqual(allDay.due.year, 2024)
        XCTAssertEqual(allDay.due.month, 2)
        XCTAssertEqual(allDay.due.day, 29)
        let embedded = try XCTUnwrap(ShellReminderDraft("Call mom at 3:30pm", day: day, calendar: calendar))
        XCTAssertEqual(embedded.title, "Call mom at 3:30pm")
        XCTAssertTrue(embedded.allDay)
        XCTAssertNil(ShellReminderDraft("3:30pm", day: day, calendar: calendar))
        XCTAssertNil(ShellReminderDraft(" ", day: day, calendar: calendar))
    }

    func testSelectedDayUsesIndependentQueriesAndKeepsPastEventsAndAllItsReminders() async throws {
        let calendar = utc()
        let selected = try date("2024-02-29", calendar: calendar)
        let old = try date("2020-01-01", calendar: calendar)
        let now = try date("2026-10-28", calendar: calendar)
        let dayEvents = (0 ..< 120).map { event("day-\($0)", start: selected.addingTimeInterval(Double($0) * 60)) }
        let dayReminders = (0 ..< 120).map { reminder("day-\($0)", due: selected.addingTimeInterval(Double($0) * 60)) }
        let oldReminders = (0 ..< 120).map { reminder("old-\($0)", due: old.addingTimeInterval(Double($0) * 60)) }
        let store = Store(events: dayEvents, items: oldReminders + dayReminders)
        let reader = CalendarReader(operations: store.operations)
        let global = await reader.readReminders()
        XCTAssertEqual(global.items.count, 100)
        XCTAssertTrue(global.items.allSatisfy { $0.id.hasPrefix("old-") })
        let reading = await reader.read(monthOffset: 0, now: now, calendar: calendar, selectedDay: "2024-02-29")
        XCTAssertEqual(reading.calendar.selectedDay, "2024-02-29")
        XCTAssertEqual(reading.calendar.events.count, 120)
        XCTAssertEqual(reading.calendar.events.first?.id, "day-0")
        XCTAssertEqual(reading.calendar.reminders?.items.count, 120)
        XCTAssertEqual(reading.calendar.reminders?.total, 120)
        XCTAssertTrue(reading.calendar.reminders?.items.allSatisfy { $0.id.hasPrefix("day-") } == true)
        XCTAssertEqual(reading.calendar.month?.year, 2024)
        XCTAssertEqual(reading.calendar.month?.month, 2)
        let expected = try XCTUnwrap(calendar.dateInterval(of: .day, for: selected))
        XCTAssertTrue(store.eventQueries.withLock { $0.contains(expected) })
        XCTAssertEqual(store.reminderQueries.withLock { $0 }, [nil, expected])
        XCTAssertEqual(store.saveCalls.withLock { $0 }, 0)
    }

    func testNoSelectionPreservesTheSevenDayUpcomingAgendaAndItsLimit() async throws {
        let calendar = utc()
        let now = try date("2026-10-28", calendar: calendar).addingTimeInterval(12 * 3600)
        let ended = event("ended", start: now.addingTimeInterval(-7200))
        let events = (0 ..< 120).map { event("next-\($0)", start: now.addingTimeInterval(Double($0) * 60)) }
        let beyond = event("beyond", start: now.addingTimeInterval(8 * 86400))
        let store = Store(events: [ended] + events + [beyond])
        let reader = CalendarReader(operations: store.operations)
        let reading = await reader.read(monthOffset: 0, now: now, calendar: calendar)
        XCTAssertNil(reading.calendar.selectedDay)
        XCTAssertNil(reading.calendar.reminders)
        XCTAssertEqual(reading.calendar.events.count, 100)
        XCTAssertEqual(reading.calendar.events.first?.id, "next-0")
        XCTAssertEqual(reading.calendar.events.last?.id, "next-99")
        XCTAssertTrue(store.reminderQueries.withLock { $0.isEmpty })
    }

    func testDeniedDayReadsAndAddsNeverQueryOrSave() async throws {
        let calendar = utc()
        let now = try date("2026-10-28", calendar: calendar)
        for status in [EKAuthorizationStatus.notDetermined, .denied, .restricted, .writeOnly] {
            let store = Store(eventAccess: status, reminderAccess: status)
            let reader = CalendarReader(operations: store.operations)
            let snapshot = await reader.read(monthOffset: 0, now: now, calendar: calendar, selectedDay: "2024-02-29")
            XCTAssertEqual(snapshot.calendar.access, CalendarReader.name(of: status))
            XCTAssertEqual(snapshot.calendar.reminders?.access, CalendarReader.name(of: status))
            let result = await reader.addReminder("Call mom", selectedDay: "2024-02-29", now: now, calendar: calendar)
            XCTAssertEqual(result.error, "access_\(CalendarReader.name(of: status))")
            XCTAssertTrue(store.eventQueries.withLock { $0.isEmpty })
            XCTAssertTrue(store.reminderQueries.withLock { $0.isEmpty })
            XCTAssertEqual(store.saveCalls.withLock { $0 }, 0)
        }
    }

    func testReaderAddsOnTheSelectedDayAndReportsSaveFailures() async throws {
        let calendar = utc()
        let now = try date("2026-10-28", calendar: calendar)
        let store = Store()
        let reader = CalendarReader(operations: store.operations)
        let result = await reader.addReminder(
            "3:30pm Call mom",
            selectedDay: "2024-02-29",
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(result.ok)
        let saved = try XCTUnwrap(store.saved.withLock { $0.first })
        XCTAssertEqual(saved.due.year, 2024)
        XCTAssertEqual(saved.due.month, 2)
        XCTAssertEqual(saved.due.day, 29)
        XCTAssertEqual(saved.due.hour, 15)
        let invalid = await reader.addReminder("", selectedDay: nil, now: now, calendar: calendar)
        XCTAssertEqual(invalid.error, "invalid_reminder")
        XCTAssertEqual(store.saveCalls.withLock { $0 }, 1)
        let blocked = Store(saveError: .readOnly)
        let failure = await CalendarReader(operations: blocked.operations)
            .addReminder("Call mom", selectedDay: nil, now: now, calendar: calendar)
        XCTAssertEqual(failure.error, "reminder_read_only")
    }

    func testCalendarOnlyDemandRefreshesTheDayAfterAddAndTodayClearsSelection() async throws {
        let store = Store()
        let controller = CalendarController(reader: CalendarReader(operations: store.operations))
        controller.perform(.day("2024-02-29"))
        let initial = await waitFor(controller) { $0.selectedDay == "2024-02-29" }
        XCTAssertEqual(initial.reminders?.access, "full")
        XCTAssertEqual(store.reminderQueries.withLock { $0.count }, 1)
        let added = await waitFor(controller, action: { controller.perform(.add(text: "Call mom")) }, matching: {
            $0.reminders?.items.count == 1
        })
        XCTAssertEqual(added.reminders?.items.first?.title, "Call mom")
        XCTAssertNil(controller.reminders)
        XCTAssertGreaterThan(store.reminderQueries.withLock { $0.count }, 1)
        _ = await waitFor(controller, action: { controller.perform(ShellCalendarCommand.month(delta: 0)) }, matching: {
            $0.selectedDay == nil
        })
        XCTAssertNil(controller.selectedDay)
        controller.setListening(false)
    }

    func testDaySnapshotSurfacesTheExistingReminderActionError() async {
        let store = Store(saveError: .readOnly)
        let controller = CalendarController(reader: CalendarReader(operations: store.operations))
        controller.perform(.day("2024-02-29"))
        _ = await waitFor(controller) { $0.selectedDay != nil }
        let failed = await waitFor(controller, action: { controller.perform(.add(text: "Call mom")) }, matching: {
            $0.reminders?.error != nil
        })
        XCTAssertEqual(failed.reminders?.error, "reminder_read_only")
        XCTAssertNil(controller.reminders)
        controller.setListening(false)
    }

    private func waitFor(
        _ controller: CalendarController, action: (() -> Void)? = nil, matching: @escaping (ShellCalendar) -> Bool
    ) async -> ShellCalendar {
        await withCheckedContinuation { continuation in
            controller.onChange = { snapshot in
                guard let snapshot, matching(snapshot) else { return }
                controller.onChange = nil
                continuation.resume(returning: snapshot)
            }
            if let action { action() } else { controller.setListening(true) }
        }
    }

    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String, calendar: Calendar) throws -> Date {
        try XCTUnwrap(ShellCalendarDay(value)?.date(in: calendar))
    }

    private func event(_ id: String, start: Date) -> ShellCalendarEvent {
        ShellCalendarEvent(
            id: id, title: id, calendar: "Fixture", color: "#112233", start: start.timeIntervalSince1970,
            end: start.addingTimeInterval(60).timeIntervalSince1970, allDay: false, location: nil, time: "", day: ""
        )
    }

    private func reminder(_ id: String, due: Date) -> ShellReminder {
        ShellReminder(
            id: id, title: id, list: "Fixture", color: "#112233", due: due.timeIntervalSince1970,
            allDay: true, priority: 0, canComplete: true
        )
    }
}

private final class Store: Sendable {
    let eventQueries = Mutex<[DateInterval]>([])
    let reminderQueries = Mutex<[DateInterval?]>([])
    let saved = Mutex<[ShellReminderDraft]>([])
    let saveCalls = Mutex(0)
    private let events: [ShellCalendarEvent]
    private let items: [ShellReminder]
    private let eventAccess: EKAuthorizationStatus
    private let reminderAccess: EKAuthorizationStatus
    private let saveError: ShellReminderError?

    init(
        events: [ShellCalendarEvent] = [], items: [ShellReminder] = [],
        eventAccess: EKAuthorizationStatus = .fullAccess, reminderAccess: EKAuthorizationStatus = .fullAccess,
        saveError: ShellReminderError? = nil
    ) {
        self.events = events
        self.items = items
        self.eventAccess = eventAccess
        self.reminderAccess = reminderAccess
        self.saveError = saveError
    }

    var operations: CalendarReader.Operations {
        CalendarReader.Operations(
            eventAccess: { self.eventAccess }, reminderAccess: { self.reminderAccess },
            events: { interval in
                self.eventQueries.withLock { $0.append(interval) }
                return self.events
                    .filter {
                        $0.start < interval.end.timeIntervalSince1970 && $0.end > interval.start.timeIntervalSince1970
                    }
            },
            reminders: { interval in
                self.reminderQueries.withLock { $0.append(interval) }
                let values = self.items + self.created()
                guard let interval else { return .bounded(values) }
                let items = values.filter { value in
                    value.due
                        .map { $0 >= interval.start.timeIntervalSince1970 && $0 < interval.end.timeIntervalSince1970
                        } ??
                        false
                }.sorted { $0.precedes($1) }
                return ShellReminders(access: "full", items: items, total: items.count)
            },
            saveReminder: { draft in
                self.saveCalls.withLock { $0 += 1 }
                if let error = self.saveError { throw error }
                self.saved.withLock { $0.append(draft) }
            }
        )
    }

    private func created() -> [ShellReminder] {
        saved.withLock { drafts in
            drafts.enumerated().map { index, draft in
                ShellReminder(
                    id: "created-\(index)", title: draft.title, list: "Fixture", color: "#112233",
                    due: draft.due.date?.timeIntervalSince1970, allDay: draft.allDay, priority: 0, canComplete: true
                )
            }
        }
    }
}
