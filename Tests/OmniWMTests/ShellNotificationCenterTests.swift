// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellNotificationCenterTests: XCTestCase {
    func testFailedCenterClickPreservesShellFocusAndShowsAnError() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let finished = expectation(description: "Notification Center rejected the request")
        let opened = expectation(description: "Notification Center accepted the retry")
        let outcomes = AsyncStream<ShellNotificationActionOutcome>.makeStream()
        defer { outcomes.continuation.finish() }
        let controller = ShellNotificationsController(
            url: directory.appendingPathComponent("db"),
            load: { _ in ShellNotificationsData(state: "accessDenied") },
            showCenter: {
                for await outcome in outcomes.stream {
                    (outcome == .dispatched ? opened : finished).fulfill()
                    return outcome
                }
                return .cancelled
            }
        )
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false), notifications: controller)
        let host = ShellWidgetHost(
            configDirectory: directory, resources: resources,
            world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
            onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
            onPopoutChange: {}, onTitleDemandChange: { _ in }
        )
        let widget = try ShellRenderedWidget("notifications")
        widget.set("settings") {
            $0.map(1)
            $0.key("native")
            $0.bool(true)
        }
        controller.onChange = { value in
            widget.set("notifications") { value.write(into: &$0) }
        }
        controller.setListening(true)
        defer { controller.setListening(false) }
        await controller.task?.value

        let focused = ShellWidgetSurface(scale: 2, resources: resources, directories: [])
        host.focusedSurface = focused
        try clickBell(widget, in: host)
        XCTAssertTrue(host.focusedSurface === focused, "The click must retain focus while the result is pending")
        XCTAssertFalse(controller.perform(.center), "A second click must wait for the in-flight request")
        outcomes.continuation.yield(.denied)
        await fulfillment(of: [finished], timeout: failureBound)
        XCTAssertTrue(host.focusedSurface === focused, "A failed request must retain focus")

        controller.refresh()
        await controller.task?.value
        let message = ShellLocalizer.string("Accessibility access is required for notification actions.", [])
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains(message), "The bell must explain the failed request")
        _ = widget.renderPopout()
        XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(message), "The list must explain the failed request")

        try clickBell(widget, in: host)
        XCTAssertTrue(host.focusedSurface === focused)
        outcomes.continuation.yield(.dispatched)
        await fulfillment(of: [opened], timeout: failureBound)
        XCTAssertNil(host.focusedSurface, "An accepted request hands focus to Notification Center")
        widget.render(ShellBarData())
        XCTAssertFalse(widget.strings().contains(message), "A successful retry clears the error")
    }

    private func clickBell(_ widget: ShellRenderedWidget, in host: ShellWidgetHost) throws {
        widget.render(ShellBarData())
        let button = try XCTUnwrap(widget.surface.layout.core.elements {
            ShellAction(widget.text.string($0.action)) == .notifications(.center)
        }.first)
        let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: button))
        let point = CGPoint(x: frame.midX, y: frame.midY)
        widget.surface.press(at: point)
        widget.surface.release(at: point)

        let state = ShellWidgetHost.WidgetState(name: "notifications", sourceURL: try XCTUnwrap(
            ShellConfig.bundledWidget("notifications")
        ))
        state.text = widget.text
        let key = ShellBarKey(monitor: .init(displayId: 1))
        host.perform(try XCTUnwrap(widget.events.last), view: .bar, key: key, for: state)
    }
}
