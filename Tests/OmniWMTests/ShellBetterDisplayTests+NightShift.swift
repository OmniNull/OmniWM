// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import XCTest

extension ShellBetterDisplayTests {
    private var displayDemand: UInt64 {
        ShellDataKey.brightness.bit | ShellDataKey.nightShift.bit | ShellDataKey.betterDisplay.bit
    }

    private func nightShiftAction(
        _ widget: ShellRenderedWidget, for snapshot: ShellWidgetData, status: String
    ) throws -> ShellAction {
        let native = try XCTUnwrap(snapshot.nightShift)
        widget.set("brightness") { snapshot.brightness?.write(into: &$0) ?? $0.null() }
        widget.set("nightShift") { native.write(into: &$0) }
        widget.set("betterDisplay") { snapshot.betterDisplay?.write(into: &$0) ?? $0.null() }
        let tree = widget.renderPopout()
        let index = try XCTUnwrap(tree.firstIndex { widget.text.string($0.content.action).contains("night-shift ") })
        let card = tree[index]
        let labels = tree[(index + 1) ..< Int(card.subtreeEnd)].filter { $0.kind == .label }
            .map { widget.text.string($0.content.text) }
        XCTAssertTrue(labels.contains(ShellLocalizer.string(status, [])), "Expected \(status) in \(labels)")
        return try XCTUnwrap(ShellAction(widget.text.string(card.content.action)))
    }

    func testFirstNativeNightShiftActionAfterBetterDisplayExitsTurnsOffManagedTint() async throws {
        let fixture = Fixture()
        fixture.pid = 42
        fixture.supportsFirstDisplay = false
        let feed = fixture.startDisplayFeed(demand: displayDemand)
        defer { feed.stop() }
        let devices = try XCTUnwrap(feed.devices)
        let widget = try displaysWidget()
        await fixture.updates.changes.wait { feed.current.betterDisplay?.nightShift.available == true }
        XCTAssertFalse(try XCTUnwrap(feed.current.betterDisplay).displays.contains(where: \.available))
        let nativeReads = fixture.nativeNightShiftReads
        guard case let .betterDisplay(managed) = try nightShiftAction(widget, for: feed.current, status: "Off") else {
            return XCTFail("Expected the BetterDisplay Night Shift control")
        }
        let write = try XCTUnwrap(devices.betterDisplay.perform(managed))
        await write.value
        await fixture.updates.changes.wait { feed.current.betterDisplay?.nightShift.enabled == true }
        XCTAssertEqual(fixture.actions, [.nightShift(.on)])
        XCTAssertEqual(fixture.nativeNightShiftReads, nativeReads)

        XCTAssertEqual(feed.current.nightShift?.enabled, false)
        fixture.deliveries.removeAll()
        fixture.pid = nil
        fixture.applicationsChanged?()
        let fallback = try XCTUnwrap(fixture.deliveries.first { $0.betterDisplay?.running == false })
        XCTAssertTrue(fixture.nativeNightShiftWrites.isEmpty)
        guard case let .nightShift(command) = try nightShiftAction(widget, for: fallback, status: "On") else {
            return XCTFail("Expected the native Night Shift control")
        }
        XCTAssertEqual(command, .off)
        XCTAssertTrue(devices.nightShift.perform(command))
        XCTAssertEqual(fixture.nativeNightShiftWrites, [false])
        XCTAssertFalse(fixture.nightShift)
    }

    func testReopeningDisplaysPublishesBothNativeControlsTogether() async throws {
        let fixture = Fixture()
        fixture.pid = 42
        let feed = fixture.startDisplayFeed(demand: displayDemand)
        defer { feed.stop() }
        await fixture.updates.changes.wait { feed.current.betterDisplay?.nightShift.available == true }
        XCTAssertEqual(feed.current.betterDisplay?.displays.first?.available, true)
        let remaining = ShellDataKey.brightness.bit | ShellDataKey.nightShift.bit
        feed.setDemand(remaining, cadence: .of([(remaining, nil)]))
        XCTAssertNil(fixture.applicationsChanged)
        XCTAssertEqual(feed.current.brightness?.value, 50)
        XCTAssertEqual(feed.current.nightShift?.enabled, false)

        fixture.level = 0.75
        fixture.nightShift = true
        fixture.pid = nil
        fixture.deliveries.removeAll()
        feed.setDemand(displayDemand, cadence: .of([(displayDemand, nil)]))
        let fallbacks = fixture.deliveries.filter { $0.betterDisplay?.nightShift.available != true }
        for fallback in fallbacks {
            XCTAssertEqual(fallback.brightness?.value, 75)
            XCTAssertEqual(fallback.nightShift, .init(available: true, enabled: true))
        }
        let first = try XCTUnwrap(fallbacks.first)
        XCTAssertEqual(try nightShiftAction(displaysWidget(), for: first, status: "On"), .nightShift(.off))
        XCTAssertTrue(fixture.nativeNightShiftWrites.isEmpty)
        XCTAssertTrue(fixture.actions.isEmpty)
    }

    func testLosingOnlyNightShiftSupportReadsExternalChange() async throws {
        let fixture = Fixture()
        fixture.pid = 42
        fixture.nightShift = true
        let feed = fixture.startDisplayFeed(demand: displayDemand)
        defer { feed.stop() }
        let widget = try displaysWidget()
        await fixture.updates.changes.wait { feed.current.betterDisplay?.nightShift.available == true }
        XCTAssertEqual(try nightShiftAction(widget, for: feed.current, status: "On"), .betterDisplay(.nightShift(.off)))
        let slidersBefore = try sliders(widget, for: feed.current).map(\.content.value)
        let brightnessReads = fixture.nativeReads

        fixture.deliveries.removeAll()
        fixture.nightShift = false // Changed externally, without a native notification.
        fixture.supportsNightShift = false
        fixture.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await fixture.updates.changes.wait { feed.current.betterDisplay?.nightShift.available == false }
        let fallback = try XCTUnwrap(fixture.deliveries.first { $0.betterDisplay?.nightShift.available == false })
        XCTAssertEqual(fallback.betterDisplay?.running, true)
        XCTAssertEqual(fallback.betterDisplay?.displays.first?.available, true)
        XCTAssertEqual(try sliders(widget, for: fallback).map(\.content.value), slidersBefore)
        XCTAssertEqual(fixture.nativeReads, brightnessReads)
        XCTAssertTrue(fixture.nativeNightShiftWrites.isEmpty)
        guard case let .nightShift(command) = try nightShiftAction(widget, for: fallback, status: "Off") else {
            return XCTFail("Expected the native Night Shift control")
        }
        XCTAssertEqual(command, .on)
        let devices = try XCTUnwrap(feed.devices)
        XCTAssertTrue(devices.nightShift.perform(command))
        XCTAssertEqual(fixture.nativeNightShiftWrites, [true])
        XCTAssertTrue(fixture.nightShift)
        XCTAssertTrue(fixture.actions.isEmpty)
    }
}
