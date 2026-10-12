// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class PanelDismissalMonitorTests: XCTestCase {
    func testLocalEscapeDismissesAndIsConsumed() throws {
        let panel = makePanel()
        let monitor = PanelDismissalMonitor()
        var dismissals = 0
        monitor.start(panels: [panel], isExemptWindow: { _ in false }, onDismiss: { dismissals += 1 })
        defer { monitor.stop() }

        XCTAssertTrue(monitor.handleLocalEvent(try keyEvent(code: 53)))
        XCTAssertEqual(dismissals, 1)
    }

    func testNavigationKeyRemainsAvailableToPanel() throws {
        let panel = makePanel()
        let monitor = PanelDismissalMonitor()
        var dismissals = 0
        monitor.start(panels: [panel], isExemptWindow: { _ in false }, onDismiss: { dismissals += 1 })
        defer { monitor.stop() }

        XCTAssertFalse(monitor.handleLocalEvent(try keyEvent(code: 48)))
        XCTAssertEqual(dismissals, 0)
    }

    func testStoppedMonitorDoesNotDismissOrConsumeEscape() throws {
        let panel = makePanel()
        let monitor = PanelDismissalMonitor()
        var dismissals = 0
        monitor.start(panels: [panel], isExemptWindow: { _ in false }, onDismiss: { dismissals += 1 })

        monitor.stop()
        monitor.stop()

        XCTAssertFalse(monitor.handleLocalEvent(try keyEvent(code: 53)))
        XCTAssertEqual(dismissals, 0)
    }

    func testRestartUsesOnlyCurrentDismissalCallback() throws {
        let panel = makePanel()
        let monitor = PanelDismissalMonitor()
        var firstDismissals = 0
        var secondDismissals = 0
        monitor.start(panels: [panel], isExemptWindow: { _ in false }, onDismiss: { firstDismissals += 1 })
        monitor.start(panels: [panel], isExemptWindow: { _ in false }, onDismiss: { secondDismissals += 1 })
        defer { monitor.stop() }

        XCTAssertTrue(monitor.handleLocalEvent(try keyEvent(code: 53)))
        XCTAssertEqual(firstDismissals, 0)
        XCTAssertEqual(secondDismissals, 1)
    }

    func testLocalClicksAcceptEveryPanelAndExemptWindowButDismissOutsideWindow() throws {
        let root = makePanel()
        let submenu = makePanel(x: 300)
        let source = makePanel(x: 600)
        let outside = makePanel(x: 900)
        let monitor = PanelDismissalMonitor()
        var dismissals = 0
        monitor.start(
            panels: [root, submenu],
            isExemptWindow: { $0 === source },
            onDismiss: { dismissals += 1 }
        )
        defer { monitor.stop() }

        for window in [root, submenu, source] {
            XCTAssertFalse(monitor.handleLocalEvent(try mouseEvent(in: window)))
        }
        XCTAssertEqual(dismissals, 0)

        XCTAssertFalse(monitor.handleLocalEvent(try mouseEvent(in: outside)))
        XCTAssertEqual(dismissals, 1)
    }

    func testPointerInsideEitherPanelStaysOpenAndOutsideDismisses() {
        let root = makePanel()
        let submenu = makePanel(x: 300)
        let monitor = PanelDismissalMonitor()
        var dismissals = 0
        monitor.start(panels: [root, submenu], isExemptWindow: { _ in false }, onDismiss: { dismissals += 1 })
        defer { monitor.stop() }

        monitor.handlePointer(location: CGPoint(x: 100, y: 100))
        monitor.handlePointer(location: CGPoint(x: 400, y: 100))
        XCTAssertEqual(dismissals, 0)

        monitor.handlePointer(location: CGPoint(x: 700, y: 100))
        XCTAssertEqual(dismissals, 1)
    }

    func testShadowMarginDismissesForLocalAndGlobalClicksWhileContentStaysOpen() throws {
        let panel = makePanel(x: 300)
        let monitor = PanelDismissalMonitor()
        var dismissals = 0
        monitor.start(
            panels: [panel],
            isExemptWindow: { _ in false },
            containsPanelPoint: { panel, point in panel.frame.insetBy(dx: 10, dy: 10).contains(point) },
            onDismiss: { dismissals += 1 }
        )
        defer { monitor.stop() }

        let content = CGPoint(x: 100, y: 100)
        let margin = CGPoint(x: 5, y: 100)
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown] {
            XCTAssertFalse(monitor.handleLocalEvent(try mouseEvent(in: panel, at: content, type: type)))
        }
        monitor.handlePointer(location: panel.convertPoint(toScreen: content))
        XCTAssertEqual(dismissals, 0)

        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown] {
            XCTAssertTrue(monitor.handleLocalEvent(try mouseEvent(in: panel, at: margin, type: type)))
        }
        monitor.handlePointer(location: panel.convertPoint(toScreen: margin))
        XCTAssertEqual(dismissals, 3)

        monitor.start(panels: [panel], isExemptWindow: { _ in false }, onDismiss: { dismissals += 1 })
        XCTAssertFalse(monitor.handleLocalEvent(try mouseEvent(in: panel, at: margin)))
        monitor.handlePointer(location: panel.convertPoint(toScreen: margin))
        XCTAssertEqual(dismissals, 3)
    }

    func testMembershipUpdateAcceptsNewPanelAndRemovesClosedSubmenu() throws {
        let root = makePanel()
        let submenu = makePanel(x: 300)
        let monitor = PanelDismissalMonitor()
        var dismissals = 0
        monitor.start(panels: [root], isExemptWindow: { _ in false }, onDismiss: { dismissals += 1 })
        defer { monitor.stop() }

        monitor.updatePanels([root, submenu])

        monitor.handlePointer(location: CGPoint(x: 400, y: 100))
        XCTAssertFalse(monitor.handleLocalEvent(try mouseEvent(in: submenu)))
        XCTAssertEqual(dismissals, 0)

        monitor.updatePanels([root])

        monitor.handlePointer(location: CGPoint(x: 400, y: 100))
        XCTAssertFalse(monitor.handleLocalEvent(try mouseEvent(in: submenu)))
        XCTAssertEqual(dismissals, 2)
    }

    func testEscapeUsesSeparateCallbackWhileOutsideClickDismissesGroup() throws {
        let root = makePanel()
        let submenu = makePanel(x: 300)
        let monitor = PanelDismissalMonitor()
        var escapes = 0
        var dismissals = 0
        monitor.start(
            panels: [root, submenu],
            isExemptWindow: { _ in false },
            onEscape: {
                escapes += 1
                monitor.updatePanels([root])
            },
            onDismiss: { dismissals += 1 }
        )
        defer { monitor.stop() }

        XCTAssertTrue(monitor.handleLocalEvent(try keyEvent(code: 53)))
        XCTAssertEqual(escapes, 1)
        XCTAssertEqual(dismissals, 0)

        monitor.handlePointer(location: CGPoint(x: 700, y: 100))
        XCTAssertEqual(escapes, 1)
        XCTAssertEqual(dismissals, 1)

        monitor.stop()
        XCTAssertFalse(monitor.handleLocalEvent(try keyEvent(code: 53)))
        monitor.handlePointer(location: CGPoint(x: 700, y: 100))
        XCTAssertEqual(escapes, 1)
        XCTAssertEqual(dismissals, 1)
    }

    private func makePanel(x: CGFloat = 0) -> NonactivatingPanel {
        NonactivatingPanel(
            contentRect: CGRect(x: x, y: 0, width: 280, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    private func mouseEvent(
        in window: NSWindow, at point: CGPoint = CGPoint(x: 10, y: 10), type: NSEvent.EventType = .leftMouseDown
    ) throws -> NSEvent {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertTrue(event.window === window)
        return event
    }

    private func keyEvent(code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: code
        ))
    }
}
