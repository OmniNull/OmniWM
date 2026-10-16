// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellEnterTests: XCTestCase {
    func testEnterTablesParseWithDefaultsAndCurveNames() throws {
        let widget = try ShellRenderedWidget(name: "enter", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.column{
                ui.box{ w = 4, h = 4, enter = { opacity = 0, scale = 0.5, dx = 3, dy = -4, from = 0.25, to = 0.75, curve = "back" } },
                ui.box{ w = 4, h = 4, enter = { opacity = 7, curve = "wobbly" } },
                ui.box{ w = 4, h = 4 },
            }
        end
        """)
        let enters = widget.renderPopout().dropFirst().map(\.paint.enter)
        XCTAssertEqual(enters[0], Enter(opacity: 0, scale: 0.5, dx: 3, dy: -4, from: 64 / 255, to: 191 / 255, curve: 5))
        XCTAssertEqual(enters[1], Enter(opacity: 1, curve: 3))
        XCTAssertEqual(enters[2], .none)
        XCTAssertNil(ShellEnter(enters[2]))
    }

    func testMaskMarksTheShaderThatShapesItsStack() throws {
        let widget = try ShellRenderedWidget(name: "mask", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.stack{ material = "thin", ui.shader{ source = "blob.metal", mask = true }, ui.shader{ source = "glow.metal" } }
        end
        """)
        XCTAssertEqual(widget.renderPopout().map(\.paint.masks), [false, true, false])
    }

    func testEntersFollowTheOpeningAndRetraceItOnClose() throws {
        let widget = try ShellRenderedWidget(name: "enter", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.column{
                ui.box{ w = 10, h = 20, enter = { opacity = 0, scale = 0.5, dy = -8, from = 0.25, to = 0.75, curve = "linear" } },
            }
        end
        """)
        let enter = try XCTUnwrap(ShellEnter(try XCTUnwrap(widget.renderPopout().last).paint.enter))
        let size = CGSize(width: 10, height: 20)
        let opening = try XCTUnwrap(enter.plan(
            ShellShaderTransition(from: 0, to: 1, start: 100, duration: 1, forced: true),
            at: 100,
            opacity: 0.8,
            transform: CATransform3DIdentity,
            size: size
        ))
        XCTAssertEqual(opening.begin, 100.25, accuracy: 0.01)
        XCTAssertEqual(opening.duration, 0.5, accuracy: 0.01)
        XCTAssertEqual(opening.opacity.from, 0)
        XCTAssertEqual(opening.opacity.to, 0.8)
        XCTAssertEqual(opening.transform.from.m11, 0.5)
        XCTAssertEqual(opening.transform.from.m41, 2.5)
        XCTAssertEqual(opening.transform.from.m42, -3)
        XCTAssertTrue(CATransform3DIsIdentity(opening.transform.to))
        XCTAssertTrue(opening.settles)

        let midway = try XCTUnwrap(enter.plan(
            ShellShaderTransition(from: 0, to: 1, start: 100, duration: 1, forced: true),
            at: 100.5,
            opacity: 1,
            transform: CATransform3DIdentity,
            size: size
        ))
        XCTAssertEqual(midway.begin, 100.5)
        XCTAssertEqual(midway.opacity.from, 0.5, accuracy: 0.01)

        let closing = try XCTUnwrap(enter.plan(
            ShellShaderTransition(from: 1, to: 0, start: 200, duration: 1, forced: true),
            at: 200,
            opacity: 1,
            transform: CATransform3DIdentity,
            size: size
        ))
        XCTAssertEqual(closing.begin, 200.25, accuracy: 0.01)
        XCTAssertEqual(closing.opacity.from, 1)
        XCTAssertEqual(closing.opacity.to, 0)
        XCTAssertFalse(closing.settles)

        XCTAssertNil(enter.plan(.settled, at: 0, opacity: 1, transform: CATransform3DIdentity, size: size))
        XCTAssertNil(enter.plan(
            ShellShaderTransition(from: 0, to: 1, start: 0, duration: 1),
            at: 2,
            opacity: 1,
            transform: CATransform3DIdentity,
            size: size
        ))
    }
}
