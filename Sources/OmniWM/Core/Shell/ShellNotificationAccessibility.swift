// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

actor ShellNotificationAccessibility {
    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.notification-actions", qos: .utility)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func perform(
        _ request: ShellNotificationActionRequest,
        notificationPID: pid_t,
        menuPID: pid_t
    ) -> ShellNotificationActionOutcome {
        let trusted = AXIsProcessTrusted()
        ShellNotificationTrace.record(
            "native.begin", target: request.id,
            fields: "trusted=\(trusted) notificationPID=\(notificationPID) menuPID=\(menuPID)"
        )
        guard trusted else { return .denied }
        let session = Session(request: request, notificationPID: notificationPID, menuPID: menuPID)
        return session.perform()
    }

    func dismissAll(
        _ requests: [ShellNotificationActionRequest],
        notificationPID: pid_t,
        menuPID: pid_t,
        progress: @Sendable (ShellNotificationActionOutcome) -> Void
    ) -> ShellNotificationActionOutcome {
        guard let first = requests.first else { return .dispatched }
        guard AXIsProcessTrusted() else { return .denied }
        let session = Session(request: first, notificationPID: notificationPID, menuPID: menuPID)
        return ShellNotificationDismissAll.perform(
            requests,
            begin: { session.prepare() },
            dismiss: { request in
                session.request = request
                session.deadline = ProcessInfo.processInfo.systemUptime + 6
                return session.execute()
            },
            finish: { session.finish($0) },
            progress: progress
        )
    }
}

extension ShellNotificationAccessibility {
    struct ActionFailure: Error {
        let outcome: ShellNotificationActionOutcome
    }

    fileprivate struct ExpiredElement: Error {}

    struct Snapshot {
        var historyWindow: AXUIElement?
        var history: Bool {
            historyWindow != nil
        }

        var items: [UUID: [AXUIElement]] = [:]
    }

    final class Session {
        var request: ShellNotificationActionRequest
        let app: AXUIElement
        let menu: AXUIElement
        let notificationPID: pid_t
        var observer: AXObserver?
        var openedHistory = false
        var openedWindow: AXUIElement?
        var deadline = ProcessInfo.processInfo.systemUptime + 6
        var stage = "initial"

        init(request: ShellNotificationActionRequest, notificationPID: pid_t, menuPID: pid_t) {
            self.request = request
            self.notificationPID = notificationPID
            app = AXUIElementCreateApplication(notificationPID)
            menu = AXUIElementCreateApplication(menuPID)
            AXUIElementSetMessagingTimeout(app, 0.25)
            AXUIElementSetMessagingTimeout(menu, 0.25)
        }

        func trace(_ event: StaticString, fields: @autoclosure () -> String = "") {
            ShellNotificationTrace.record(event, target: request.id, fields: "stage=\(stage) \(fields())")
        }

        func enter(_ stage: String) {
            self.stage = stage
            trace("native.stage")
        }

        func perform() -> ShellNotificationActionOutcome {
            finish(prepare() ?? execute())
        }

        func prepare() -> ShellNotificationActionOutcome? {
            do {
                try check()
                enter("observe")
                try observe()
                enter("history")
                if try !snapshot().history {
                    let clock = try clock()
                    try check()
                    let result = AXUIElementPerformAction(clock, kAXPressAction as CFString)
                    trace("native.clock.open", fields: "ax=\(result.rawValue)")
                    guard result == .success else {
                        throw ActionFailure(outcome: .failed)
                    }
                    openedHistory = true
                    openedWindow = try wait { $0.history }.historyWindow
                }
                return nil
            } catch let error as ActionFailure {
                return error.outcome
            } catch is ExpiredElement {
                return .notFound
            } catch {
                return .failed
            }
        }

        func execute() -> ShellNotificationActionOutcome {
            do {
                try check()
                enter("individual")
                switch request.operation {
                case .dismiss:
                    return try dismiss()
                case let .reply(text, title, sendTitle):
                    let target = try individual()
                    try reply(target, text: text, title: title, sendTitle: sendTitle)
                }
                return .dispatched
            } catch let error as ActionFailure {
                return error.outcome
            } catch is ExpiredElement {
                return .notFound
            } catch {
                return .failed
            }
        }

        func finish(_ result: ShellNotificationActionOutcome) -> ShellNotificationActionOutcome {
            defer {
                if let observer {
                    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
                }
            }
            var outcome = result
            trace("native.effect.end", fields: "outcome=\(outcome.rawValue) openedHistory=\(openedHistory)")
            if openedHistory {
                enter("restoreHistory")
                do { try restoreHistory() }
                catch { outcome = outcome == .dispatched ? .dispatchedPanelOpen : .failedPanelOpen }
            }
            trace("native.end", fields: "outcome=\(outcome.rawValue)")
            return outcome
        }

        func restoreHistory() throws {
            deadline = ProcessInfo.processInfo.systemUptime + 1
            let current = try snapshot(includeItems: false, checkCancellation: false)
            guard let window = openedWindow ?? current.historyWindow else { return }
            func containsWindow() throws -> Bool {
                let windows = try copy(app, kAXWindowsAttribute, checkCancellation: false) as? [AXUIElement] ?? []
                return windows.contains { CFEqual($0, window) }
            }
            guard try containsWindow() else { return }
            if let active = current.historyWindow, CFEqual(active, window) {
                let clock = try clock(checkCancellation: false)
                let result = AXUIElementPerformAction(clock, kAXPressAction as CFString)
                trace("native.clock.close", fields: "ax=\(result.rawValue)")
                guard result == .success else {
                    throw ActionFailure(outcome: .failed)
                }
            }
            while try containsWindow() {
                try check(false)
                let result = CFRunLoopRunInMode(
                    .defaultMode,
                    max(0, deadline - ProcessInfo.processInfo.systemUptime),
                    true
                )
                if result == .timedOut { throw ActionFailure(outcome: .timeout) }
                if result == .finished { throw ActionFailure(outcome: .unavailable) }
            }
            trace("native.history.retired")
        }

        func observe() throws {
            var observer: AXObserver?
            let result = AXObserverCreate(notificationPID, { _, _, _, _ in }, &observer)
            trace("native.observer.create", fields: "ax=\(result.rawValue)")
            guard result == .success,
                  let observer
            else { throw ActionFailure(outcome: .unavailable) }
            self.observer = observer
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            for name in [
                kAXWindowCreatedNotification,
                kAXLayoutChangedNotification,
                kAXUIElementDestroyedNotification
            ] {
                let result = AXObserverAddNotification(observer, app, name as CFString, nil)
                trace("native.observer.subscribe", fields: "notification=\(name) ax=\(result.rawValue)")
                guard result == .success else {
                    throw ActionFailure(outcome: .unavailable)
                }
            }
        }

        func check(_ checkCancellation: Bool = true) throws {
            if checkCancellation, Task.isCancelled { throw ActionFailure(outcome: .cancelled) }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw ActionFailure(outcome: .timeout) }
        }

        func copy(_ element: AXUIElement, _ name: String, checkCancellation: Bool = true) throws -> CFTypeRef? {
            try check(checkCancellation)
            var result: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            if status != .success, status != .noValue, status != .attributeUnsupported {
                trace("native.attribute.error", fields: "attribute=\(name) ax=\(status.rawValue)")
            }
            switch status {
            case .success: return result
            case .noValue,
                 .attributeUnsupported: return nil
            case .invalidUIElement: throw ExpiredElement()
            default: throw ActionFailure(outcome: .failed)
            }
        }

        func string(_ element: AXUIElement, _ name: String) throws -> String? {
            try copy(element, name) as? String
        }

        func children(_ element: AXUIElement, checkCancellation: Bool = true) throws -> [AXUIElement] {
            try copy(element, kAXChildrenAttribute, checkCancellation: checkCancellation) as? [AXUIElement] ?? []
        }

        func snapshot(includeItems: Bool = true, checkCancellation: Bool = true) throws -> Snapshot {
            var result = Snapshot()
            var remaining = 2048
            func visit(_ element: AXUIElement, _ depth: Int, window: AXUIElement, inList: Bool = false) throws {
                do {
                    try check(checkCancellation)
                    guard depth <= 24, remaining > 0 else { throw ActionFailure(outcome: .unsupported) }
                    remaining -= 1
                    let role = try copy(element, kAXRoleAttribute, checkCancellation: checkCancellation) as? String
                    if inList, role != kAXGroupRole { return }
                    var identifier: String?
                    if role == kAXGroupRole || role == kAXButtonRole {
                        identifier = try copy(
                            element,
                            kAXIdentifierAttribute,
                            checkCancellation: checkCancellation
                        ) as? String
                    }
                    if identifier == "widget-editor-button" { result.historyWindow = window }
                    if identifier == "AXNotificationListItems", !includeItems { return }
                    if inList {
                        if let identifier, let id = UUID(uuidString: identifier), request.peers.contains(id) {
                            result.items[id, default: []].append(element)
                        }
                        return
                    }
                    guard role == kAXGroupRole || role == kAXWindowRole || role == kAXScrollAreaRole else { return }
                    for child in try children(element, checkCancellation: checkCancellation) {
                        try visit(child, depth + 1, window: window, inList: identifier == "AXNotificationListItems")
                    }
                } catch is ExpiredElement {
                    return
                }
            }
            let windows = try copy(app, kAXWindowsAttribute, checkCancellation: checkCancellation) as? [AXUIElement] ??
                []
            for window in windows { try visit(window, 0, window: window) }
            trace(
                "native.snapshot",
                fields: "history=\(result.history) windows=\(windows.count) visited=\(2048 - remaining)"
                    + " peerCapsules=\(result.items.count) targetMatches=\(result.items[request.id]?.count ?? 0) includeItems=\(includeItems)"
            )
            return result
        }

        func wait(_ ready: (Snapshot) throws -> Bool) throws -> Snapshot {
            while true {
                try check()
                let value = try snapshot()
                if try ready(value) { return value }
                let result = CFRunLoopRunInMode(
                    .defaultMode,
                    max(0, deadline - ProcessInfo.processInfo.systemUptime),
                    true
                )
                trace("native.wait.wake", fields: "result=\(result.rawValue)")
                if result == .timedOut { throw ActionFailure(outcome: .timeout) }
                if result == .finished { throw ActionFailure(outcome: .unavailable) }
            }
        }

        func clock(checkCancellation: Bool = true) throws -> AXUIElement {
            guard let raw = try copy(menu, kAXExtrasMenuBarAttribute, checkCancellation: checkCancellation),
                  CFGetTypeID(raw) == AXUIElementGetTypeID()
            else { throw ActionFailure(outcome: .unavailable) }
            let bar = unsafeDowncast(raw as AnyObject, to: AXUIElement.self)
            var matches: [AXUIElement] = []
            for container in try children(bar, checkCancellation: checkCancellation) {
                for element in [container] + (try children(container, checkCancellation: checkCancellation))
                    where try copy(element, kAXIdentifierAttribute, checkCancellation: checkCancellation) as? String
                    == "com.apple.menuextra.clock"
                {
                    matches.append(element)
                }
            }
            guard matches.count == 1 else { throw ActionFailure(outcome: .ambiguous) }
            trace("native.clock.found", fields: "matches=\(matches.count)")
            return matches[0]
        }

        func actions(_ element: AXUIElement) throws -> [String] {
            try check()
            var names: CFArray?
            let result = AXUIElementCopyActionNames(element, &names)
            trace("native.actions.read", fields: "ax=\(result.rawValue)")
            guard result == .success else {
                throw ActionFailure(outcome: .failed)
            }
            return names as? [String] ?? []
        }
    }
}

extension ShellNotificationAccessibility.Session {
    func expand(_ target: AXUIElement) throws {
        enter("details")
        let names = try actions(target)
        let details = names.filter { $0.hasPrefix("Name:Show Details\n") }
        trace("native.details.matches", fields: "actions=\(names.count) matches=\(details.count)")
        guard details.count <= 1 else { throw ShellNotificationAccessibility.ActionFailure(outcome: .ambiguous) }
        if let detail = details.first {
            try check()
            let result = AXUIElementPerformAction(target, detail as CFString)
            trace("native.details.press", fields: "ax=\(result.rawValue)")
            guard result == .success else {
                throw ShellNotificationAccessibility.ActionFailure(outcome: .failed)
            }
        }
    }

    func exactTarget() throws -> AXUIElement {
        let current = try snapshot()
        guard let matches = current.items[request.id]
        else { throw ShellNotificationAccessibility.ActionFailure(outcome: .notFound) }
        guard matches.count == 1 else { throw ShellNotificationAccessibility.ActionFailure(outcome: .ambiguous) }
        guard try string(matches[0], kAXSubroleAttribute) == "AXNotificationCenterBanner" else {
            throw ShellNotificationAccessibility.ActionFailure(outcome: .unsupported)
        }
        return matches[0]
    }

    func controls(
        _ target: AXUIElement,
        role: String,
        identifier: String? = nil,
        title: String? = nil
    ) throws -> [AXUIElement] {
        var result: [AXUIElement] = []
        var remaining = 128
        func visit(_ element: AXUIElement, _ depth: Int) throws {
            do {
                guard depth < 12,
                      remaining > 0 else { throw ShellNotificationAccessibility.ActionFailure(outcome: .unsupported) }
                remaining -= 1
                if try string(element, kAXRoleAttribute) == role,
                   try identifier.map({ try string(element, kAXIdentifierAttribute) == $0 }) ?? true,
                   try title.map({ try string(element, kAXDescriptionAttribute) == $0 }) ?? true
                { result.append(element) }
                for child in try children(element) { try visit(child, depth + 1) }
            } catch is ShellNotificationAccessibility.ExpiredElement {
                return
            }
        }
        try visit(target, 0)
        return result
    }

    func dismiss() throws -> ShellNotificationActionOutcome {
        try ShellNotificationAction.dismiss(
            resolve: { try individual() },
            actions: { target in
                enter("dismiss")
                let names = try actions(target)
                let matches = names.lazy.filter { $0.hasPrefix("Name:Close\n") }.count
                trace("native.dismiss.controls", fields: "matches=\(matches)")
                return names
            },
            press: { target, close in
                try check()
                let result = AXUIElementPerformAction(target, close as CFString)
                trace("native.dismiss.press", fields: "ax=\(result.rawValue)")
                return result == .success
            }
        )
    }

    func reply(_ target: AXUIElement, text: String, title: String, sendTitle: String) throws {
        try expand(target)
        enter("reply")
        let current = try exactTarget()
        let buttons = try controls(current, role: kAXButtonRole, title: title)
        trace("native.reply.controls", fields: "matches=\(buttons.count) textBytes=\(text.utf8.count)")
        guard buttons.count == 1 else { throw ShellNotificationAccessibility.ActionFailure(outcome: .ambiguous) }
        try check()
        let opened = AXUIElementPerformAction(buttons[0], kAXPressAction as CFString)
        trace("native.reply.open", fields: "ax=\(opened.rawValue)")
        guard opened == .success || opened == .failure
        else { throw ShellNotificationAccessibility.ActionFailure(outcome: .failed) }
        var field: AXUIElement?
        var send: AXUIElement?
        enter("composer")
        _ = try wait { value in
            guard let matches = value.items[self.request.id], matches.count == 1 else { return false }
            let fields = try self.controls(matches[0], role: kAXTextAreaRole)
            let sends = try self.controls(matches[0], role: kAXButtonRole, title: sendTitle)
            self.trace("native.composer.controls", fields: "fields=\(fields.count) sends=\(sends.count)")
            guard fields.count <= 1,
                  sends.count <= 1 else { throw ShellNotificationAccessibility.ActionFailure(outcome: .ambiguous) }
            guard let input = fields.first, let button = sends.first else { return false }
            var settable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(input, kAXValueAttribute as CFString, &settable)
            self.trace("native.composer.settable", fields: "ax=\(status.rawValue) settable=\(settable.boolValue)")
            guard status == .success,
                  settable.boolValue
            else { throw ShellNotificationAccessibility.ActionFailure(outcome: .unsupported) }
            field = input
            send = button
            return true
        }
        guard let field, let send else { throw ShellNotificationAccessibility.ActionFailure(outcome: .failed) }
        try check()
        let written = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
        trace("native.reply.write", fields: "ax=\(written.rawValue)")
        guard written == .success else { throw ShellNotificationAccessibility.ActionFailure(outcome: .failed) }
        let matched = try string(field, kAXValueAttribute) == text
        trace("native.reply.readback", fields: "matched=\(matched)")
        guard matched
        else { throw ShellNotificationAccessibility.ActionFailure(outcome: .failed) }
        _ = try exactTarget()
        try check()
        enter("send")
        let sent = AXUIElementPerformAction(send, kAXPressAction as CFString)
        trace("native.reply.send", fields: "ax=\(sent.rawValue)")
        guard sent == .success else {
            throw ShellNotificationAccessibility.ActionFailure(outcome: .failed)
        }
    }
}
