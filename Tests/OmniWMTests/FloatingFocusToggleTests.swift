// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FloatingFocusToggleTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let manager: WorkspaceManager
        let workspace1: WorkspaceDescriptor.ID
        let workspace2: WorkspaceDescriptor.ID
    }

    func testOnlyAFloatingWindowOnTheWorkspaceIsAToggleSource() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5001, 11, to: fixture.workspace1, manager: fixture.manager)
        let floating = addWindow(5001, 12, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let otherFloating = addWindow(5001, 13, to: fixture.workspace2, mode: .floating, manager: fixture.manager)

        XCTAssertTrue(fixture.manager.isFloatingFocusToggleSource(floating, in: fixture.workspace1))
        XCTAssertFalse(fixture.manager.isFloatingFocusToggleSource(tiled, in: fixture.workspace1))
        XCTAssertFalse(fixture.manager.isFloatingFocusToggleSource(otherFloating, in: fixture.workspace1))
        XCTAssertFalse(fixture.manager.isFloatingFocusToggleSource(nil, in: fixture.workspace1))
    }

    func testFloatingTargetsFollowAStableOrderWithinTheWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5003, 31, to: fixture.workspace1, manager: fixture.manager)
        let first = addWindow(5003, 33, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let second = addWindow(5004, 32, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = addWindow(5005, 34, to: fixture.workspace2, mode: .floating, manager: fixture.manager)
        _ = fixture.manager.rememberFocus(tiled, in: fixture.workspace1)
        let manager = fixture.manager
        let workspace = fixture.workspace1

        XCTAssertEqual(manager.floatingFocusToggleTarget(after: tiled, cycleStart: nil, in: workspace), first)
        XCTAssertEqual(manager.floatingFocusToggleTarget(after: first, cycleStart: first, in: workspace), second)
        XCTAssertEqual(manager.floatingFocusToggleTarget(after: second, cycleStart: first, in: workspace), tiled)
        XCTAssertEqual(manager.floatingFocusToggleTarget(after: second, cycleStart: second, in: workspace), first)

        XCTAssertEqual(manager.focusToggleCycleAllTarget(after: nil, in: workspace), first)
        XCTAssertEqual(manager.focusToggleCycleAllTarget(after: tiled, in: workspace), first)
        XCTAssertEqual(manager.focusToggleCycleAllTarget(after: first, in: workspace), second)
        XCTAssertEqual(manager.focusToggleCycleAllTarget(after: second, in: workspace), tiled)
    }

    func testTargetIsAbsentWithoutAnotherWindowOnTheWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5006, 41, to: fixture.workspace1, manager: fixture.manager)
        _ = addWindow(5006, 42, to: fixture.workspace2, mode: .floating, manager: fixture.manager)

        XCTAssertNil(fixture.manager.floatingFocusToggleTarget(after: tiled, cycleStart: nil, in: fixture.workspace1))
        XCTAssertNil(fixture.manager.focusToggleCycleAllTarget(after: tiled, in: fixture.workspace1))
    }

    func testToggleFromTiledFocusFocusesTheFirstFloatingWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5007, 51, to: fixture.workspace1, manager: fixture.manager)
        let first = addWindow(5007, 52, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = addWindow(5007, 53, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        XCTAssertTrue(fixture.manager.setManagedFocus(tiled, in: fixture.workspace1))

        XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
        XCTAssertEqual(fixture.manager.pendingFocusedToken, first)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, first)
    }

    func testToggleFromTheLastFloatingWindowReturnsToTheRememberedTile() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        _ = addWindow(5008, 201, to: fixture.workspace1, manager: fixture.manager)
        let rememberedTiled = addWindow(5008, 202, to: fixture.workspace1, manager: fixture.manager)
        let floating = addWindow(5008, 203, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = fixture.manager.rememberFocus(rememberedTiled, in: fixture.workspace1)
        XCTAssertTrue(fixture.manager.setManagedFocus(floating, in: fixture.workspace1))

        XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, rememberedTiled)
    }

    func testRepeatedTogglesVisitEveryFloatingWindowThenReturnToTiled() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        _ = addWindow(5013, 100, to: fixture.workspace1, manager: fixture.manager)
        let tiled = addWindow(5013, 101, to: fixture.workspace1, manager: fixture.manager)
        let first = addWindow(5013, 102, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let second = addWindow(5013, 103, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let third = addWindow(5014, 104, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = fixture.manager.rememberFocus(tiled, in: fixture.workspace1)
        XCTAssertTrue(fixture.manager.setManagedFocus(tiled, in: fixture.workspace1))

        for expected in [first, second, third, tiled, third, first, second, tiled] {
            XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            try confirmRequestedFocus(on: expected, fixture: fixture)
        }
    }

    func testCycleStartsAtTheRememberedFloatingWindowAndVisitsTheRest() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5018, 131, to: fixture.workspace1, manager: fixture.manager)
        let first = addWindow(5018, 132, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let second = addWindow(5018, 133, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let third = addWindow(5018, 134, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = fixture.manager.rememberFocus(second, in: fixture.workspace1)
        _ = fixture.manager.rememberFocus(tiled, in: fixture.workspace1)
        XCTAssertTrue(fixture.manager.setManagedFocus(tiled, in: fixture.workspace1))

        for expected in [second, third, first, tiled] {
            XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            try confirmRequestedFocus(on: expected, fixture: fixture)
        }
    }

    func testCycleAllWindowsSettingAlsoVisitsTiledWindows() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        fixture.controller.settings.focus.floatingFocusToggleCyclesAllWindows = true
        let firstTiled = addWindow(5016, 121, to: fixture.workspace1, manager: fixture.manager)
        let secondTiled = addWindow(5016, 122, to: fixture.workspace1, manager: fixture.manager)
        let floating = addWindow(5016, 123, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = addWindow(5017, 124, to: fixture.workspace2, manager: fixture.manager)
        _ = fixture.manager.rememberFocus(secondTiled, in: fixture.workspace1)
        XCTAssertTrue(fixture.manager.setManagedFocus(firstTiled, in: fixture.workspace1))

        for expected in [secondTiled, floating, firstTiled] {
            XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            try confirmRequestedFocus(on: expected, fixture: fixture)
        }
    }

    func testCycleAllWindowsSettingVisitsAnInactiveTab() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        fixture.controller.settings.focus.floatingFocusToggleCyclesAllWindows = true
        let firstTab = addWindow(5021, 161, to: fixture.workspace1, manager: fixture.manager)
        let secondTab = addWindow(5021, 162, to: fixture.workspace1, manager: fixture.manager)
        let engine = NiriLayoutEngine()
        fixture.controller.niriEngine = engine
        let (firstNode, secondNode) = fixture.manager.withEngineMutationScope {
            let first = engine.addWindow(token: firstTab, to: fixture.workspace1, afterSelection: nil)
            let second = engine.addWindow(token: secondTab, to: fixture.workspace1, afterSelection: first.id)
            return (first, second)
        }
        let column = try XCTUnwrap(engine.column(of: firstNode))
        fixture.manager.withEngineMutationScope {
            var state = ViewportState(selectedNodeId: firstNode.id)
            XCTAssertTrue(engine.consumeWindow(
                secondNode, into: column, enteringFrom: .right,
                context: .init(
                    workspaceId: fixture.workspace1, motion: .disabled,
                    workingFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
                    gaps: 12, orientation: .horizontal
                ), state: &state
            ))
        }
        let firstIndex = try XCTUnwrap(column.windowNodes.firstIndex { $0 === firstNode })
        fixture.manager.withEngineMutationScope {
            column.setActiveTileIdx(firstIndex)
            XCTAssertTrue(engine.setColumnDisplay(
                .tabbed, for: column, in: fixture.workspace1, motion: .disabled, orientation: .horizontal
            ))
        }
        fixture.manager.setHiddenState(
            HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .layoutTransient(.right)),
            for: secondTab
        )
        XCTAssertTrue(fixture.manager.setManagedFocus(firstTab, in: fixture.workspace1))

        XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
        try confirmRequestedFocus(on: secondTab, fixture: fixture)
        XCTAssertTrue(column.windowNodes[column.activeTileIdx] === secondNode)
    }

    func testHidingTheCycleStartStillReturnsToTheTile() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5020, 151, to: fixture.workspace1, manager: fixture.manager)
        let first = addWindow(5020, 152, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let second = addWindow(5020, 153, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let third = addWindow(5020, 154, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = fixture.manager.rememberFocus(tiled, in: fixture.workspace1)
        XCTAssertTrue(fixture.manager.setManagedFocus(tiled, in: fixture.workspace1))

        for expected in [first, second] {
            XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            try confirmRequestedFocus(on: expected, fixture: fixture)
        }
        fixture.manager.setHiddenState(
            HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .scratchpad),
            for: first
        )

        for expected in [third, tiled] {
            XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            try confirmRequestedFocus(on: expected, fixture: fixture)
        }
    }

    func testPressBeforeFocusConfirmationStepsOnFromThePendingTarget() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5022, 171, to: fixture.workspace1, manager: fixture.manager)
        let first = addWindow(5022, 172, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let second = addWindow(5022, 173, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = fixture.manager.rememberFocus(tiled, in: fixture.workspace1)
        XCTAssertTrue(fixture.manager.setManagedFocus(tiled, in: fixture.workspace1))

        XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
        XCTAssertEqual(fixture.manager.pendingFocusedToken, first)
        XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
        XCTAssertEqual(fixture.manager.pendingFocusedToken, second)
    }

    func testToggleWrapsBetweenFloatingWindowsWhenNothingIsTiled() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let first = addWindow(5015, 111, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let second = addWindow(5015, 112, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        XCTAssertTrue(fixture.manager.setManagedFocus(first, in: fixture.workspace1))

        for expected in [second, first] {
            XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)
            try confirmRequestedFocus(on: expected, fixture: fixture)
        }
    }

    func testToggleBringsUpOneFloatingWindowAtATime() throws {
        var orderedWindowIds: [UInt32] = []
        let fixture = try makeFixture(secondMonitor: true, orderWindow: { orderedWindowIds.append($0) })
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5011, 91, to: fixture.workspace1, manager: fixture.manager)
        let first = addWindow(5011, 92, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let second = addWindow(5012, 94, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = addWindow(5012, 93, to: fixture.workspace2, mode: .floating, manager: fixture.manager)
        XCTAssertTrue(fixture.manager.visibleWorkspaceIds().contains(fixture.workspace2))
        XCTAssertTrue(fixture.manager.setManagedFocus(tiled, in: fixture.workspace1))

        XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
        XCTAssertEqual(orderedWindowIds, [])
        XCTAssertEqual(fixture.manager.pendingFocusedToken, first)
        try confirmRequestedFocus(on: first, fixture: fixture)

        XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
        XCTAssertEqual(orderedWindowIds, [91], "The previous floating window goes behind the tiled window")
        XCTAssertEqual(fixture.manager.pendingFocusedToken, second)
    }

    func testToggleWithoutACounterpartReportsNoChange() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5009, 71, to: fixture.workspace1, manager: fixture.manager)
        XCTAssertTrue(fixture.manager.setManagedFocus(tiled, in: fixture.workspace1))

        XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .noChange)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)

        let floatingFixture = try makeFixture()
        defer { floatingFixture.controller.layoutRefreshController.resetState() }
        let floating = addWindow(
            5010,
            81,
            to: floatingFixture.workspace1,
            mode: .floating,
            manager: floatingFixture.manager
        )
        XCTAssertTrue(floatingFixture.manager.setManagedFocus(floating, in: floatingFixture.workspace1))

        XCTAssertEqual(floatingFixture.controller.toggleFloatingFocus(), .noChange)
    }

    private func confirmRequestedFocus(on token: WindowToken, fixture: Fixture) throws {
        let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(request.token, token)
        XCTAssertTrue(
            fixture.manager.confirmManagedFocus(
                token,
                in: fixture.workspace1,
                activateWorkspaceOnMonitor: false,
                requestId: request.requestId
            )
        )
        XCTAssertNotNil(fixture.controller.intentLedger.confirmManagedRequest(
            token: token,
            source: .focusedWindowChanged
        ))
    }

    private func addWindow(
        _ pid: pid_t,
        _ windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        manager: WorkspaceManager
    ) -> WindowToken {
        manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: mode
        )
    }

    private func makeFixture(
        secondMonitor: Bool = false,
        orderWindow: @escaping (UInt32) -> Void = { _ in }
    ) throws -> Fixture {
        let monitor = Monitor(
            id: .init(displayId: 472_000),
            displayId: 472_000,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "FloatingFocusToggle"
        )
        let monitor2 = Monitor(
            id: .init(displayId: 472_001),
            displayId: 472_001,
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "FloatingFocusToggle 2"
        )
        let monitors = secondMonitor ? [monitor, monitor2] : [monitor]
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloatingFocusToggleTests-\(UUID().uuidString)", isDirectory: true)
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
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: monitors.last!)),
                layoutType: .niri
            )
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in },
                orderWindow: orderWindow
            )
        )
        controller.workspaceManager.applyMonitorConfigurationChange(monitors)
        controller.workspaceManager.applySettings()
        controller.niriLayoutHandler.enableNiriLayout()
        let workspace1 = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        let workspace2 = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspace1, on: monitor.id))
        if secondMonitor {
            XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspace2, on: monitor2.id))
        }
        controller.layoutRefreshController.resetState()

        return Fixture(
            controller: controller,
            manager: controller.workspaceManager,
            workspace1: workspace1,
            workspace2: workspace2
        )
    }
}
