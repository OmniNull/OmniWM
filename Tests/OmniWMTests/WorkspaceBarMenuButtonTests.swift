// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarMenuButtonTests: XCTestCase {
    func testMenuButtonIsTwentyFourPointsOnATwentyEightPointBar() throws {
        let widget = try ShellRenderedWidget("omniwm")
        for vertical in [false, true] {
            var style = ShellBarStyle()
            style.height = 28
            style.vertical = vertical
            widget.render(ShellBarData(style: style))
            XCTAssertEqual(widget.surface.size, CGSize(width: 24, height: 24), "vertical \(vertical)")
        }
    }

    func testLeftAndRightClicksBothOpenTheStatusMenuWithTheirButton() throws {
        let widget = try ShellRenderedWidget("omniwm")
        widget.render(ShellBarData())
        let center = CGPoint(x: 10, y: 10)
        widget.surface.press(at: center)
        widget.surface.release(at: center, event: ShellEvent(button: .left, modifiers: []))
        widget.surface.press(at: center, button: .right)
        widget.surface.release(at: center, event: ShellEvent(button: .right, modifiers: []))
        XCTAssertEqual(widget.clicks.map(\.action), [ShellRequest.statusMenuCommand, ShellRequest.statusMenuCommand])
        XCTAssertEqual(widget.clicks.map(\.button), [.left, .right])
    }

    func testMenuButtonShowsTheSecureInputLockOnlyWhileActive() throws {
        let widget = try ShellRenderedWidget("omniwm")
        var style = ShellBarStyle()
        style.secureInput = true
        widget.render(ShellBarData(style: style))
        XCTAssertEqual(widget.strings(), [
            ShellLocalizer.string("Secure Input is on: Option shortcuts are paused", []),
            "omniwm.lock"
        ])

        style.secureInput = false
        widget.render(ShellBarData(style: style))
        XCTAssertEqual(widget.strings(), [ShellLocalizer.string("Window manager controls", []), "omniwm"])
    }
}
