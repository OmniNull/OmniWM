// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import EventKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellRemindersTests: XCTestCase {
    private func item(_ id: String, due: Double? = nil, priority: Int = 0) -> ShellReminder {
        ShellReminder(
            id: id, title: "Task \(id)", list: "Personal", color: "#112233", due: due,
            allDay: false, priority: priority, canComplete: true
        )
    }

    func testReminderCommandsAreExplicitAndBounded() {
        XCTAssertEqual(ShellAction("reminders authorize"), .reminders(.authorize))
        XCTAssertEqual(ShellAction("reminders settings"), .reminders(.settings))
        XCTAssertEqual(ShellAction("reminders complete item-1"), .reminders(.complete(id: "item-1")))
        XCTAssertNil(ShellAction("reminders complete"))
        XCTAssertNil(ShellAction("reminders complete first second"))
        XCTAssertNil(ShellAction("reminders delete item-1"))
    }

    func testAccessStatesStaySeparateAndCompletionDoesNotAuthorize() {
        let values: [(EKAuthorizationStatus, String)] = [
            (.notDetermined, "notDetermined"), (.restricted, "restricted"), (.denied, "denied"),
            (.writeOnly, "writeOnly"), (.fullAccess, "full")
        ]
        for (status, name) in values {
            XCTAssertEqual(CalendarReader.name(of: status), name)
            var saves = 0
            let result = ShellReminderResult.complete(id: "id", access: status) { _ in saves += 1 }
            XCTAssertEqual(saves, status == .fullAccess ? 1 : 0)
            XCTAssertEqual(result.error, status == .fullAccess ? nil : "access_\(name)")
        }
    }

    func testCompletionReturnsEveryAuthoritativeFailure() {
        var saves = 0
        let invalid = ShellReminderResult.complete(id: "", access: .fullAccess) { _ in saves += 1 }
        XCTAssertEqual(invalid.error, "invalid_reminder")
        XCTAssertEqual(saves, 0)
        for failure in [ShellReminderError.missing, .readOnly] {
            let result = ShellReminderResult.complete(id: "id", access: .fullAccess) { _ in throw failure }
            XCTAssertEqual(result.error, failure.rawValue)
        }
        let failed = ShellReminderResult.complete(id: "id", access: .fullAccess) { _ in
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture save failure"])
        }
        XCTAssertEqual(failed.error, "save_failed: fixture save failure")
        let completed = ShellReminderResult.complete(id: "id", access: .fullAccess) { id in
            XCTAssertEqual(id, "id")
            saves += 1
        }
        XCTAssertTrue(completed.ok)
        XCTAssertEqual(saves, 1)
    }

    func testSnapshotIsBoundedAndOrdersOverdueThenPriorityThenStableIdentity() {
        let values = (0 ..< 120).reversed().map { item("item-\($0)", due: Double($0)) }
        let snapshot = ShellReminders.bounded(values)
        XCTAssertEqual(snapshot.total, 120)
        XCTAssertEqual(snapshot.items.count, 100)
        XCTAssertEqual(snapshot.items.first?.due, 0)
        XCTAssertEqual(snapshot.items.last?.due, 99)
        let sameDate = ShellReminders.bounded([
            item("none"), item("low", due: 5, priority: 9), item("high-b", due: 5, priority: 1),
            item("high-a", due: 5, priority: 1), item("unset", due: 5), item("overdue", due: -5)
        ])
        XCTAssertEqual(sameDate.items.map(\.id), ["overdue", "high-a", "high-b", "low", "unset", "none"])
    }

    func testReminderChangeDoesNotDirtyTheCalendarKey() {
        let before = ShellWidgetData()
        var after = before
        after.reminders = ShellReminders(access: "full", items: [item("a")], total: 1)
        XCTAssertEqual(after.changedKeys(from: before), ShellDataKey.reminders.bit)
    }

    func testFeedKeepsReminderAndCalendarDemandIndependent() {
        let controller = CalendarController()
        let feed = ShellDataFeed(calendar: controller, deliver: { _ in })
        feed.start()
        let both = ShellDataKey.calendar.bit | ShellDataKey.reminders.bit
        feed.setDemand(both, cadence: .of([(both, nil)]))
        XCTAssertNotNil(controller.onChange)
        XCTAssertNotNil(controller.onRemindersChange)
        feed.setDemand(ShellDataKey.reminders.bit, cadence: .of([(ShellDataKey.reminders.bit, nil)]))
        XCTAssertNil(controller.onChange)
        XCTAssertNotNil(controller.onRemindersChange)
        XCTAssertNil(feed.current.calendar)
        feed.stop()
        XCTAssertNil(controller.onRemindersChange)
        XCTAssertNil(feed.current.reminders)
    }

    func testReminderOnlyDemandHasNoPollingCadence() {
        let cadence = ShellDataFeed.Cadence.of([(ShellDataKey.reminders.bit, nil)])
        XCTAssertEqual(cadence.tick, 0)
        XCTAssertEqual(cadence.sampling, 0)
    }

    func testPublicSnapshotContainsItemsAndVisibleErrors() throws {
        let widget = try ShellRenderedWidget(name: "reminder-fixture", source: """
        function render(ctx)
            local r = ctx.data.reminders
            local item = r.items[1]
            return ui.text{text = r.access .. ":" .. r.total .. ":" .. tostring(r.truncated)
                .. ":" .. item.title .. ":" .. tostring(item.canComplete) .. ":" .. r.error}
        end
        """)
        widget.set("reminders") {
            ShellReminders(access: "full", items: [self.item("a")], total: 101, error: "reminder_read_only")
                .write(into: &$0)
        }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("full:101:true:Task a:true:reminder_read_only"))
    }
}
