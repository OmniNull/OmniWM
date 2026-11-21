// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Foundation

extension ShellNotificationAccessibility.Session {
    func showCenter() -> ShellNotificationActionOutcome {
        defer {
            stopObserving()
            releaseMenuBar()
        }
        do {
            enter("center")
            if #available(macOS 27.2, *) {
                try observe()
                guard try !retryAX({ try snapshot(includeItems: false).history }) else { return .dispatched }
                _ = try openHistory()
            } else {
                guard try !snapshot(includeItems: false).history else { return .dispatched }
                try pressClock(opening: true)
            }
            return .dispatched
        } catch let error as ShellNotificationAccessibility.ActionFailure {
            return error.outcome
        } catch {
            return .failed
        }
    }

    func openHistory() throws -> AXUIElement {
        if #available(macOS 27.2, *) {
            return try clickClock()
        }
        try pressClock(opening: true)
        didDispatchHistoryOpen = true
        return try waitForOpenedHistory()
    }

    func closeHistory() throws {
        guard #available(macOS 27.2, *) else {
            try pressClock(opening: false)
            return
        }
        guard CGPreflightPostEventAccess() else {
            throw ShellNotificationAccessibility.ActionFailure(outcome: .denied)
        }
        let key = CGKeyCode(kVK_Escape)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        else { throw ShellNotificationAccessibility.ActionFailure(outcome: .failed) }
        try check(false)
        for event in [down, up] {
            event.flags = []
            event.postToPid(notificationPID)
        }
        trace("native.history.escape")
    }

    private func pressClock(opening: Bool) throws {
        let clock = try clock(checkCancellation: opening)
        try check(opening)
        let result = AXUIElementPerformAction(clock, kAXPressAction as CFString)
        trace(opening ? "native.clock.open" : "native.clock.close", fields: "ax=\(result.rawValue)")
        guard result == .success else { throw ShellNotificationAccessibility.ActionFailure(outcome: .failed) }
    }

    private func clickClock() throws -> AXUIElement {
        guard CGPreflightPostEventAccess() else {
            throw ShellNotificationAccessibility.ActionFailure(outcome: .denied)
        }
        let clock = try clock()
        guard let frame = AXAttributeValue.rectValue(try copy(clock, "AXFrame")),
              frame.size.hasFinitePositiveDimensions(),
              frame.midX.isFinite, frame.midY.isFinite
        else { throw ShellNotificationAccessibility.ActionFailure(outcome: .unavailable) }
        let point = frame.center
        let coveringPanels = DispatchQueue.main.sync {
            Self.allowClockClicks(throughShellPanelsAt: point)
        }
        defer {
            if !coveringPanels.isEmpty {
                DispatchQueue.main.sync { coveringPanels.forEach { $0.setClockClickPassThrough(false) } }
            }
        }
        let clockReady = try waitForClock(clock, at: point, within: coveringPanels.isEmpty ? 0 : 0.25)
            || revealMenuBar(clock, at: point)
        guard clockReady,
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                  mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left
              ),
              let up = CGEvent(
                  mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left
              )
        else { throw ShellNotificationAccessibility.ActionFailure(outcome: .unavailable) }
        try check()
        let cursorBeforeClick = CGEvent(source: nil)?.location
        let hardwareMoveCount = CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved)
        defer {
            if let cursorBeforeClick, let cursor = CGEvent(source: nil)?.location,
               cursor.distanceSquared(to: point) <= 2,
               CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved) == hardwareMoveCount
            {
                CGWarpMouseCursorPosition(cursorBeforeClick)
            }
        }
        // The clock's AXPress skips ControlCenter's mouse-down path on macOS 27.2.
        source.localEventsSuppressionInterval = 0
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
        didDispatchHistoryOpen = true
        trace("native.clock.click")
        return try waitForOpenedHistory()
    }

    private func waitForOpenedHistory() throws -> AXUIElement {
        // A cancelled action still needs the window identity to restore the panel it opened.
        try waitUntil(checkCancellation: false) {
            try snapshot(includeItems: false, checkCancellation: false).historyWindow
        }
    }

    private func waitForClock(_ clock: AXUIElement, at point: CGPoint, within duration: TimeInterval) throws -> Bool {
        // WindowServer can take a moment to update the hit target after changing a panel's mouse routing.
        let hitDeadline = ProcessInfo.processInfo.systemUptime + duration
        return try waitUntil {
            if self.clockIsAtPoint(clock, point: point) { return true }
            return ProcessInfo.processInfo.systemUptime >= hitDeadline ? false : nil
        }
    }

    // An auto-hidden menu bar keeps the clock off screen, so a click would land on whatever is below it.
    private func revealMenuBar(_ clock: AXUIElement, at point: CGPoint) throws -> Bool {
        guard !holdsMenuBarAccess else { return false }
        let access = menuBarAccess
        holdsMenuBarAccess = DispatchQueue.main.sync { access(true) }
        trace("native.menuBar.reveal", fields: "held=\(holdsMenuBarAccess)")
        guard holdsMenuBarAccess else { return false }
        return try waitForClock(clock, at: point, within: 1)
    }

    func releaseMenuBar() {
        guard holdsMenuBarAccess else { return }
        holdsMenuBarAccess = false
        let access = menuBarAccess
        let restored = DispatchQueue.main.sync { access(false) }
        trace("native.menuBar.release", fields: "restored=\(restored)")
    }

    private func clockIsAtPoint(_ clock: AXUIElement, point: CGPoint) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
            == .success, let hit
        else { return false }
        return CFEqual(hit, clock)
    }

    @MainActor
    private static func allowClockClicks(throughShellPanelsAt quartzPoint: CGPoint) -> [ShellFocusPanel] {
        let point = ScreenCoordinateSpace.toAppKit(point: quartzPoint)
        let panels = (NSApp?.windows ?? []).compactMap { $0 as? ShellFocusPanel }.filter {
            $0.isVisible && $0.frame.contains(point)
        }
        panels.forEach { $0.setClockClickPassThrough(true) }
        return panels
    }
}
