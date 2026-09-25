// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarActionsTests: XCTestCase {
    struct Fixture {
        let controller: WMController
        let mainMonitor: Monitor
        let sideMonitor: Monitor
        let ws1: WorkspaceDescriptor.ID
        let ws2: WorkspaceDescriptor.ID
        let ws3: WorkspaceDescriptor.ID
    }

    func testMenuMoveOfAnUnfocusedWindowHonorsTheFollowSettingWithoutWarping() async throws {
        for followsFocus in [false, true] {
            let fixture = try makeFixture(followsFocus: followsFocus)
            let manager = fixture.controller.workspaceManager
            let neighbor = try addWindow(pid: 700_003, windowId: 3, to: fixture.ws1, fixture: fixture)
            let moved = try addWindow(pid: 700_002, windowId: 2, to: fixture.ws1, fixture: fixture)
            let focused = try addWindow(pid: 700_001, windowId: 1, to: fixture.ws1, fixture: fixture)
            try select(focused, in: fixture.ws1, fixture: fixture)
            let focusedNode = try XCTUnwrap(fixture.controller.niriEngine?.findNode(for: focused, in: fixture.ws1))

            fixture.controller.performWorkspaceBarMenuAction(
                .moveWindowsToWorkspace([moved.id], fixture.ws2),
                barMonitorId: fixture.mainMonitor.id
            )
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

            XCTAssertEqual(manager.workspace(for: moved.id), fixture.ws2)
            XCTAssertEqual(manager.workspace(for: neighbor.id), fixture.ws1)
            if followsFocus {
                XCTAssertEqual(manager.activeWorkspace(on: fixture.mainMonitor.id)?.id, fixture.ws2)
                let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
                XCTAssertEqual(request.token, moved.id)
                XCTAssertEqual(request.origin, .pointerSelection)
            } else {
                XCTAssertEqual(manager.activeWorkspace(on: fixture.mainMonitor.id)?.id, fixture.ws1)
                XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
                XCTAssertEqual(manager.selectedManagedToken, focused.id)
                XCTAssertEqual(manager.niriViewportState(for: fixture.ws1).selectedNodeId, focusedNode.id)
            }
        }
    }

    func testMenuMoveOfTheFocusedWindowRefocusesTheSourceWithoutWarping() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let neighbor = try addWindow(pid: 700_004, windowId: 4, to: fixture.ws1, fixture: fixture)
        let focused = try addWindow(pid: 700_005, windowId: 5, to: fixture.ws1, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)

        fixture.controller.performWorkspaceBarMenuAction(
            .moveWindowsToWorkspace([focused.id], fixture.ws2),
            barMonitorId: fixture.mainMonitor.id
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: focused.id), fixture.ws2)
        let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(request.token, neighbor.id)
        XCTAssertEqual(request.origin, .pointerSelection)
    }

    func testShiftClickMovesTheSelectedWindow() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let focused = try addWindow(pid: 700_011, windowId: 1, to: fixture.ws1, fixture: fixture)
        let other = try addWindow(pid: 700_012, windowId: 2, to: fixture.ws1, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)

        XCTAssertTrue(fixture.controller.workspaceNavigationHandler
            .moveFocusedWindowFromBar(toWorkspaceId: fixture.ws2))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: focused.id), fixture.ws2)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: other.id), fixture.ws1)
    }

    func testMoveToMonitorTargetsThatMonitorsActiveWorkspace() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let focused = try addWindow(pid: 700_021, windowId: 1, to: fixture.ws1, fixture: fixture)
        let moved = try addWindow(pid: 700_022, windowId: 2, to: fixture.ws1, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)

        fixture.controller.performWorkspaceBarMenuAction(
            .moveWindowsToMonitor([moved.id], fixture.sideMonitor.id),
            barMonitorId: fixture.mainMonitor.id
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: moved.id), fixture.ws3)
    }

    func testMoveAllMovesEveryGroupedWindow() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let first = try addWindow(pid: 700_031, windowId: 1, to: fixture.ws1, fixture: fixture)
        let second = try addWindow(pid: 700_031, windowId: 2, to: fixture.ws1, fixture: fixture)
        let anchor = try addWindow(pid: 700_032, windowId: 3, to: fixture.ws1, fixture: fixture)
        try select(anchor, in: fixture.ws1, fixture: fixture)

        fixture.controller.performWorkspaceBarMenuAction(
            .moveWindowsToWorkspace([first.id, second.id], fixture.ws2),
            barMonitorId: fixture.mainMonitor.id
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        let manager = fixture.controller.workspaceManager
        XCTAssertEqual(manager.workspace(for: first.id), fixture.ws2)
        XCTAssertEqual(manager.workspace(for: second.id), fixture.ws2)
        XCTAssertEqual(manager.workspace(for: anchor.id), fixture.ws1)
    }

    func testMoveWorkspaceToMonitorByIdentifier() async throws {
        let fixture = try makeFixture(followsFocus: false)

        fixture.controller.performWorkspaceBarMenuAction(
            .moveWorkspaceToMonitor(fixture.ws2, fixture.sideMonitor.id),
            barMonitorId: fixture.mainMonitor.id
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.monitorId(for: fixture.ws2), fixture.sideMonitor.id)
    }

    func testRenameAndLayoutApplyOnlyToConfiguredWorkspaces() throws {
        let fixture = try makeFixture(followsFocus: false)
        let controller = fixture.controller

        XCTAssertEqual(controller.setWorkspaceDisplayName("Mail", forWorkspaceNamed: "2"), .executed)
        XCTAssertEqual(controller.settings.workspaces.displayName(for: "2"), "Mail")
        XCTAssertEqual(controller.setWorkspaceDisplayName("Mail", forWorkspaceNamed: "2"), .noChange)
        XCTAssertEqual(controller.setWorkspaceDisplayName("", forWorkspaceNamed: "2"), .executed)
        XCTAssertEqual(controller.settings.workspaces.displayName(for: "2"), "2")
        XCTAssertEqual(controller.setWorkspaceDisplayName("Mail", forWorkspaceNamed: "9"), .notFound)

        controller.performWorkspaceBarMenuAction(
            .setLayout(fixture.ws2, .dwindle),
            barMonitorId: fixture.mainMonitor.id
        )
        XCTAssertEqual(controller.workspaceManager.activeLayoutKind(for: fixture.ws2), .dwindle)

        let dynamic = try XCTUnwrap(controller.workspaceManager.createDynamicWorkspace(
            named: "8",
            on: fixture.mainMonitor.id
        ))
        XCTAssertEqual(controller.workspaceBarWorkspaceMenuTarget(for: dynamic.id)?.isConfigured, false)
        XCTAssertEqual(controller.workspaceBarWorkspaceMenuTarget(for: fixture.ws2)?.isConfigured, true)
    }

    func testToggleFloatingAndScratchpadAssignmentTargetTheClickedWindow() throws {
        let fixture = try makeFixture(followsFocus: false)
        let manager = fixture.controller.workspaceManager
        let focused = try addWindow(pid: 700_041, windowId: 700_141, to: fixture.ws1, fixture: fixture)
        let floated = try addWindow(pid: 700_042, windowId: 700_142, to: fixture.ws1, fixture: fixture)
        let assigned = try addWindow(pid: 700_043, windowId: 700_143, to: fixture.ws1, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)
        fixture.controller.axManager.confirmFrameWrite(
            for: assigned.id.windowId,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )

        XCTAssertEqual(fixture.controller.toggleWindowFloating(floated.id), .executed)
        XCTAssertEqual(manager.manualLayoutOverride(for: floated.id), .forceFloat)
        XCTAssertNil(manager.manualLayoutOverride(for: focused.id))

        fixture.controller.performWorkspaceBarMenuAction(
            .assignToScratchpad(assigned.id, 3),
            barMonitorId: fixture.mainMonitor.id
        )
        XCTAssertEqual(manager.scratchpadIndex(for: assigned.id), 3)
        XCTAssertNil(manager.scratchpadIndex(for: focused.id))
    }

    func testAssigningTheFocusedWindowToAScratchpadRecoversFocusWithoutWarping() throws {
        let fixture = try makeFixture(followsFocus: false)
        let neighbor = try addWindow(pid: 700_044, windowId: 700_144, to: fixture.ws1, fixture: fixture)
        let focused = try addWindow(pid: 700_045, windowId: 700_145, to: fixture.ws1, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)
        fixture.controller.axManager.confirmFrameWrite(
            for: focused.id.windowId,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )

        fixture.controller.performWorkspaceBarMenuAction(
            .assignToScratchpad(focused.id, 2),
            barMonitorId: fixture.mainMonitor.id
        )

        XCTAssertEqual(fixture.controller.workspaceManager.scratchpadIndex(for: focused.id), 2)
        let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(request.token, neighbor.id)
        XCTAssertEqual(request.origin, .pointerSelection)
    }

    func testSummonAnchorPrefersTheFocusedWindowThenTheRememberedOne() throws {
        let fixture = try makeFixture(followsFocus: false)
        let focused = try addWindow(pid: 700_051, windowId: 1, to: fixture.ws1, fixture: fixture)
        let other = try addWindow(pid: 700_052, windowId: 2, to: fixture.ws2, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)

        XCTAssertEqual(fixture.controller.summonAnchorToken(in: fixture.ws1), focused.id)
        XCTAssertNil(fixture.controller.summonAnchorToken(in: fixture.ws2))
        _ = fixture.controller.workspaceManager.rememberFocus(other.id, in: fixture.ws2)
        XCTAssertEqual(fixture.controller.summonAnchorToken(in: fixture.ws2), other.id)

        let target = try XCTUnwrap(fixture.controller.workspaceBarWindowMenuTarget(for: other.id, title: "Other"))
        XCTAssertTrue(target.canSummon)
        let anchorTarget = try XCTUnwrap(
            fixture.controller.workspaceBarWindowMenuTarget(for: focused.id, title: "Focused")
        )
        XCTAssertFalse(anchorTarget.canSummon)
    }

    func testMenuFactsListEveryMonitorsWorkspacesAndScratchpadSlots() throws {
        let fixture = try makeFixture(followsFocus: false)
        let focused = try addWindow(pid: 700_061, windowId: 1, to: fixture.ws1, fixture: fixture)
        try select(focused, in: fixture.ws1, fixture: fixture)

        let facts = fixture.controller.workspaceBarMenuFacts()

        XCTAssertEqual(facts.displays.map(\.id), [fixture.mainMonitor.id, fixture.sideMonitor.id])
        XCTAssertEqual(facts.displays.first?.workspaces.map(\.id), [fixture.ws1, fixture.ws2])
        XCTAssertEqual(facts.displays.last?.workspaces.map(\.id), [fixture.ws3])
        XCTAssertEqual(facts.focusedWindowWorkspaceId, fixture.ws1)
        XCTAssertEqual(facts.scratchpadSlots.map(\.index.rawValue), Array(ScratchpadIndex.range))
    }

    func testDroppingASingleColumnInAGapReordersTheColumnAndFocusesIt() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let first = try addWindow(pid: 700_071, windowId: 1, to: fixture.ws1, fixture: fixture)
        let second = try addWindow(pid: 700_072, windowId: 2, to: fixture.ws1, fixture: fixture)
        let third = try addWindow(pid: 700_073, windowId: 3, to: fixture.ws1, fixture: fixture)
        try select(second, in: fixture.ws1, fixture: fixture)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriMoveColumn(fixture.ws1, oneBasedIndex: 3),
            source: .init(tokens: [first.id], workspaceId: fixture.ws1, isFloating: false)
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try columnTokens(in: fixture.ws1, fixture: fixture), [[second.id], [third.id], [first.id]])
        let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(request.token, first.id)
        XCTAssertEqual(request.origin, .pointerSelection)
    }

    func testColumnMoveUsesProjectedIndicesAroundExcludedColumns() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let first = try addWindow(pid: 700_081, windowId: 12, to: fixture.ws1, fixture: fixture)
        let excluded = try addWindow(pid: 700_082, windowId: 13, to: fixture.ws1, fixture: fixture)
        let last = try addWindow(pid: 700_083, windowId: 14, to: fixture.ws1, fixture: fixture)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.ws1) {
            engine.setProjectionExclusions([excluded.id], in: fixture.ws1)
        }
        let layout = fixture.controller.workspaceBarDropLayout(for: fixture.ws1)
        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.placements[last.id]?.column, 1)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriMoveColumn(fixture.ws1, oneBasedIndex: 2),
            source: .init(tokens: [first.id], workspaceId: fixture.ws1, isFloating: false)
        ))

        XCTAssertEqual(try columnTokens(in: fixture.ws1, fixture: fixture), [[excluded.id], [last.id], [first.id]])
    }

    func testDroppingOntoAnIconStacksAndAGapSplitsTheStackAgain() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let first = try addWindow(pid: 700_074, windowId: 4, to: fixture.ws1, fixture: fixture)
        let second = try addWindow(pid: 700_075, windowId: 5, to: fixture.ws1, fixture: fixture)
        try select(second, in: fixture.ws1, fixture: fixture)
        let source = WorkspaceBarDragSource(tokens: [first.id], workspaceId: fixture.ws1, isFloating: false)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriStack(fixture.ws1, target: second.id, position: .after),
            source: source
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertEqual(try columnTokens(in: fixture.ws1, fixture: fixture), [[second.id, first.id]])

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(.niriNewColumn(fixture.ws1, gap: 0), source: source))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertEqual(try columnTokens(in: fixture.ws1, fixture: fixture), [[first.id], [second.id]])
    }

    func testDwindleDropSwapsTheTwoTiles() async throws {
        let fixture = try makeFixture(followsFocus: false)
        fixture.controller.performWorkspaceBarMenuAction(
            .setLayout(fixture.ws2, .dwindle),
            barMonitorId: fixture.mainMonitor.id
        )
        let first = try addWindow(pid: 700_076, windowId: 6, to: fixture.ws2, fixture: fixture)
        let second = try addWindow(pid: 700_077, windowId: 7, to: fixture.ws2, fixture: fixture)
        let engine = try XCTUnwrap(fixture.controller.dwindleEngine)
        let before = try XCTUnwrap(engine.root(for: fixture.ws2)).collectAllWindows()

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .dwindleSwap(fixture.ws2, target: second.id),
            source: .init(tokens: [first.id], workspaceId: fixture.ws2, isFloating: false)
        ))

        XCTAssertEqual(try XCTUnwrap(engine.root(for: fixture.ws2)).collectAllWindows(), before.reversed())
    }

    func testDroppingOnAnotherWorkspaceMovesTheWholeGroup() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let first = try addWindow(pid: 700_078, windowId: 8, to: fixture.ws1, fixture: fixture)
        let second = try addWindow(pid: 700_078, windowId: 9, to: fixture.ws1, fixture: fixture)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .moveToWorkspace(fixture.ws3),
            source: .init(tokens: [first.id, second.id], workspaceId: fixture.ws1, isFloating: false)
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: first.id), fixture.ws3)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: second.id), fixture.ws3)
    }

    func testDroppingIntoAnotherNiriRowInsertsAtThatPosition() async throws {
        let fixture = try makeFixture(followsFocus: false)
        let moved = try addWindow(pid: 700_084, windowId: 15, to: fixture.ws1, fixture: fixture)
        let stayed = try addWindow(pid: 700_085, windowId: 16, to: fixture.ws1, fixture: fixture)
        let target = try addWindow(pid: 700_086, windowId: 17, to: fixture.ws2, fixture: fixture)
        try select(stayed, in: fixture.ws1, fixture: fixture)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriStack(fixture.ws2, target: target.id, position: .before),
            source: .init(tokens: [moved.id], workspaceId: fixture.ws1, isFloating: false)
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try columnTokens(in: fixture.ws2, fixture: fixture), [[moved.id, target.id]])
        XCTAssertEqual(fixture.controller.workspaceManager.activeWorkspace(on: fixture.mainMonitor.id)?.id, fixture.ws1)
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, stayed.id)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriNewColumn(fixture.ws1, gap: 0),
            source: .init(tokens: [moved.id], workspaceId: fixture.ws2, isFloating: false)
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(try columnTokens(in: fixture.ws1, fixture: fixture), [[moved.id], [stayed.id]])
    }

    func testDroppingADwindleWindowIntoANiriRowWaitsForAdmission() async throws {
        let fixture = try makeFixture(followsFocus: false)
        fixture.controller.performWorkspaceBarMenuAction(
            .setLayout(fixture.ws2, .dwindle),
            barMonitorId: fixture.mainMonitor.id
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        let niriWindow = try addWindow(pid: 700_087, windowId: 18, to: fixture.ws1, fixture: fixture)
        let dwindleWindow = try addWindow(pid: 700_088, windowId: 19, to: fixture.ws2, fixture: fixture)
        try select(niriWindow, in: fixture.ws1, fixture: fixture)

        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriNewColumn(fixture.ws1, gap: 0),
            source: .init(tokens: [dwindleWindow.id], workspaceId: fixture.ws2, isFloating: false)
        ))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: dwindleWindow.id), fixture.ws1)
        XCTAssertEqual(try columnTokens(in: fixture.ws1, fixture: fixture), [[dwindleWindow.id], [niriWindow.id]])
    }

    func testDropLayoutReportsProjectedColumnPlacements() throws {
        let fixture = try makeFixture(followsFocus: false)
        let first = try addWindow(pid: 700_079, windowId: 10, to: fixture.ws1, fixture: fixture)
        let second = try addWindow(pid: 700_080, windowId: 11, to: fixture.ws1, fixture: fixture)
        XCTAssertTrue(fixture.controller.commitWorkspaceBarDrop(
            .niriStack(fixture.ws1, target: first.id, position: .after),
            source: .init(tokens: [second.id], workspaceId: fixture.ws1, isFloating: false)
        ))

        let layout = fixture.controller.workspaceBarDropLayout(for: fixture.ws1)

        XCTAssertEqual(layout.layout, .niri)
        XCTAssertEqual(layout.columnCount, 1)
        XCTAssertEqual(layout.placements[first.id], .init(column: 0, row: 0, columnTileCount: 2))
        XCTAssertEqual(layout.placements[second.id], .init(column: 0, row: 1, columnTileCount: 2))
    }

    private func columnTokens(in workspaceId: WorkspaceDescriptor.ID, fixture: Fixture) throws -> [[WindowToken]] {
        try XCTUnwrap(fixture.controller.niriEngine).columns(in: workspaceId).map { $0.windowNodes.map(\.token) }
    }

    private func makeFixture(followsFocus: Bool) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceBarActionsTests-\(UUID().uuidString)", isDirectory: true)
        let mainMonitor = Monitor(
            id: .init(displayId: 700_000), displayId: 700_000,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false, name: "Main"
        )
        let sideMonitor = Monitor(
            id: .init(displayId: 700_001), displayId: 700_001,
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            hasNotch: false, name: "Side"
        )
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        settings.animationsEnabled = false
        settings.focus.followsWindowToMonitor = followsFocus
        settings.workspaces.defaultLayoutType = .niri
        settings.workspaces.configurations = [
            WorkspaceConfiguration(name: "1", monitorAssignment: .specificDisplay(OutputId(from: mainMonitor))),
            WorkspaceConfiguration(name: "2", monitorAssignment: .specificDisplay(OutputId(from: mainMonitor))),
            WorkspaceConfiguration(name: "3", monitorAssignment: .specificDisplay(OutputId(from: sideMonitor)))
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.workspaceManager.applyMonitorConfigurationChange([mainMonitor, sideMonitor])
        controller.workspaceManager.applySettings()
        let niriEngine = NiriLayoutEngine()
        niriEngine.animationClock = controller.animationClock
        controller.niriEngine = niriEngine
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()
        let dwindleEngine = DwindleLayoutEngine()
        dwindleEngine.animationClock = controller.animationClock
        controller.dwindleEngine = dwindleEngine

        let manager = controller.workspaceManager
        let ws1 = try XCTUnwrap(manager.workspaceId(named: "1"))
        let ws2 = try XCTUnwrap(manager.workspaceId(named: "2"))
        let ws3 = try XCTUnwrap(manager.workspaceId(named: "3"))
        XCTAssertTrue(manager.setActiveWorkspace(ws3, on: sideMonitor.id, updateInteractionMonitor: false))
        XCTAssertTrue(manager.setActiveWorkspace(ws1, on: mainMonitor.id))
        controller.layoutRefreshController.resetState()
        return Fixture(
            controller: controller,
            mainMonitor: mainMonitor,
            sideMonitor: sideMonitor,
            ws1: ws1,
            ws2: ws2,
            ws3: ws3
        )
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        fixture: Fixture
    ) throws -> WindowHandle {
        let manager = fixture.controller.workspaceManager
        let token = manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        manager.withEngineMutationScope(in: workspaceId) {
            switch manager.activeLayoutKind(for: workspaceId) {
            case .niri:
                _ = fixture.controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
            case .dwindle:
                _ = fixture.controller.dwindleEngine?.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
        }
        return try XCTUnwrap(manager.handle(for: token))
    }

    private func select(_ handle: WindowHandle, in workspaceId: WorkspaceDescriptor.ID, fixture: Fixture) throws {
        let manager = fixture.controller.workspaceManager
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let node = try XCTUnwrap(engine.findNode(for: handle, in: workspaceId))
        manager.withEngineMutationScope(in: workspaceId) {
            engine.activateWindow(node.id, in: workspaceId)
        }
        let monitorId = manager.monitorId(for: workspaceId)
        _ = manager.commitWorkspaceSelection(
            nodeId: node.id,
            focusedToken: handle.id,
            in: workspaceId,
            onMonitor: monitorId
        )
        _ = manager.setManagedFocus(handle.id, in: workspaceId, onMonitor: monitorId)
    }
}
