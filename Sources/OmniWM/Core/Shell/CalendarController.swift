// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import EventKit

@MainActor
final class CalendarController {
    private static let notifications: [Notification.Name] = [
        .EKEventStoreChanged,
        .NSCalendarDayChanged,
        .NSSystemClockDidChange,
        .NSSystemTimeZoneDidChange,
        NSLocale.currentLocaleDidChangeNotification
    ]

    private let reader = CalendarReader()
    private var listening = false
    private var remindersListening = false
    private var remindersVersion = 0
    private var remindersTask: Task<Void, Never>?
    private var remindersActionError: String?
    private var monthOffset = 0
    private var version = 0
    private var observers: [NSObjectProtocol] = []
    private var links: [String: URL] = [:]
    private(set) var calendar: ShellCalendar?
    var onChange: (@MainActor (ShellCalendar?) -> Void)?
    private(set) var reminders: ShellReminders?
    var onRemindersChange: (@MainActor (ShellReminders?) -> Void)?

    func setListening(_ listening: Bool) {
        guard self.listening != listening else { return }
        self.listening = listening
        if !listening {
            version += 1
            monthOffset = 0
            links = [:]
            publish(nil)
        }
        updateListening()
        if listening { refresh() }
    }

    func setRemindersListening(_ listening: Bool) {
        guard remindersListening != listening else { return }
        remindersListening = listening
        if !listening {
            remindersVersion += 1
            remindersTask?.cancel()
            publishReminders(nil)
        }
        updateListening()
        if listening { refreshReminders() }
    }

    func perform(_ command: ShellRemindersCommand) {
        Task { [reader] in
            let result: ShellReminderResult
            switch command {
            case .authorize:
                result = await reader.requestReminderAccess()
            case let .complete(id):
                result = await reader.completeReminder(id)
            case .settings:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            remindersActionError = result.error
            if let error = result.error { Log.shell.error("Reminders action failed: \(error)") }
            if var snapshot = reminders {
                snapshot.error = result.error
                publishReminders(snapshot)
            }
            refreshReminders()
        }
    }

    private func updateListening() {
        guard listening || remindersListening else {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            return
        }
        guard observers.isEmpty else { return }
        observers = Self.notifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    self?.refreshReminders()
                }
            }
        }
    }

    private func refreshReminders() {
        guard remindersListening else { return }
        remindersVersion += 1
        startRemindersRead()
    }

    private func startRemindersRead() {
        guard remindersListening, remindersTask == nil else { return }
        let version = remindersVersion
        remindersTask = Task { [reader] in
            var snapshot = await reader.readReminders()
            let cancelled = Task.isCancelled
            remindersTask = nil
            guard remindersListening else { return }
            if cancelled || version != remindersVersion {
                startRemindersRead()
                return
            }
            if snapshot.error == nil { snapshot.error = remindersActionError }
            publishReminders(snapshot)
        }
    }

    private func publishReminders(_ reminders: ShellReminders?) {
        guard reminders != self.reminders else { return }
        self.reminders = reminders
        onRemindersChange?(reminders)
    }

    func perform(_ command: ShellCalendarCommand) {
        switch command {
        case .authorize:
            Task { [reader] in
                await reader.requestAccess()
                self.refresh()
            }
        case .settings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        case let .open(event):
            if let event, let url = links[event] {
                NSWorkspace.shared.open(url)
            } else if let calendar = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                NSWorkspace.shared.openApplication(at: calendar, configuration: NSWorkspace.OpenConfiguration())
            }
        case let .month(delta):
            monthOffset = delta == 0 ? 0 : monthOffset + delta
            refresh()
        }
    }

    private func refresh() {
        guard listening else { return }
        version += 1
        let version = version
        let offset = monthOffset
        Task { [reader] in
            let reading = await reader.read(monthOffset: offset, now: Date())
            guard version == self.version, self.listening else { return }
            self.links = reading.links
            self.publish(reading.calendar)
        }
    }

    private func publish(_ calendar: ShellCalendar?) {
        guard calendar != self.calendar else { return }
        self.calendar = calendar
        onChange?(calendar)
    }
}

actor CalendarReader {
    struct Reading: Sendable {
        let calendar: ShellCalendar
        let links: [String: URL]
    }

    private static let agendaDays = 7
    private static let agendaLimit = 100

    private let store = EKEventStore()

    private struct ReminderFetch {
        let id: UUID
        let token: Any
        let continuation: CheckedContinuation<ShellReminders, Never>
    }

    private var reminderFetch: ReminderFetch?

    func requestReminderAccess() async -> ShellReminderResult {
        do {
            let granted = try await store.requestFullAccessToReminders()
            return granted ? .success : ShellReminderResult(
                error: "access_\(Self.name(of: EKEventStore.authorizationStatus(for: .reminder)))"
            )
        } catch {
            return ShellReminderResult(error: "authorize_failed: \(String(error.localizedDescription.prefix(512)))")
        }
    }

    func completeReminder(_ id: String) -> ShellReminderResult {
        ShellReminderResult.complete(id: id, access: EKEventStore.authorizationStatus(for: .reminder)) { id in
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
                throw ShellReminderError.missing
            }
            guard reminder.calendar.allowsContentModifications else { throw ShellReminderError.readOnly }
            guard !reminder.isCompleted else { return }
            reminder.isCompleted = true
            do {
                try store.save(reminder, commit: true)
            } catch {
                reminder.rollback()
                throw error
            }
        }
    }

    func readReminders() async -> ShellReminders {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .fullAccess else { return ShellReminders(access: Self.name(of: status)) }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: ShellReminders(access: "full", error: "cancelled"))
                    return
                }
                if let previous = reminderFetch { cancelReminderFetch(previous.id) }
                let predicate = store.predicateForIncompleteReminders(
                    withDueDateStarting: nil, ending: nil, calendars: nil
                )
                let complete: @Sendable ([EKReminder]?) -> Void = { [weak self] reminders in
                    let snapshot = Self.reminderSnapshot(reminders)
                    Task { await self?.finishReminderFetch(id, snapshot: snapshot) }
                }
                let token = store.fetchReminders(matching: predicate, completion: complete)
                reminderFetch = ReminderFetch(id: id, token: token, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelReminderFetch(id) }
        }
    }

    private func finishReminderFetch(_ id: UUID, snapshot: ShellReminders) {
        guard let pending = reminderFetch, pending.id == id else { return }
        reminderFetch = nil
        let access = Self.name(of: EKEventStore.authorizationStatus(for: .reminder))
        pending.continuation.resume(returning: access == "full" ? snapshot : ShellReminders(access: access))
    }

    private func cancelReminderFetch(_ id: UUID) {
        guard let pending = reminderFetch, pending.id == id else { return }
        reminderFetch = nil
        store.cancelFetchRequest(pending.token)
        pending.continuation.resume(returning: ShellReminders(access: "full", error: "cancelled"))
    }

    private nonisolated static func reminderSnapshot(_ reminders: [EKReminder]?) -> ShellReminders {
        guard let reminders else { return ShellReminders(access: "full", error: "read_failed") }
        let calendar = Calendar.autoupdatingCurrent
        return ShellReminders.bounded(reminders.lazy.filter { !$0.isCompleted }.map { reminder in
            let components = reminder.dueDateComponents
            let due = components.flatMap { ($0.calendar ?? calendar).date(from: $0) }
            return ShellReminder(
                id: reminder.calendarItemIdentifier,
                title: reminder.title ?? "",
                list: reminder.calendar.title,
                color: Self.hex(reminder.calendar.cgColor),
                due: due?.timeIntervalSince1970,
                allDay: components.map { $0.hour == nil && $0.minute == nil && $0.second == nil } ?? false,
                priority: reminder.priority,
                canComplete: reminder.calendar.allowsContentModifications
            )
        })
    }

    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            Log.shell.error("Calendar access was not granted: \(error)")
        }
    }

    func read(monthOffset: Int, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Reading {
        let status = EKEventStore.authorizationStatus(for: .event)
        var result = ShellCalendar(access: Self.name(of: status))
        let today = calendar.startOfDay(for: now)
        guard let shown = calendar.date(byAdding: .month, value: monthOffset, to: today),
              let month = calendar.dateInterval(of: .month, for: shown)
        else {
            return Reading(calendar: result, links: [:])
        }
        var marked: Set<Int> = []
        var links: [String: URL] = [:]
        if status == .fullAccess {
            marked = markedDays(in: month, calendar: calendar)
            (result.events, links) = agenda(from: today, now: now, calendar: calendar)
        }
        result.month = Self.month(month, now: now, marked: marked, calendar: calendar)
        return Reading(calendar: result, links: links)
    }

    private func markedDays(in month: DateInterval, calendar: Calendar) -> Set<Int> {
        var marked: Set<Int> = []
        for event in events(from: month.start, to: month.end) {
            var day = max(calendar.startOfDay(for: event.startDate), month.start)
            let until = max(min(event.endDate, month.end), day.addingTimeInterval(1))
            while day < until {
                marked.insert(calendar.component(.day, from: day))
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return marked
    }

    private func agenda(
        from today: Date,
        now: Date,
        calendar: Calendar
    ) -> (events: [ShellCalendarEvent], links: [String: URL]) {
        guard let end = calendar.date(byAdding: .day, value: Self.agendaDays, to: today) else { return ([], [:]) }
        let time = DateFormatter()
        time.timeStyle = .short
        time.dateStyle = .none
        let dayLabel = DateFormatter()
        dayLabel.dateStyle = .medium
        dayLabel.timeStyle = .none
        dayLabel.doesRelativeDateFormatting = true
        var events: [ShellCalendarEvent] = []
        var links: [String: URL] = [:]
        for event in self.events(from: today, to: end).filter({ $0.endDate > now }).prefix(Self.agendaLimit) {
            let id = "\(event.calendarItemIdentifier)@\(Int(event.startDate.timeIntervalSince1970))"
            links[id] = Self.link(to: event)
            events.append(ShellCalendarEvent(
                id: id,
                title: event.title ?? "",
                calendar: event.calendar.title,
                color: Self.hex(event.calendar.cgColor),
                start: event.startDate.timeIntervalSince1970,
                end: event.endDate.timeIntervalSince1970,
                allDay: event.isAllDay,
                location: event.location.flatMap { $0.isEmpty ? nil : $0 },
                time: event.isAllDay ? "" : time.string(from: event.startDate),
                day: dayLabel.string(from: event.startDate)
            ))
        }
        return (events, links)
    }

    private static func month(
        _ month: DateInterval,
        now: Date,
        marked: Set<Int>,
        calendar: Calendar
    ) -> ShellCalendarMonth {
        let title = DateFormatter()
        title.setLocalizedDateFormatFromTemplate("MMMM y")
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let weekday = calendar.component(.weekday, from: month.start) - 1
        return ShellCalendarMonth(
            title: title.string(from: month.start),
            year: calendar.component(.year, from: month.start),
            month: calendar.component(.month, from: month.start),
            days: calendar.range(of: .day, in: .month, for: month.start)?.count ?? 0,
            offset: (weekday - first + 7) % 7,
            today: month.contains(now) ? calendar.component(.day, from: now) : 0,
            weekdays: Array(symbols[first...] + symbols[..<first]),
            marked: marked.sorted()
        )
    }

    private func events(from start: Date, to end: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { event in
                event.status != .canceled
                    && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }
    }

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

    private nonisolated static func hex(_ color: CGColor?) -> String {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let color = color?.converted(to: space, intent: .defaultIntent, options: nil),
              let components = color.components, components.count >= 3
        else {
            return "#8E8E93"
        }
        let bytes = components.prefix(3).map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }

    private static func link(to event: EKEvent) -> URL? {
        let item = event.calendarItemIdentifier
        guard event.hasRecurrenceRules else { return URL(string: "ical://ekevent/\(item)?method=show&options=more") }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return URL(string: "ical://ekevent/\(format.string(from: event.startDate))/\(item)?method=show&options=more")
    }
}
