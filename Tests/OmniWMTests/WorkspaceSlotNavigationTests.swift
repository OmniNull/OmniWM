// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WorkspaceSlotNavigationTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let controller: WMController
        let router: IPCCommandRouter
        let monitorA: Monitor
        let monitorB: Monitor
        let workspace1: WorkspaceDescriptor.ID
        let workspace2: WorkspaceDescriptor.ID
        let workspace3: WorkspaceDescriptor.ID

        var manager: WorkspaceManager {
            controller.workspaceManager
        }

        var navigation: WorkspaceNavigationHandler {
            controller.workspaceNavigationHandler
        }
    }

    func testSlotResolvesPositionInInteractionMonitorOrder() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertEqual(fixture.navigation.workspaceSlot(1)?.id, fixture.workspace1)
        XCTAssertEqual(fixture.navigation.workspaceSlot(2)?.id, fixture.workspace3)
        XCTAssertNil(fixture.navigation.workspaceSlot(3))
        XCTAssertNil(fixture.navigation.workspaceSlot(0))

        _ = fixture.manager.setInteractionMonitor(fixture.monitorB.id)
        XCTAssertEqual(fixture.navigation.workspaceSlot(1)?.id, fixture.workspace2)
        XCTAssertNil(fixture.navigation.workspaceSlot(2))
    }

    func testSwitchWorkspaceSlotActivatesWorkspaceOnInteractionMonitorOnly() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertTrue(fixture.navigation.switchWorkspaceSlot(2))
        XCTAssertEqual(fixture.manager.activeWorkspace(on: fixture.monitorA.id)?.id, fixture.workspace3)
        XCTAssertEqual(fixture.manager.activeWorkspace(on: fixture.monitorB.id)?.id, fixture.workspace2)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace3)

        XCTAssertFalse(fixture.navigation.switchWorkspaceSlot(2))
        XCTAssertFalse(fixture.navigation.switchWorkspaceSlot(3))
        XCTAssertEqual(fixture.manager.activeWorkspace(on: fixture.monitorA.id)?.id, fixture.workspace3)

        fixture.navigation.switchWorkspace(index: 1)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace2)
        XCTAssertEqual(fixture.manager.activeWorkspace(on: fixture.monitorA.id)?.id, fixture.workspace3)
    }

    func testWorkspaceCommandRoutesTransferFocusAfterMouseWarp() throws {
        let routes: [(String, (Fixture) -> ExternalCommandResult)] = [
            ("shortcut", { $0.controller.commandHandler.performCommand(.workspace(.switchTo(1))) }),
            ("numeric IPC", { $0.router.handle(IPCCommandRequest(.workspace(.switchTo(workspaceNumber: 2)))) }),
            ("anywhere IPC", { $0.router.handle(IPCCommandRequest(.workspace(.switchAnywhere(workspaceNumber: 2)))) }),
            ("slot IPC", { $0.router.handle(IPCCommandRequest(.workspace(.switchSlot(slotNumber: 1)))) }),
            ("raw name IPC", { $0.router.handle(IPCWorkspaceRequest.focusName(target: .rawID("2"))) }),
            (
                "display name IPC",
                { $0.router.handle(IPCWorkspaceRequest.focusName(target: .displayName("Workspace Two"))) }
            )
        ]
        for (label, invoke) in routes {
            var focusedWindowIds: [UInt32] = []
            let fixture = try makeFixture(
                windowFocusOperations: WindowFocusOperations(
                    activateApp: { _ in },
                    focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                    raiseWindow: { _ in }
                )
            )
            defer { resetWarpState(in: fixture) }
            let scenario = try warpPointerToMonitorB(in: fixture)
            XCTAssertTrue(focusedWindowIds.isEmpty)

            blockLayoutRefresh(in: fixture, for: fixture.workspace1)
            XCTAssertEqual(invoke(fixture), .executed, label)
            try runPendingPostLayoutActions(in: fixture)

            try assertBrowserFocused(scenario, focusedWindowIds: focusedWindowIds, in: fixture)
        }
    }

    func testWorkspaceSlotShortcutTransfersFocusAfterMouseWarp() throws {
        var focusedWindowIds: [UInt32] = []
        let fixture = try makeFixture(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                raiseWindow: { _ in }
            )
        )
        defer { resetWarpState(in: fixture) }
        let scenario = try warpPointerToMonitorB(in: fixture)
        XCTAssertTrue(focusedWindowIds.isEmpty)

        blockLayoutRefresh(in: fixture, for: fixture.workspace1)
        XCTAssertTrue(fixture.navigation.switchWorkspaceSlot(1))
        try runPendingPostLayoutActions(in: fixture)

        try assertBrowserFocused(scenario, focusedWindowIds: focusedWindowIds, in: fixture)
    }

    func testSlotAndIPCSwitchesAreNoOpsWhenWorkspaceHasNativeFocus() throws {
        let fixture = try makeFixture()
        let terminal = addFocusedWindow(to: fixture.workspace1, in: fixture)
        fixture.controller.layoutRefreshController.resetState()
        defer { fixture.controller.layoutRefreshController.resetState() }

        assertVisibleWorkspaceSwitchesAreNoOps(in: fixture)

        XCTAssertEqual(fixture.manager.nativeManagedFocusToken, terminal)
    }

    func testSlotAndIPCSwitchesAreNoOpsWhenNoManagedWindowHasNativeFocus() throws {
        var focusedWindowIds: [UInt32] = []
        let fixture = try makeFixture(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                raiseWindow: { _ in }
            )
        )
        let manager = fixture.manager
        _ = addFocusedWindow(to: fixture.workspace1, in: fixture)
        XCTAssertTrue(manager.recordExternalFocus(pid: 473_900, windowId: 90))
        XCTAssertNil(manager.nativeManagedFocusToken)
        fixture.controller.layoutRefreshController.resetState()
        defer { fixture.controller.layoutRefreshController.resetState() }

        assertVisibleWorkspaceSwitchesAreNoOps(in: fixture)

        XCTAssertTrue(focusedWindowIds.isEmpty)
        XCTAssertTrue(manager.nativeFocusOwner.isExternal)

        XCTAssertTrue(manager.clearNativeFocusOwner())
        XCTAssertEqual(manager.nativeFocusOwner, .none)

        assertVisibleWorkspaceSwitchesAreNoOps(in: fixture)

        XCTAssertTrue(focusedWindowIds.isEmpty)
        XCTAssertEqual(manager.nativeFocusOwner, .none)
    }

    func testMoveFocusedWindowToSlotUsesInteractionMonitorOrder() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        XCTAssertFalse(fixture.navigation.moveFocusedWindow(toWorkspaceSlot: 2))

        let token = addFocusedWindow(to: fixture.workspace1, in: fixture)

        XCTAssertTrue(fixture.navigation.moveFocusedWindow(toWorkspaceSlot: 2))
        XCTAssertEqual(fixture.manager.workspace(for: token), fixture.workspace3)
        XCTAssertFalse(fixture.navigation.moveFocusedWindow(toWorkspaceSlot: 3))
        XCTAssertEqual(fixture.manager.workspace(for: token), fixture.workspace3)
    }

    func testHotkeyCommandsRouteToSlotNavigation() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let token = addFocusedWindow(to: fixture.workspace1, in: fixture)

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.workspace(.moveToSlot(2))), .executed)
        XCTAssertEqual(fixture.manager.workspace(for: token), fixture.workspace3)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.workspace(.switchSlot(2))), .executed)
        XCTAssertEqual(fixture.manager.activeWorkspace(on: fixture.monitorA.id)?.id, fixture.workspace3)
    }

    func testScriptBindsMonitorLocalSlotAndWorkspaceIDIndependently() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let workspaceNumber = try XCTUnwrap(fixture.manager.descriptor(for: fixture.workspace2)?.name)
        let source = """
        local wm = omniwm
        wm.keymap.set("Control+Option+S", wm.cmd.switchWorkspace("slot", "\(workspaceNumber)"))
        wm.keymap.set("Control+Option+W", wm.cmd.switchWorkspace("\(workspaceNumber)"))
        """
        let result = try await ConfigScriptLoader().evaluate(
            Data(source.utf8), hyperMask: fixture.controller.settings.hyperKeyModifiers.carbonMask
        )
        let commands = result.bindings.map(\.command)
        let number = try XCTUnwrap(Int(workspaceNumber))
        XCTAssertEqual(commands, [.workspace(.switchSlot(number)), .workspace(.switchTo(number - 1))])
        let slot = try XCTUnwrap(commands.first)
        let named = try XCTUnwrap(commands.last)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(slot), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace3)
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(named), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace2)
        XCTAssertEqual(fixture.manager.activeWorkspace(on: fixture.monitorA.id)?.id, fixture.workspace3)
    }

    func testRouterDistinguishesInvalidAbsentAndUnchangedSlots() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertEqual(
            fixture.router.handle(IPCCommandRequest(.workspace(.switchSlot(slotNumber: 0)))),
            .invalidArguments
        )
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest(.workspace(.switchSlot(slotNumber: 9)))), .notFound)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest(.workspace(.switchSlot(slotNumber: 1)))), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest(.workspace(.switchSlot(slotNumber: 2)))), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace3)

        XCTAssertEqual(
            fixture.router.handle(IPCCommandRequest(.workspace(.moveToSlot(slotNumber: 0)))),
            .invalidArguments
        )
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest(.workspace(.moveToSlot(slotNumber: 1)))), .notFound)

        let token = addFocusedWindow(to: fixture.workspace3, in: fixture)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest(.workspace(.moveToSlot(slotNumber: 2)))), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest(.workspace(.moveToSlot(slotNumber: 9)))), .notFound)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest(.workspace(.moveToSlot(slotNumber: 1)))), .executed)
        XCTAssertEqual(fixture.manager.workspace(for: token), fixture.workspace1)
    }

    private struct WarpScenario {
        let browser: WindowToken
        let terminal: WindowToken
        let visibleWorkspaces: [Monitor.ID: WorkspaceDescriptor.ID]
    }

    private func warpPointerToMonitorB(in fixture: Fixture) throws -> WarpScenario {
        let controller = fixture.controller
        let manager = fixture.manager
        controller.settings.pointer.enabled = true
        controller.settings.pointer.margin = 2
        controller.settings.pointer.constrainToArrangement = false
        controller.settings.monitors.routingMode = .macOS
        controller.setFocusFollowsMouse(false)
        controller.setMoveMouseToFocusedWindow(false)

        let browser = addFocusedWindow(to: fixture.workspace2, in: fixture, pid: 473_002, windowId: 12)
        let terminal = addFocusedWindow(to: fixture.workspace1, in: fixture)
        controller.layoutRefreshController.resetState()
        let visibleWorkspaces = manager.activeVisibleWorkspaceMap()

        let warpHandler = controller.mouseWarpHandler
        var warpCalls = 0
        warpHandler.activeDisplayBounds = { _ in .infinite }
        warpHandler.warpCursor = { _ in
            warpCalls += 1
            return .success
        }
        warpHandler.postMouseMovedEvent = { _ in }

        controller.mouseEventHandler.dispatchMouseMoved(at: CGPoint(
            x: fixture.monitorA.frame.maxX - 1,
            y: fixture.monitorA.frame.midY
        ))

        XCTAssertEqual(warpCalls, 1)
        XCTAssertEqual(manager.interactionMonitorId, fixture.monitorB.id)
        XCTAssertEqual(controller.activeWorkspace()?.id, fixture.workspace2)
        XCTAssertEqual(manager.nativeManagedFocusToken, terminal)
        return WarpScenario(browser: browser, terminal: terminal, visibleWorkspaces: visibleWorkspaces)
    }

    private func resetWarpState(in fixture: Fixture) {
        fixture.controller.mouseWarpHandler.resetTransientState()
        fixture.controller.layoutRefreshController.resetState()
    }

    private func blockLayoutRefresh(in fixture: Fixture, for workspaceId: WorkspaceDescriptor.ID) {
        let blocker = Task { @MainActor in }
        fixture.controller.layoutRefreshController.layoutState.activeRefreshTask = blocker
        fixture.controller.layoutRefreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [workspaceId]
        )
    }

    private func runPendingPostLayoutActions(in fixture: Fixture) throws {
        let actions = try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions
        )
        XCTAssertEqual(actions.count, 1)
        for action in actions {
            XCTAssertTrue(action.isCurrent(using: fixture.manager))
            action.runIfCurrent(using: fixture.manager)
        }
    }

    private func assertBrowserFocused(
        _ scenario: WarpScenario,
        focusedWindowIds: [UInt32],
        in fixture: Fixture
    ) throws {
        XCTAssertEqual(focusedWindowIds, [UInt32(scenario.browser.windowId)])
        let request = try XCTUnwrap(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertEqual(request.token, scenario.browser)
        XCTAssertEqual(request.workspaceId, fixture.workspace2)
        XCTAssertEqual(fixture.manager.activeVisibleWorkspaceMap(), scenario.visibleWorkspaces)
    }

    private func assertNoSwitchQueued(in fixture: Fixture) {
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefreshTask)
    }

    private func assertVisibleWorkspaceSwitchesAreNoOps(in fixture: Fixture) {
        fixture.navigation.switchWorkspace(index: 0)
        assertNoSwitchQueued(in: fixture)
        XCTAssertFalse(fixture.navigation.switchWorkspaceSlot(1))
        assertNoSwitchQueued(in: fixture)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest(.workspace(.switchTo(workspaceNumber: 1)))), .noChange)
        assertNoSwitchQueued(in: fixture)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest(.workspace(.switchSlot(slotNumber: 1)))), .noChange)
        assertNoSwitchQueued(in: fixture)
        XCTAssertEqual(
            fixture.router.handle(IPCCommandRequest(.workspace(.switchAnywhere(workspaceNumber: 1)))),
            .noChange
        )
        assertNoSwitchQueued(in: fixture)
        for target in [WorkspaceTarget.rawID("1"), .displayName("Workspace One")] {
            XCTAssertEqual(fixture.router.handle(IPCWorkspaceRequest.focusName(target: target)), .noChange)
            assertNoSwitchQueued(in: fixture)
        }
    }

    private func addFocusedWindow(
        to workspaceId: WorkspaceDescriptor.ID,
        in fixture: Fixture,
        pid: pid_t = 473_001,
        windowId: Int = 11
    ) -> WindowToken {
        let token = fixture.manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        fixture.manager.withEngineMutationScope(in: workspaceId) {
            _ = fixture.controller.niriEngine?.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        XCTAssertTrue(fixture.manager.setManagedFocus(token, in: workspaceId))
        XCTAssertEqual(fixture.manager.selectedManagedToken, token)
        return token
    }

    private func makeFixture(
        windowFocusOperations: WindowFocusOperations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
    ) throws -> Fixture {
        let monitorA = makeMonitor(displayId: 473_100, name: "A", frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let monitorB = makeMonitor(
            displayId: 473_101,
            name: "B",
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OmniWMWorkspaceSlotNavigationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
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
                displayName: "Workspace One",
                monitorAssignment: .specificDisplay(OutputId(from: monitorA)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "2",
                displayName: "Workspace Two",
                monitorAssignment: .specificDisplay(OutputId(from: monitorB)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "3",
                monitorAssignment: .specificDisplay(OutputId(from: monitorA)),
                layoutType: .niri
            )
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: windowFocusOperations
        )
        let niriEngine = NiriLayoutEngine()
        niriEngine.animationClock = controller.animationClock
        controller.niriEngine = niriEngine
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitorA, monitorB])
        manager.applySettings()
        let workspace1 = try XCTUnwrap(manager.workspaceId(named: "1"))
        let workspace2 = try XCTUnwrap(manager.workspaceId(named: "2"))
        let workspace3 = try XCTUnwrap(manager.workspaceId(named: "3"))
        XCTAssertTrue(manager.setActiveWorkspace(workspace1, on: monitorA.id, updateInteractionMonitor: false))
        XCTAssertTrue(manager.setActiveWorkspace(workspace2, on: monitorB.id, updateInteractionMonitor: false))
        _ = manager.setInteractionMonitor(monitorA.id)
        controller.layoutRefreshController.resetState()

        return Fixture(
            controller: controller,
            router: IPCCommandRouter(controller: controller, sessionToken: "test"),
            monitorA: monitorA,
            monitorB: monitorB,
            workspace1: workspace1,
            workspace2: workspace2,
            workspace3: workspace3
        )
    }

    private func makeMonitor(displayId: CGDirectDisplayID, name: String, frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: name
        )
    }
}
