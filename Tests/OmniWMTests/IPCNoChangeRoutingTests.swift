// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class IPCNoChangeRoutingTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let router: IPCCommandRouter
        let monitor: Monitor
        let workspace1: WorkspaceDescriptor.ID
        let workspace2: WorkspaceDescriptor.ID
    }

    func testEachIPCRequestThatChangesSomethingCountsOneUserAction() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let controller = fixture.controller
        var counted = controller.userActionCount

        fixture.controller.eventInterpreter.handleIntakeEvent(StampedIntakeEvent(
            seq: 1,
            event: .ipcCommand(IPCCommandIntake(
                perform: { IPCCommandRouter(controller: $0, sessionToken: "test").handle(.raiseAllFloatingWindows) },
                completion: { _ in }
            ))
        ))
        counted += 1
        XCTAssertEqual(controller.userActionCount, counted)

        _ = await IPCApplicationBridge.shellResponse(
            for: .toggle(widget: "clock"),
            id: "test",
            controller: fixture.controller
        )
        counted += 1
        XCTAssertEqual(controller.userActionCount, counted)

        _ = IPCWindowGatherRequestExecutor(controller: fixture.controller, sessionToken: "")
            .response(for: IPCWindowGatherRequest(windowIds: [], from: .workspace), id: "test")
        counted += 1
        XCTAssertEqual(controller.userActionCount, counted)

        let marks = IPCWindowMarkRequestExecutor(controller: fixture.controller)
        _ = marks.response(for: .focus(name: "missing"), id: "test")
        counted += 1
        XCTAssertEqual(controller.userActionCount, counted)

        _ = marks.response(for: .list, id: "test")
        XCTAssertEqual(controller.userActionCount, counted)

        _ = await IPCRuleRouter(controller: fixture.controller, sessionToken: "").handle(.remove(id: "missing"))
        counted += 1
        XCTAssertEqual(controller.userActionCount, counted)
    }

    func testWorkspaceSwitchesDistinguishNoChangeFromAbsentTargets() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.switchTo(workspaceNumber: 1))), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCWorkspaceRequest.focusName(target: .rawID("1"))), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCWorkspaceRequest.focusName(target: .rawID("99"))), .notFound)
        XCTAssertEqual(
            fixture.router.handle(IPCWorkspaceRequest.rename(target: .rawID("1"), displayName: "")),
            .noChange
        )
        XCTAssertEqual(
            fixture.router.handle(IPCWorkspaceRequest.rename(target: .rawID("99"), displayName: "x")),
            .notFound
        )
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.switchTo(workspaceNumber: 7))), .notFound)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace1)

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.switchTo(workspaceNumber: 2))), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace2)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.switchTo(workspaceNumber: 2))), .noChange)
        XCTAssertEqual(
            fixture.router.handle(IPCCommandRequest.workspace(.switchAnywhere(workspaceNumber: 2))),
            .noChange
        )
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.backAndForth)), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace1)
    }

    func testRelativeWorkspaceCommandsReportTheWorkspaceAfterReentrantNavigation() throws {
        for action in [WorkspaceAction.next, .previous, .backAndForth] {
            let fixture = try makeFixture()
            let controller = fixture.controller
            let manager = controller.workspaceManager
            let monitor = fixture.monitor.id
            defer { controller.layoutRefreshController.resetState() }
            controller.settings.workspaceBar.hideEmptyWorkspaces = false
            manager.updateMonitorSession(monitor) { $0.previousVisibleWorkspaceId = fixture.workspace2 }
            var returned = false
            manager.onSessionStateChanged = { _ in
                guard !returned, manager.visibleWorkspaceId(on: monitor) == fixture.workspace2 else { return }
                returned = true
                XCTAssertTrue(manager.setActiveWorkspace(fixture.workspace1, on: monitor))
            }
            defer { manager.onSessionStateChanged = nil }
            XCTAssertEqual(controller.commandHandler.performCommand(.workspace(action)), .noChange)
            XCTAssertTrue(returned)
            XCTAssertEqual(controller.activeWorkspace()?.id, fixture.workspace1)
        }
    }

    func testRelativeWorkspaceResultUsesTheActiveWorkspaceWhileASwipeIsPending() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        let swipe = controller.layoutRefreshController.workspaceSwipe
        let monitor = fixture.monitor
        defer { controller.layoutRefreshController.resetState() }
        controller.settings.workspaceBar.hideEmptyWorkspaces = false
        controller.settings.slideWorkspaceSwitches = true
        controller.motionPolicy.animationsEnabled = false
        let source = WorkspaceSwipePresentation.Workspace(id: fixture.workspace1, items: [])
        let destination = WorkspaceSwipePresentation.Workspace(id: fixture.workspace2, items: [])
        let flight = WorkspaceSwipePresentation.Flight(
            preparation: .init(
                monitor: monitor,
                frame: monitor.visibleFrame,
                source: source,
                previous: nil,
                next: destination
            ),
            destination: destination, axis: .vertical, cumulative: .zero, isNext: true, timestamp: .zero,
            recognitionMovement: nil
        )
        swipe.install(flight, after: nil)
        flight.motion.animateToDestination(startTime: .zero, motion: controller.motionPolicy.snapshot())
        XCTAssertEqual(swipe.pendingSwitchTarget(on: monitor.id), destination.id)
        XCTAssertEqual(controller.commandHandler.performCommand(.workspace(.next)), .noChange)
        XCTAssertEqual(controller.activeWorkspace()?.id, source.id)
    }

    func testAutoBackAndForthAppliesToShortcutsButNotToIPC() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let commands = fixture.controller.commandHandler

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.switchTo(workspaceNumber: 2))), .executed)
        XCTAssertEqual(commands.performCommand(.workspace(.switchTo(1))), .noChange)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace2)

        fixture.controller.settings.workspaces.autoBackAndForth = true
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.switchTo(workspaceNumber: 2))), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.switchSlot(slotNumber: 2))), .noChange)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace2)

        XCTAssertEqual(commands.performCommand(.workspace(.switchTo(1))), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace1)
        XCTAssertEqual(commands.performCommand(.workspace(.switchSlot(1))), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace2)
        XCTAssertEqual(commands.performCommand(.workspace(.switchTo(0))), .executed)
        XCTAssertEqual(fixture.controller.activeWorkspace()?.id, fixture.workspace1)
    }

    func testWindowMovesDistinguishNoChangeFromAbsentTargets() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.moveTo(workspaceNumber: 1))), .notFound)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.moveToMonitor(direction: .right))), .notFound)

        let token = fixture.controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(471_001), windowId: 11),
            pid: 471_001,
            windowId: 11,
            to: fixture.workspace1
        )
        XCTAssertTrue(fixture.controller.workspaceManager.setManagedFocus(token, in: fixture.workspace1))
        XCTAssertEqual(fixture.controller.workspaceManager.selectedManagedToken, token)

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.moveTo(workspaceNumber: 1))), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.moveTo(workspaceNumber: 7))), .notFound)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspace(.moveToMonitor(direction: .right))), .notFound)
        XCTAssertEqual(fixture.controller.workspaceManager.workspace(for: token), fixture.workspace1)
    }

    func testLoadedWorkspaceBindingsRejectTargetsRemovedAfterLoad() async throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        defer { controller.layoutRefreshController.resetState() }
        let manager = controller.workspaceManager
        let target = try XCTUnwrap(manager.descriptor(for: fixture.workspace2)?.name)
        let source = """
        local wm = omniwm
        wm.keymap.set("Control+Option+W", wm.cmd("switch-workspace", "\(target)"))
        wm.keymap.set("Control+Option+N", wm.cmd("switch-workspace", "anywhere", "\(target)"))
        """
        let loaded = try await ConfigScriptLoader().evaluate(
            Data(source.utf8), hyperMask: controller.settings.hyperKeyModifiers.carbonMask
        )
        let number = try XCTUnwrap(Int(target))
        let requests: [IPCCommandRequest] = [
            .workspace(.switchTo(workspaceNumber: number)), .workspace(.switchAnywhere(workspaceNumber: number))
        ]
        XCTAssertEqual(loaded.bindings.count, requests.count)
        controller.settings.workspaces.configurations.removeAll { $0.name == target }
        controller.updateWorkspaceConfig()
        XCTAssertNil(manager.workspaceId(named: target))

        for (binding, request) in zip(loaded.bindings, requests) {
            XCTAssertEqual(controller.commandHandler.performCommand(binding.command), .notFound)
            XCTAssertEqual(fixture.router.handle(request), .notFound)
        }
        XCTAssertEqual(controller.activeWorkspace()?.id, fixture.workspace1)
        XCTAssertNil(manager.workspaceId(named: target))
    }

    func testSatisfiedMaintenanceCommandsReportNoChange() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.rescueOffscreenWindows), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.raiseAllFloatingWindows), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.toggleFloatingFocus), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.workspaceLayout(.set(layout: .niri))), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.monitorFocus(.next)), .noChange)
        XCTAssertEqual(fixture.router.handle(IPCCommandRequest.swapWorkspaceWithMonitor(direction: .left)), .notFound)
    }

    private func makeFixture() throws -> Fixture {
        let monitor = Monitor(
            id: .init(displayId: 471_000),
            displayId: 471_000,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "NoChange"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPCNoChangeRoutingTests-\(UUID().uuidString)", isDirectory: true)
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
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspace1 = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        let workspace2 = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspace1, on: monitor.id))
        controller.layoutRefreshController.resetState()

        return Fixture(
            controller: controller,
            router: IPCCommandRouter(controller: controller, sessionToken: "test"),
            monitor: monitor,
            workspace1: workspace1,
            workspace2: workspace2
        )
    }
}
