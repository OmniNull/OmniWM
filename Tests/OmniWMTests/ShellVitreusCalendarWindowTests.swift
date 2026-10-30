// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellVitreusCalendarWindowTests: XCTestCase {
    private let drawers = ShellVitreusDrawerTests()
    private typealias Fixture = ShellVitreusDrawerTests.Fixture

    private func fixture() throws -> Fixture {
        let fixture = try drawers.fixture()
        fixture.widget.set("clock") { $0.string("3:00 PM") }
        fixture.widget.set("date") { $0.string("Thu 29") }
        drawers.show(fixture)
        drawers.trigger(fixture, "drawer-calendar")
        return fixture
    }

    private func frame(_ fixture: Fixture, _ key: String) throws -> CGRect {
        try VitreusFixture.frame(fixture.widget, key: key)
    }

    private func element(_ fixture: Fixture, _ key: String) throws -> ElementHandle {
        try VitreusFixture.element(fixture.widget, key: key)
    }

    private func checkRenderBudget(_ fixture: Fixture) {
        var stats = omni_render_stats()
        var error = [CChar](repeating: 0, count: 256)
        XCTAssertEqual(
            omni_instance_render(
                fixture.widget.instance,
                OMNI_VIEW_BAR,
                ShellWidgetPackage.renderBudget,
                &stats,
                &error,
                error.count
            ),
            OMNI_OK,
            String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        )
        print("CALENDAR-WINDOW-RENDER cpu_ns=\(stats.cpu_ns) encode_ns=\(stats.encode_cpu_ns)")
    }

    private func move(_ fixture: Fixture, to origin: CGPoint, check: (() throws -> Void)? = nil) throws {
        let target = try frame(fixture, "drawer-content-calendar")
        let grip = try frame(fixture, "window-grip-calendar")
        let start = CGPoint(x: grip.midX, y: grip.midY)
        let end = CGPoint(x: start.x + origin.x - target.minX, y: start.y + origin.y - target.minY)
        let handle = try element(fixture, "drawer-content-calendar")
        let source = try element(fixture, "window-grip-calendar")
        VitreusFixture.grab(fixture.widget, at: start, to: end, on: fixture.monitor)
        XCTAssertEqual(fixture.widget.surface.manipulation?.target, handle)
        XCTAssertEqual(try element(fixture, "drawer-content-calendar"), handle)
        XCTAssertEqual(try element(fixture, "window-grip-calendar"), source)
        try check?()
        VitreusFixture.drop(fixture.widget, at: end, on: fixture.monitor)
        fixture.widget.surface.finishSettle()
        XCTAssertEqual(try element(fixture, "drawer-content-calendar"), handle)
        XCTAssertEqual(try element(fixture, "window-grip-calendar"), source)
        XCTAssertNil(fixture.widget.surface.manipulation)
    }

    func testCalendarPullsOutFloatsSticksRightAndReturnsHomeWithoutReplacingItsGrip() throws {
        let fixture = try fixture()
        let home = try frame(fixture, "drawer-content-calendar")
        try move(fixture, to: CGPoint(x: 200, y: 300))
        var shown = try frame(fixture, "drawer-content-calendar")
        XCTAssertEqual(shown.minX, 200, accuracy: 0.01)
        XCTAssertEqual(shown.minY, 300, accuracy: 0.01)
        try move(fixture, to: CGPoint(x: 1920 - shown.width - 20, y: 250))
        shown = try frame(fixture, "drawer-content-calendar")
        XCTAssertEqual(shown.maxX, 1920, accuracy: 0.01)
        XCTAssertEqual(shown.minY, 250, accuracy: 0.01)
        let glass = try element(fixture, "drawer")
        XCTAssertNotNil(fixture.widget.surface.boundShapes[glass])
        XCTAssertEqual(fixture.widget.surface.boundTarget(of: glass), try element(fixture, "drawer-content-calendar"))
        let bulge = try drawers.morph(fixture, "calendar-window-bulge")
        XCTAssertEqual(bulge.source?.target, VitreusFixture.key("drawer-content-calendar"))
        XCTAssertEqual(bulge.source?.contact, true)
        try move(fixture, to: CGPoint(x: home.minX + 10, y: home.minY + 10))
        ShellVitreusMediaCardTests.assertRect(try frame(fixture, "drawer-content-calendar"), home)
        XCTAssertEqual(
            fixture.widget.surface.followedTarget(of: glass),
            try element(fixture, "drawer-content-calendar")
        )
        XCTAssertFalse(drawers.has(fixture, "calendar-window-bulge"))
    }

    private func editReminder(_ fixture: Fixture, text: String) throws
        -> (ShellTextInput, ShellManipulationSurfaceTests.Window)
    {
        let widget = fixture.widget
        let inputHandle = try element(fixture, "calendar-entry-1")
        let input = try XCTUnwrap(widget.surface.textInputs[inputHandle])
        let window = ShellManipulationSurfaceTests.Window()
        window.acceptsDeclaredFocus = true
        window.setContentSize(widget.surface.size)
        window.contentView = widget.surface.view
        widget.surface.view.frame = CGRect(origin: .zero, size: widget.surface.size)
        widget.surface.focusDeclared(inputHandle)
        input.beganEditing()
        XCTAssertTrue(window.selectedResponder === input.responder)
        let change = widget.surface.layout.core.content(of: inputHandle).action
        var event = ShellEvent()
        event.text = text
        input.field?.stringValue = text
        widget.invoke(change, event: event)
        drawers.show(fixture)
        return (input, window)
    }

    func testClockRedocksOnceAndPreservesTheReminderEditorAndCommands() throws {
        let fixture = try fixture()
        let widget = fixture.widget
        let (input, window) = try editReminder(fixture, text: "Keep this draft")
        let inputHandle = input.handle
        defer { widget.surface.blurDeclaredFocus()
            window.contentView = nil
        }
        let home = try frame(fixture, "drawer-content-calendar")
        try move(fixture, to: CGPoint(x: 250, y: 300)) {
            XCTAssertTrue(widget.surface.textInputs[inputHandle] === input)
            XCTAssertTrue(window.selectedResponder === input.responder)
            XCTAssertEqual(input.view.alphaValue, 0)
        }
        let day = try frame(fixture, "calendar-day-2026-10-28")
        XCTAssertEqual(widget.surface.command(at: CGPoint(x: day.midX, y: day.midY)), "calendar day 2026-10-28")
        let reminder = try frame(fixture, "calendar-complete-reminder-1")
        XCTAssertEqual(
            widget.surface.command(at: CGPoint(x: reminder.midX, y: reminder.midY)),
            "reminders complete \"reminder-1\""
        )
        let clock = try frame(fixture, "bar-clock")
        XCTAssertEqual(
            widget.surface.command(at: CGPoint(x: clock.midX, y: clock.midY)),
            "shell trigger vitreus drawer-calendar " + VitreusFixture.bar(fixture.monitor).monitorId
        )
        drawers.trigger(fixture, "drawer-calendar")
        ShellVitreusMediaCardTests.assertRect(try frame(fixture, "drawer-content-calendar"), home)
        XCTAssertEqual(try element(fixture, "calendar-entry-1"), inputHandle)
        XCTAssertTrue(widget.surface.textInputs[inputHandle] === input)
        XCTAssertEqual(input.text, "Keep this draft")
        XCTAssertEqual(widget.text.string(widget.surface.layout.core.content(of: inputHandle).text), "Keep this draft")
        XCTAssertTrue(window.selectedResponder === input.responder)
        XCTAssertEqual(input.view.alphaValue, 1)
        let layout = widget.surface.layout
        for key in ["drawer-content-calendar", "window-grip-calendar", "drawer"] {
            XCTAssertEqual(
                layout.core.elements { _ in true }.count { layout.core.key(of: $0) == VitreusFixture.key(key) },
                1
            )
        }
        drawers.trigger(fixture, "drawer-calendar")
        XCTAssertFalse(drawers.has(fixture, "drawer-content-calendar"))
    }

    func testDetachedCalendarRemainsWhenAnotherDropdownOpensWithinShapeAndTargetBudgets() throws {
        let fixture = try fixture()
        let target = try element(fixture, "drawer-content-calendar")
        try move(fixture, to: CGPoint(x: 200, y: 300))
        drawers.trigger(fixture, "drawer-player")
        XCTAssertEqual(try element(fixture, "drawer-content-calendar"), target)
        XCTAssertTrue(drawers.has(fixture, "drawer-content-player"))
        XCTAssertFalse(drawers.has(fixture, "calendar-window-bulge"))
        XCTAssertTrue(drawers.has(fixture, "drawer-player"))
        var media = ShellMedia()
        media.title = "Song"
        media.artist = "Artist"
        media.bundle = "test.music"
        fixture.widget.set("media") { media.write(into: &$0) }
        drawers.trigger(fixture, "desk-open")
        let surface = fixture.widget.surface
        XCTAssertEqual(surface.manipulationTargets.count, 7)
        let layout = surface.layout
        let bodies = layout.core.elements { _ in true }.filter { layout.core.kind(of: $0) == .glass }
        let counts = bodies.map { body in
            layout.core.elements { _ in true }.count { layout.core.parent(of: $0) == body }
        }
        XCTAssertTrue(counts.allSatisfy { $0 <= 64 })
        print("CALENDAR-WINDOW-BUDGET targets=\(surface.manipulationTargets.count) shapes=\(counts)")
        checkRenderBudget(fixture)
    }
}
