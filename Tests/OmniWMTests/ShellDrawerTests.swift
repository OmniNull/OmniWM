// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class ShellDrawerTests: XCTestCase {
    func testDrawerTablesParseWithDefaultsAndSkipInvalidOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
        [profiles.default.drawer.controls]
        widgets = ["volume", "media"]
        hover = true
        [profiles.default.drawer.agenda]
        edge = "left"
        widgets = ["calendar"]
        [profiles.default.drawer.sideways]
        edge = "middle"
        widgets = ["clock"]
        [profiles.default.drawer.empty]
        edge = "top"
        widgets = []
        """.utf8).write(to: root.appendingPathComponent("shell.toml"))
        let config = try XCTUnwrap(ShellConfig.load(shellDirectory: root))
        XCTAssertEqual(config.drawers, [
            ShellDrawerConfig(id: "agenda", edge: .left, widgets: ["calendar"], hover: false),
            ShellDrawerConfig(id: "controls", edge: .right, widgets: ["volume", "media"], hover: true)
        ])
    }

    private func monitor(_ display: UInt32, _ frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: display),
            displayId: display,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: ""
        )
    }

    func testHoverOpensAtOuterScreenEdgesOnlyAndRearmsAfterLeaving() {
        let left = monitor(1, CGRect(x: 0, y: 0, width: 1000, height: 800))
        let right = monitor(2, CGRect(x: 1000, y: 0, width: 1000, height: 800))
        let drawers = [
            ShellDrawerConfig(id: "quiet", edge: .right, widgets: ["clock"], hover: false),
            ShellDrawerConfig(id: "controls", edge: .right, widgets: ["volume"], hover: true),
            ShellDrawerConfig(id: "agenda", edge: .top, widgets: ["calendar"], hover: true)
        ]
        var hover = ShellEdgeHover()
        let update = { (point: CGPoint, buttons: Bool) in
            hover.update(pointer: point, drawers: drawers, monitors: [left, right], buttonsDown: buttons, open: nil)
                .flatMap { action -> String? in
                    guard case let .open(drawer, monitor) = action else { return nil }
                    return "\(drawer)@\(monitor.displayId)"
                }
        }
        XCTAssertNil(update(CGPoint(x: 999.5, y: 400), false))
        XCTAssertEqual(update(CGPoint(x: 1999.5, y: 400), false), "controls@2")
        XCTAssertNil(update(CGPoint(x: 1999.5, y: 300), false))
        XCTAssertNil(update(CGPoint(x: 1500, y: 300), false))
        XCTAssertEqual(update(CGPoint(x: 1999.5, y: 300), false), "controls@2")
        XCTAssertNil(update(CGPoint(x: 1500, y: 300), false))
        XCTAssertNil(update(CGPoint(x: 1999.5, y: 300), true))
        XCTAssertNil(update(CGPoint(x: 1999.5, y: 300), false))
        XCTAssertNil(update(CGPoint(x: 1500, y: 300), false))
        XCTAssertEqual(update(CGPoint(x: 300, y: 799.5), false), "agenda@1")
    }

    func testDashboardDrawersOpenOverTheirStretchAndCloseOnLeave() {
        let screen = monitor(1, CGRect(x: 0, y: 0, width: 1000, height: 800))
        var dashboard = ShellDrawerConfig(id: "dashboard", edge: .top, widgets: ["dash"], hover: true)
        dashboard.reach = 10
        dashboard.width = 400
        dashboard.closesOnLeave = true
        var hover = ShellEdgeHover()
        let region = CGRect(x: 275, y: 500, width: 450, height: 300)
        var open: ShellEdgeHover.Open?
        let update = { (point: CGPoint, buttons: Bool) -> ShellEdgeHover.Action? in
            hover.update(pointer: point, drawers: [dashboard], monitors: [screen], buttonsDown: buttons, open: open)
        }
        XCTAssertNil(update(CGPoint(x: 250, y: 795), false))
        XCTAssertNil(update(CGPoint(x: 500, y: 780), false))
        XCTAssertNil(update(CGPoint(x: 500, y: 795), true))
        XCTAssertNil(update(CGPoint(x: 500, y: 600), false))
        XCTAssertEqual(update(CGPoint(x: 500, y: 795), false), .open(drawer: "dashboard", monitor: screen.id))
        open = ShellEdgeHover.Open(drawer: dashboard, region: region)
        XCTAssertNil(update(CGPoint(x: 500, y: 600), false))
        XCTAssertNil(update(CGPoint(x: 280, y: 520), false))
        XCTAssertEqual(update(CGPoint(x: 500, y: 300), false), .close)
        open = nil
        XCTAssertNil(update(CGPoint(x: 500, y: 795), false))
        XCTAssertNil(update(CGPoint(x: 500, y: 600), false))
        XCTAssertEqual(update(CGPoint(x: 500, y: 795), false), .open(drawer: "dashboard", monitor: screen.id))
    }

    func testAHoverOpenedDrawerWaitsForItsPanelAndHoldsAlongItsTrigger() {
        let screen = monitor(1, CGRect(x: 0, y: 0, width: 1000, height: 800))
        var dashboard = ShellDrawerConfig(id: "dashboard", edge: .top, widgets: ["dash"], hover: true)
        dashboard.width = 400
        dashboard.closesOnLeave = true
        var hover = ShellEdgeHover()
        var open: ShellEdgeHover.Open?
        let update = { (point: CGPoint) -> ShellEdgeHover.Action? in
            hover.update(pointer: point, drawers: [dashboard], monitors: [screen], buttonsDown: false, open: open)
        }
        XCTAssertEqual(update(CGPoint(x: 320, y: 799.5)), .open(drawer: "dashboard", monitor: screen.id))
        open = ShellEdgeHover.Open(drawer: dashboard, region: nil)
        XCTAssertNil(update(CGPoint(x: 320, y: 700)))
        open = ShellEdgeHover.Open(drawer: dashboard, region: CGRect(x: 400, y: 600, width: 200, height: 200))
        XCTAssertNil(update(CGPoint(x: 320, y: 799.5)))
        XCTAssertNil(update(CGPoint(x: 450, y: 650)))
        XCTAssertNil(hover.update(
            pointer: CGPoint(x: 320, y: 700),
            drawers: [dashboard],
            monitors: [screen],
            buttonsDown: true,
            open: open
        ))
        XCTAssertEqual(update(CGPoint(x: 320, y: 700)), .close)
    }

    func testDrawersOpenedByAHotkeyStayUntilThePointerHasBeenInsideAndLeft() {
        let screen = monitor(1, CGRect(x: 0, y: 0, width: 1000, height: 800))
        var dashboard = ShellDrawerConfig(id: "dashboard", edge: .top, widgets: ["dash"], hover: true)
        dashboard.closesOnLeave = true
        var hover = ShellEdgeHover()
        let open = ShellEdgeHover.Open(drawer: dashboard, region: CGRect(x: 275, y: 500, width: 450, height: 300))
        let update = { (point: CGPoint) in
            hover.update(pointer: point, drawers: [dashboard], monitors: [screen], buttonsDown: false, open: open)
        }
        XCTAssertNil(update(CGPoint(x: 100, y: 100)))
        XCTAssertNil(update(CGPoint(x: 900, y: 300)))
        XCTAssertNil(update(CGPoint(x: 500, y: 600)))
        XCTAssertEqual(update(CGPoint(x: 900, y: 300)), .close)

        let outside = ShellDrawerConfig(id: "dashboard", edge: .top, widgets: ["dash"], hover: true)
        var plain = ShellEdgeHover()
        XCTAssertNil(plain.update(
            pointer: CGPoint(x: 900, y: 300),
            drawers: [outside],
            monitors: [screen],
            buttonsDown: false,
            open: ShellEdgeHover.Open(drawer: outside, region: open.region)
        ))
    }

    func testFlushDrawersHangBesideTheBarWithRoomToOvershoot() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 770)
        XCTAssertEqual(
            ShellEdgeDrawer.area(visible, beside: CGRect(x: 0, y: 0, width: 60, height: 770)),
            CGRect(x: 60, y: 0, width: 940, height: 770)
        )
        XCTAssertEqual(
            ShellEdgeDrawer.area(visible, beside: CGRect(x: 0, y: 760, width: 1000, height: 40)),
            CGRect(x: 0, y: 0, width: 1000, height: 760)
        )
        XCTAssertEqual(ShellEdgeDrawer.area(visible, beside: CGRect(x: 0, y: 775, width: 1000, height: 25)), visible)
        XCTAssertEqual(ShellEdgeDrawer.area(visible, beside: nil), visible)

        let flush = ShellEdgeDrawer.flush(
            size: CGSize(width: 400, height: 200),
            edge: .top,
            area: CGRect(x: 60, y: 0, width: 940, height: 770)
        )
        XCTAssertEqual(flush.content, CGRect(x: 330, y: 570, width: 400, height: 200))
        XCTAssertEqual(flush.panel, CGRect(x: 330, y: 546, width: 400, height: 224))
    }

    func testDrawerTablesTakeTheDashboardKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
        [profiles.default.drawer.dashboard]
        edge = "top"
        widgets = ["dash"]
        hover = true
        reach = 10
        width = 900
        close = "leave"
        chrome = false
        [profiles.default.drawer.odd]
        widgets = ["dash"]
        close = "never"
        """.utf8).write(to: root.appendingPathComponent("shell.toml"))
        var problems: [String] = []
        let drawers = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems)).drawers
        let dashboard = try XCTUnwrap(drawers.first { $0.id == "dashboard" })
        XCTAssertEqual(dashboard.reach, 10)
        XCTAssertEqual(dashboard.width, 900)
        XCTAssertTrue(dashboard.closesOnLeave)
        XCTAssertFalse(dashboard.chrome)
        let odd = try XCTUnwrap(drawers.first { $0.id == "odd" })
        XCTAssertEqual(odd.reach, 1)
        XCTAssertNil(odd.width)
        XCTAssertFalse(odd.closesOnLeave)
        XCTAssertTrue(odd.chrome)
        XCTAssertTrue(problems.contains { $0.contains("close must be") }, "\(problems)")
    }

    func testDrawersSitOnTheirEdgeCentredAndSlideInFromBeyondIt() {
        let visible = CGRect(x: 0, y: 40, width: 1000, height: 600)
        let size = CGSize(width: 200, height: 100)
        let expected: [(ShellDrawerConfig.Edge, CGRect, CGRect)] = [
            (.right, CGRect(x: 792, y: 290, width: 200, height: 100), CGRect(x: 1000, y: 290, width: 200, height: 100)),
            (.left, CGRect(x: 8, y: 290, width: 200, height: 100), CGRect(x: -200, y: 290, width: 200, height: 100)),
            (.top, CGRect(x: 400, y: 532, width: 200, height: 100), CGRect(x: 400, y: 640, width: 200, height: 100)),
            (.bottom, CGRect(x: 400, y: 48, width: 200, height: 100), CGRect(x: 400, y: -60, width: 200, height: 100))
        ]
        for (edge, frame, hidden) in expected {
            let placed = ShellEdgeDrawer.frame(size: size, edge: edge, visibleFrame: visible)
            XCTAssertEqual(placed, frame, "\(edge)")
            XCTAssertEqual(ShellEdgeDrawer.hiddenFrame(placed, edge: edge), hidden, "\(edge)")
        }
        XCTAssertEqual(
            ShellEdgeDrawer.frame(size: CGSize(width: 2000, height: 900), edge: .right, visibleFrame: visible),
            CGRect(x: 8, y: 48, width: 984, height: 584)
        )
    }
}
