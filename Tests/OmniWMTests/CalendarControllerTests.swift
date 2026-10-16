// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import EventKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class CalendarControllerTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try XCTUnwrap(Calendar.autoupdatingCurrent.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: 9
        )))
    }

    private func event(_ id: String, start: Double, allDay: Bool = false) -> ShellCalendarEvent {
        ShellCalendarEvent(
            id: id, title: "Standup \(id)", calendar: "Work", color: "#FF9500", start: start,
            end: start + (allDay ? 86400 : 1800), allDay: allDay, location: nil, time: "9:30 AM", day: "Today"
        )
    }

    private func month() -> ShellCalendarMonth {
        ShellCalendarMonth(
            title: "October 2026", year: 2026, month: 10, days: 31, offset: 4, today: 8,
            weekdays: ["S", "M", "T", "W", "T", "F", "S"], marked: [8, 9]
        )
    }

    func testCalendarCommandsParse() {
        XCTAssertEqual(ShellAction("calendar authorize"), .calendar(.authorize))
        XCTAssertEqual(ShellAction("calendar open"), .calendar(.open(event: nil)))
        XCTAssertEqual(ShellAction("calendar open abc@123"), .calendar(.open(event: "abc@123")))
        XCTAssertEqual(ShellAction("calendar month previous"), .calendar(.month(delta: -1)))
        XCTAssertEqual(ShellAction("calendar month today"), .calendar(.month(delta: 0)))
        XCTAssertNil(ShellAction("calendar month later"))
        XCTAssertNil(ShellAction("calendar delete"))
    }

    func testTheMonthGridFollowsTheCalendarsFirstWeekday() async throws {
        let reader = CalendarReader()
        let now = try date(2026, 10, 8)
        for firstWeekday in [1, 2] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = .autoupdatingCurrent
            calendar.firstWeekday = firstWeekday
            let cases = [
                (0, (2026, 10, 31, 8, firstWeekday == 1 ? 4 : 3)),
                (4, (2027, 2, 28, 0, firstWeekday == 1 ? 1 : 0))
            ]
            for (offset, expected) in cases {
                let reading = await reader.read(monthOffset: offset, now: now, calendar: calendar)
                let month = try XCTUnwrap(reading.calendar.month)
                XCTAssertEqual(month.year, expected.0)
                XCTAssertEqual(month.month, expected.1)
                XCTAssertEqual(month.days, expected.2)
                XCTAssertEqual(month.today, expected.3)
                XCTAssertEqual(month.offset, expected.4, "first weekday \(firstWeekday), offset \(offset)")
                XCTAssertEqual(month.weekdays.first, firstWeekday == 1 ? "S" : "M")
                XCTAssertEqual(month.weekdays.count, 7)
            }
        }
        let reading = await reader.read(monthOffset: 0, now: now)
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            XCTAssertTrue(reading.calendar.events.isEmpty)
            XCTAssertEqual(reading.calendar.month?.marked, [])
        }
    }

    func testTheControllerReadsOnlyWhileListenedTo() async {
        let controller = CalendarController()
        var changes: [ShellCalendar?] = []
        await withCheckedContinuation { continuation in
            controller.onChange = { calendar in
                changes.append(calendar)
                if changes.count == 1 {
                    continuation.resume()
                }
            }
            controller.setListening(true)
        }
        XCTAssertNotNil(changes.first??.month)
        XCTAssertEqual(controller.calendar, changes.first ?? nil)
        controller.setListening(false)
        XCTAssertNil(controller.calendar)
        XCTAssertEqual(changes.count, 2)
    }

    func testTheFeedListensToTheCalendarOnlyWhileItIsRead() {
        let calendar = CalendarController()
        let feed = ShellDataFeed(calendar: calendar, deliver: { _ in })
        feed.start()
        feed.setDemand(ShellDataKey.calendar.bit, cadence: .of([(ShellDataKey.calendar.bit, nil)]))
        XCTAssertNotNil(calendar.onChange)
        feed.setDemand(ShellDataKey.clock.bit, cadence: .of([(ShellDataKey.clock.bit, nil)]))
        XCTAssertNil(calendar.onChange)
        XCTAssertNil(feed.current.calendar)
        feed.stop()
    }

    func testThePopoutAgendaSkipsEventsThatHaveEnded() throws {
        let widget = try ShellRenderedWidget("calendar")
        let now = 1_000_000.0
        let ended = (0 ..< 6).map { event("old\($0)", start: now - 7200 + Double($0) * 60) }
        let live = ShellCalendarEvent(
            id: "live", title: "Standup live", calendar: "Work", color: "#FF9500", start: now - 600, end: now + 1200,
            allDay: false, location: nil, time: "9:30 AM", day: "Today"
        )
        widget.set("calendar") {
            ShellCalendar(
                access: "full",
                events: ended + [live, self.event("next", start: now + 600)],
                month: self.month()
            )
            .write(into: &$0)
        }
        let none = ShellLocalizer.string("No upcoming events", [])
        widget.set("seconds") { $0.number(now) }
        _ = widget.renderPopout()
        let open = widget.strings(OMNI_VIEW_POPOUT)
        XCTAssertTrue(open.contains("Standup live"))
        XCTAssertTrue(open.contains("Standup next"))
        XCTAssertFalse(open.contains("Standup old0"))
        XCTAssertFalse(open.contains(none))

        widget.set("seconds") { $0.number(now + 3600) }
        _ = widget.renderPopout()
        let later = widget.strings(OMNI_VIEW_POPOUT)
        XCTAssertTrue(later.contains(none))
        XCTAssertFalse(later.contains("Standup next"))
    }

    func testTheCalendarWidgetCountsDownAndOffersAccessByState() throws {
        let widget = try ShellRenderedWidget("calendar")
        widget.set("seconds") { $0.number(1_000_000) }
        let data = { (access: String, events: [ShellCalendarEvent]) in
            widget
                .set("calendar") { ShellCalendar(access: access, events: events, month: self.month()).write(into: &$0) }
        }
        data("full", [event("a", start: 1_000_000 - 3600, allDay: true), event("b", start: 1_000_000 + 12 * 60 - 30)])
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("Standup b"))
        XCTAssertTrue(widget.strings().contains(ShellLocalizer.string("In %lld min", [.number(12)])))
        let actions = Set(widget.renderPopout().map { widget.text.string($0.content.action) })
        XCTAssertTrue(actions.isSuperset(of: [
            "calendar open a", "calendar open b", "calendar open", "calendar month previous", "calendar month next",
            "calendar month today"
        ]))
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains("31"))

        data("full", [event("c", start: 1_000_000 + 13 * 3600)])
        widget.render(ShellBarData())
        XCTAssertFalse(widget.strings().contains("Standup c"))

        data("notDetermined", [])
        XCTAssertTrue(widget.renderPopout().map { widget.text.string($0.content.action) }
            .contains("calendar authorize"))
        data("denied", [])
        XCTAssertTrue(widget.renderPopout().map { widget.text.string($0.content.action) }.contains("calendar settings"))
    }
}
