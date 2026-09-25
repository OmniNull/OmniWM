// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarMenuModelTests: XCTestCase {
    private let mainMonitor = Monitor.ID(displayId: 1)
    private let sideMonitor = Monitor.ID(displayId: 2)
    private let ws1 = WorkspaceDescriptor.ID()
    private let ws2 = WorkspaceDescriptor.ID()
    private let ws3 = WorkspaceDescriptor.ID()
    private let windowA = WindowToken(pid: 10, windowId: 1)
    private let windowB = WindowToken(pid: 10, windowId: 2)

    private func facts(
        displays: Int = 2,
        focusedWorkspace: WorkspaceDescriptor.ID? = nil
    ) -> WorkspaceBarMenuFacts {
        var all = [
            WorkspaceBarMenuFacts.Display(
                id: mainMonitor,
                name: "Main",
                workspaces: [.init(id: ws1, name: "1"), .init(id: ws2, name: "2")]
            ),
            WorkspaceBarMenuFacts.Display(
                id: sideMonitor,
                name: "Side",
                workspaces: [.init(id: ws3, name: "3")]
            )
        ]
        all = Array(all.prefix(displays))
        return WorkspaceBarMenuFacts(
            displays: all,
            focusedWindowWorkspaceId: focusedWorkspace,
            scratchpadSlots: [.init(index: 1, name: "Scratchpad 1"), .init(index: 2, name: "Scratchpad 2")]
        )
    }

    private func windowTarget(
        _ token: WindowToken,
        title: String = "Doc",
        workspace: WorkspaceDescriptor.ID? = nil,
        canMove: Bool = true,
        canSummon: Bool = true
    ) -> WorkspaceBarWindowMenuTarget {
        WorkspaceBarWindowMenuTarget(
            token: token,
            title: title,
            workspaceId: workspace ?? ws1,
            monitorId: mainMonitor,
            isFloating: false,
            canMove: canMove,
            canSummon: canSummon
        )
    }

    private func action(_ items: [WorkspaceBarMenuItem], titled title: String) -> WorkspaceBarMenuItem? {
        items.first {
            switch $0 {
            case let .action(itemTitle, _, _, _),
                 let .submenu(itemTitle, _, _): itemTitle == title
            default: false
            }
        }
    }

    func testWorkspaceMenuOffersFocusMoveRenameLayoutAndMonitorMove() {
        let target = WorkspaceBarWorkspaceMenuTarget(id: ws2, monitorId: mainMonitor, isConfigured: true, layout: .niri)
        let items = WorkspaceBarMenuBuilder.workspaceMenu(for: target, facts: facts(focusedWorkspace: ws1))

        XCTAssertEqual(items.first, .action("Focus Workspace", .focusWorkspace(ws2)))
        XCTAssertEqual(action(items, titled: "Move Focused Window Here"), .action(
            "Move Focused Window Here",
            .moveFocusedWindow(toWorkspace: ws2)
        ))
        XCTAssertEqual(action(items, titled: "Rename…"), .action("Rename…", .renameWorkspace(ws2)))
        XCTAssertEqual(action(items, titled: "Layout"), .submenu("Layout", [
            .action(LayoutType.niri.localizedDisplayName, .setLayout(ws2, .niri), isChecked: true),
            .action(LayoutType.dwindle.localizedDisplayName, .setLayout(ws2, .dwindle))
        ]))
        XCTAssertEqual(action(items, titled: "Move Workspace to Monitor"), .submenu(
            "Move Workspace to Monitor",
            [.action("Side", .moveWorkspaceToMonitor(ws2, sideMonitor))]
        ))
    }

    func testWorkspaceMenuDisablesUnavailableActions() {
        let target = WorkspaceBarWorkspaceMenuTarget(
            id: ws1,
            monitorId: mainMonitor,
            isConfigured: false,
            layout: .niri
        )
        let items = WorkspaceBarMenuBuilder.workspaceMenu(for: target, facts: facts(displays: 1, focusedWorkspace: ws1))

        XCTAssertEqual(action(items, titled: "Move Focused Window Here"), .action(
            "Move Focused Window Here",
            .moveFocusedWindow(toWorkspace: ws1),
            isEnabled: false
        ))
        XCTAssertEqual(
            action(items, titled: "Rename… (configured workspaces only)"),
            .action("Rename… (configured workspaces only)", .renameWorkspace(ws1), isEnabled: false)
        )
        guard case let .submenu(_, _, layoutEnabled)? = action(items, titled: "Layout (configured workspaces only)"),
              case let .submenu(_, monitors, monitorEnabled)? = action(items, titled: "Move Workspace to Monitor")
        else {
            return XCTFail("missing submenus")
        }
        XCTAssertFalse(layoutEnabled)
        XCTAssertTrue(monitors.isEmpty)
        XCTAssertFalse(monitorEnabled)
    }

    func testWindowMenuGroupsTargetsByMonitorAndExcludesOwnWorkspace() {
        let items = WorkspaceBarMenuBuilder.windowMenu(for: [windowTarget(windowA)], facts: facts())

        XCTAssertEqual(action(items, titled: "Move to Workspace"), .submenu("Move to Workspace", [
            .header("Main"),
            .action("2", .moveWindowsToWorkspace([windowA], ws2)),
            .header("Side"),
            .action("3", .moveWindowsToWorkspace([windowA], ws3))
        ]))
        XCTAssertEqual(action(items, titled: "Move to Monitor"), .submenu(
            "Move to Monitor",
            [.action("Side", .moveWindowsToMonitor([windowA], sideMonitor))]
        ))
        XCTAssertEqual(action(items, titled: "Float Window"), .action("Float Window", .toggleFloating(windowA)))
        XCTAssertEqual(action(items, titled: "Assign to Scratchpad"), .submenu("Assign to Scratchpad", [
            .action("Scratchpad 1", .assignToScratchpad(windowA, 1)),
            .action("Scratchpad 2", .assignToScratchpad(windowA, 2))
        ]))
        XCTAssertEqual(items.last, .action("Close Window", .closeWindow(windowA)))
    }

    func testSingleMonitorWindowMenuOmitsSectionHeaders() {
        let items = WorkspaceBarMenuBuilder.windowMenu(for: [windowTarget(windowA)], facts: facts(displays: 1))

        XCTAssertEqual(action(items, titled: "Move to Workspace"), .submenu(
            "Move to Workspace",
            [.action("2", .moveWindowsToWorkspace([windowA], ws2))]
        ))
        guard case let .submenu(_, _, isEnabled)? = action(items, titled: "Move to Monitor") else {
            return XCTFail("missing Move to Monitor")
        }
        XCTAssertFalse(isEnabled)
    }

    func testWindowMenuDisablesMovesForUnmovableWindows() {
        let items = WorkspaceBarMenuBuilder.windowMenu(
            for: [windowTarget(windowA, canMove: false, canSummon: false)],
            facts: facts()
        )

        for title in ["Move to Workspace", "Move to Monitor", "Assign to Scratchpad"] {
            guard case let .submenu(_, _, isEnabled)? = action(items, titled: title) else {
                return XCTFail("missing \(title)")
            }
            XCTAssertFalse(isEnabled, title)
        }
        XCTAssertEqual(
            action(items, titled: "Summon to the Right"),
            .action("Summon to the Right", .summonRight(windowA), isEnabled: false)
        )
        XCTAssertEqual(items.last, .action("Close Window", .closeWindow(windowA)))
    }

    func testScratchpadMenuForASingleMember() {
        let target = WorkspaceBarScratchpadMenuTarget(
            index: 2,
            isVisible: false,
            members: [.init(token: windowA, title: "Notes", canUnassign: true)]
        )

        XCTAssertEqual(WorkspaceBarMenuBuilder.scratchpadMenu(for: target), [
            .action("Show Scratchpad", .toggleScratchpad(2)),
            .action("Focus Window", .focusScratchpadWindow(windowA, 2)),
            .separator,
            .action("Unassign from Scratchpad", .unassignScratchpadWindows([windowA]))
        ])
    }

    func testScratchpadMenuForSeveralMembersOffersPerWindowAndUnassignAll() {
        let target = WorkspaceBarScratchpadMenuTarget(
            index: 1,
            isVisible: true,
            members: [
                .init(token: windowA, title: "Notes", canUnassign: true),
                .init(token: windowB, title: "Music", canUnassign: false)
            ]
        )
        let items = WorkspaceBarMenuBuilder.scratchpadMenu(for: target)

        XCTAssertEqual(items.first, .action("Hide Scratchpad", .toggleScratchpad(1)))
        XCTAssertEqual(action(items, titled: "Music"), .submenu("Music", [
            .action("Focus Window", .focusScratchpadWindow(windowB, 1)),
            .separator,
            .action("Unassign from Scratchpad", .unassignScratchpadWindows([windowB]), isEnabled: false)
        ]))
        XCTAssertEqual(items.last, .action("Unassign All", .unassignScratchpadWindows([windowA])))
    }

    func testGroupedWindowMenuMovesAllAndOffersPerWindowSubmenus() {
        let items = WorkspaceBarMenuBuilder.windowMenu(
            for: [windowTarget(windowA, title: "First"), windowTarget(windowB, title: "Second")],
            facts: facts(displays: 1)
        )

        XCTAssertEqual(action(items, titled: "Move All to Workspace"), .submenu(
            "Move All to Workspace",
            [.action("2", .moveWindowsToWorkspace([windowA, windowB], ws2))]
        ))
        guard case let .submenu(_, firstItems, _)? = action(items, titled: "First"),
              case .submenu? = action(items, titled: "Second")
        else {
            return XCTFail("missing per-window submenus")
        }
        XCTAssertEqual(firstItems.last, .action("Close Window", .closeWindow(windowA)))
    }
}
