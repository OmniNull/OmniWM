// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellWidgetMenuTests: XCTestCase {
    func testRightClicksOpenTheLayoutMenuUnlessTheWidgetUsesThem() throws {
        let widget = try ShellRenderedWidget(name: "menu", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.row{
                ui.box{ w = 20, h = 10, fill = "accent" },
                ui.box{ w = 20, h = 10, onRightClick = "focus left" },
                ui.box{ w = 20, h = 10, menu = true, target = "workspace 1" },
            }
        end
        """)
        widget.layoutPopout()
        let surface = widget.surface
        XCTAssertFalse(surface.openContextMenu(at: CGPoint(x: 5, y: 5), option: true))

        var layoutMenus = 0
        var targetMenus = 0
        surface.onLayoutMenu = { _ in layoutMenus += 1 }
        surface.onMenu = { _ in targetMenus += 1 }
        XCTAssertTrue(surface.openContextMenu(at: CGPoint(x: 5, y: 5), option: false))
        XCTAssertEqual(layoutMenus, 1)
        XCTAssertFalse(surface.openContextMenu(at: CGPoint(x: 25, y: 5), option: false))
        XCTAssertEqual(layoutMenus, 1)
        XCTAssertTrue(surface.openContextMenu(at: CGPoint(x: 25, y: 5), option: true))
        XCTAssertEqual(layoutMenus, 2)
        XCTAssertTrue(surface.openContextMenu(at: CGPoint(x: 45, y: 5), option: false))
        XCTAssertEqual(targetMenus, 1)
        XCTAssertEqual(layoutMenus, 2)
    }

    func testTheLayoutMenuMovesWithinASideAcrossSidesAndOffTheBar() {
        let layout = ShellBarLayout(
            leading: ["omniwm", "workspaces"],
            trailing: ["clock"],
            widgets: [],
            profile: ShellDefaults.profile,
            customized: false
        )
        XCTAssertEqual(WorkspaceBarManager.widgetMenuItems(for: "omniwm", layout: layout, vertical: false), [
            .header("OmniWM"),
            .action(String(localized: "Move Left"), .editShellWidget("omniwm", .earlier), isEnabled: false),
            .action(String(localized: "Move Right"), .editShellWidget("omniwm", .later), isEnabled: true),
            .action(
                String(localized: "Move to \(String(localized: "Center"))"),
                .editShellWidget("omniwm", .lane(.center))
            ),
            .action(
                String(localized: "Move to \(String(localized: "Right"))"),
                .editShellWidget("omniwm", .lane(.trailing))
            ),
            .separator,
            .action(String(localized: "Remove from Bar"), .editShellWidget("omniwm", .remove)),
            .separator,
            .action(String(localized: "Bar Widgets…"), .openBarWidgetSettings)
        ])
        let vertical = WorkspaceBarManager.widgetMenuItems(for: "clock", layout: layout, vertical: true)
        XCTAssertEqual(
            vertical[1],
            .action(String(localized: "Move Up"), .editShellWidget("clock", .earlier), isEnabled: false)
        )
        XCTAssertEqual(
            vertical[2],
            .action(String(localized: "Move Down"), .editShellWidget("clock", .later), isEnabled: false)
        )
        XCTAssertEqual(
            vertical[3],
            .action(
                String(localized: "Move to \(String(localized: "Top"))"),
                .editShellWidget("clock", .lane(.leading))
            )
        )
        XCTAssertEqual(
            vertical[4],
            .action(
                String(localized: "Move to \(String(localized: "Center"))"),
                .editShellWidget("clock", .lane(.center))
            )
        )
    }
}
