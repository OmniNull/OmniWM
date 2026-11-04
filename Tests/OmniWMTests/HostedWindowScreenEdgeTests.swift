// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedWindowScreenEdgeTests: XCTestCase {
    func testAppWindowKeepsItsFramePastTheTopAndBottomThroughHideAndReveal() throws {
        let fixture = try HostedManagementFixture(layout: .niri)
        defer { fixture.close() }
        var opened: [NSWindow] = []
        fixture.manager.makeWindow = { definition in
            let window = ShellAppWindowManager.makeWindow(definition)
            opened.append(window)
            return window
        }
        defer {
            for window in opened {
                window.close()
            }
        }
        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.shellAppNewWindow(fixture.definition.id)), .executed
        )
        let window = try XCTUnwrap(opened.last)
        let token = WindowToken(pid: getpid(), windowId: window.windowNumber)
        let desktop = NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }
        let size = window.frame.size
        for y in [desktop.maxY, desktop.minY - size.height] {
            let target = CGRect(origin: CGPoint(x: desktop.minX, y: y), size: size)

            XCTAssertTrue(fixture.manager.setFrame(target, for: token))
            XCTAssertEqual(window.frame, target)

            XCTAssertTrue(fixture.manager.setHidden(true, for: token))
            XCTAssertFalse(window.isVisible)
            XCTAssertTrue(fixture.manager.setHidden(false, for: token))
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(window.frame, target)
        }
    }
}
