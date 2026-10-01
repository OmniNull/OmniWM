// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WorkspaceAccordionCommandTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
    }

    func testRelayoutSyncsWorkspaceAccordionFlagIntoEngine() throws {
        let fixture = try makeFixture(accordion: true)
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertTrue(fixture.engine.isAccordion(in: fixture.workspaceId))

        fixture.controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(name: "1", layoutType: .niri)
        ]
        relayout(fixture.controller, fixture.workspaceId)

        XCTAssertFalse(fixture.engine.isAccordion(in: fixture.workspaceId))
    }

    func testToggleAccordionTurnsOnOffAndOnAgain() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let handler = fixture.controller.commandHandler
        let settings = fixture.controller.settings.workspaces

        XCTAssertEqual(handler.performCommand(.workspace(.toggleAccordion)), .executed)
        XCTAssertTrue(settings.isAccordion(for: "1"))
        XCTAssertTrue(fixture.engine.isAccordion(in: fixture.workspaceId))

        XCTAssertEqual(handler.performCommand(.workspace(.toggleAccordion)), .executed)
        XCTAssertFalse(settings.isAccordion(for: "1"))
        XCTAssertFalse(fixture.engine.isAccordion(in: fixture.workspaceId))

        XCTAssertEqual(handler.performCommand(.workspace(.toggleAccordion)), .executed)
        XCTAssertTrue(settings.isAccordion(for: "1"))
        XCTAssertTrue(fixture.engine.isAccordion(in: fixture.workspaceId))
    }

    func testFocusRightMovesAccordionToNextColumn() throws {
        let fixture = try makeFixture(accordion: true)
        defer { fixture.controller.layoutRefreshController.resetState() }
        let manager = fixture.controller.workspaceManager
        let columns = fixture.engine.columns(in: fixture.workspaceId)
        let first = try XCTUnwrap(columns.first?.windowNodes.first)
        _ = manager.commitWorkspaceSelection(
            nodeId: first.id, focusedToken: first.token, in: fixture.workspaceId, onMonitor: fixture.monitor.id
        )
        manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.activeColumnIndex = 0
        }
        relayout(fixture.controller, fixture.workspaceId)

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.focus(.right)), .executed)
        relayout(fixture.controller, fixture.workspaceId)

        let state = manager.niriViewportState(for: fixture.workspaceId)
        XCTAssertEqual(state.selectedNodeId, columns[1].windowNodes.first?.id)
        XCTAssertEqual(state.activeColumnIndex, 1)
        XCTAssertEqual(fixture.engine.states[fixture.workspaceId]?.accordionActiveColumnId, columns[1].id)
    }

    func testFocusRightRaisesNewAccordionColumn() throws {
        final class Recorder {
            var raises = 0
        }
        let recorder = Recorder()
        let fixture = try makeFixture(
            accordion: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in recorder.raises += 1 }
            )
        )
        defer { fixture.controller.layoutRefreshController.resetState() }
        let manager = fixture.controller.workspaceManager
        let first = try XCTUnwrap(fixture.engine.columns(in: fixture.workspaceId).first?.windowNodes.first)
        _ = manager.commitWorkspaceSelection(
            nodeId: first.id, focusedToken: first.token, in: fixture.workspaceId, onMonitor: fixture.monitor.id
        )
        manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.activeColumnIndex = 0
        }
        recorder.raises = 0

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.focus(.right)), .executed)

        XCTAssertGreaterThan(recorder.raises, 0)
    }

    func testToggleOffRevealsActiveColumn() throws {
        let fixture = try makeFixture(accordion: true)
        defer { fixture.controller.layoutRefreshController.resetState() }
        let manager = fixture.controller.workspaceManager
        let window = try XCTUnwrap(fixture.engine.columns(in: fixture.workspaceId).first?.windowNodes.first)
        _ = manager.commitWorkspaceSelection(
            nodeId: window.id, focusedToken: window.token, in: fixture.workspaceId, onMonitor: fixture.monitor.id
        )
        manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.activeColumnIndex = 0
            state.viewOffset = 50_000
        }

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.workspace(.toggleAccordion)), .executed)

        XCTAssertFalse(fixture.engine.isAccordion(in: fixture.workspaceId))
        XCTAssertLessThan(
            abs(manager.niriViewportState(for: fixture.workspaceId).viewOffset),
            fixture.monitor.frame.width
        )
    }

    func testSettingsTurningAccordionOffRevealsActiveColumn() throws {
        let fixture = try makeFixture(accordion: true)
        defer { fixture.controller.layoutRefreshController.resetState() }
        let manager = fixture.controller.workspaceManager
        let window = try XCTUnwrap(fixture.engine.columns(in: fixture.workspaceId).first?.windowNodes.first)
        _ = manager.commitWorkspaceSelection(
            nodeId: window.id, focusedToken: window.token, in: fixture.workspaceId, onMonitor: fixture.monitor.id
        )
        manager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.activeColumnIndex = 0
            state.viewOffset = 50_000
        }

        fixture.controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(name: "1", layoutType: .niri, accordion: false)
        ]
        relayout(fixture.controller, fixture.workspaceId)

        XCTAssertFalse(fixture.engine.isAccordion(in: fixture.workspaceId))
        XCTAssertLessThan(
            abs(manager.niriViewportState(for: fixture.workspaceId).viewOffset),
            fixture.monitor.frame.width
        )
    }

    func testColumnScrollIsOffOnAccordionWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let mouse = fixture.controller.mouseEventHandler
        let point = CGPoint(x: fixture.monitor.frame.midX, y: fixture.monitor.frame.midY)
        let workspace = try XCTUnwrap(fixture.controller.workspaceManager.descriptor(for: fixture.workspaceId))

        XCTAssertNotNil(mouse.resolveScrollContext(at: point))
        XCTAssertTrue(mouse.supportsNiriColumnScroll(in: workspace))

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.workspace(.toggleAccordion)), .executed)

        XCTAssertNil(mouse.resolveScrollContext(at: point))
        XCTAssertFalse(mouse.supportsNiriColumnScroll(in: workspace))
    }

    func testMouseFocusRaisesOnAccordionWorkspaceWithoutRaiseSetting() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let controller = fixture.controller
        controller.settings.focus.raiseOnMouseFocus = false
        let window = try XCTUnwrap(fixture.engine.columns(in: fixture.workspaceId).last?.windowNodes.first)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: window.token))

        XCTAssertFalse(controller.raisesOnMouseFocus(entry))
        XCTAssertEqual(controller.accordionFocusRaiseOrder(for: entry), [])

        XCTAssertEqual(controller.commandHandler.performCommand(.workspace(.toggleAccordion)), .executed)

        XCTAssertTrue(controller.raisesOnMouseFocus(entry))
        XCTAssertEqual(controller.accordionFocusRaiseOrder(for: entry), [window.token])
    }

    func testToggleAccordionIgnoresDwindleWorkspace() throws {
        let fixture = try makeFixture(layoutType: .dwindle)
        defer { fixture.controller.layoutRefreshController.resetState() }

        XCTAssertEqual(HotkeyCommand.workspace(.toggleAccordion).layoutCompatibility, .niri)
        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.workspace(.toggleAccordion)),
            .ignoredLayoutMismatch
        )
        XCTAssertFalse(fixture.controller.settings.workspaces.isAccordion(for: "1"))
    }

    func testIPCToggleAccordionRoutesToCommand() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "accordion-test")

        XCTAssertEqual(router.handle(.workspaceLayout(.toggleAccordion)), .executed)
        XCTAssertTrue(fixture.controller.settings.workspaces.isAccordion(for: "1"))
    }

    func testToggleAccordionActionSpec() throws {
        let spec = try XCTUnwrap(ActionCatalog.spec(for: "toggleAccordion"))

        XCTAssertEqual(spec.command, .workspace(.toggleAccordion))
        XCTAssertEqual(spec.title, "Toggle Accordion")
        XCTAssertEqual(spec.category, .layout)
        XCTAssertEqual(spec.defaultBinding, .unassigned)
        XCTAssertEqual(spec.layoutCompatibility, .niri)
        XCTAssertEqual(spec.ipcCommandName, .workspaceLayout(.toggleAccordion))
    }

    private func relayout(_ controller: WMController, _ workspaceId: WorkspaceDescriptor.ID) {
        _ = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }
    }

    private func makeFixture(
        accordion: Bool = false,
        layoutType: LayoutType = .niri,
        windowFocusOperations: WindowFocusOperations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
    ) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMWorkspaceAccordionCommandTests",
            windowFocusOperations: windowFocusOperations
        )
        controller.motionPolicy.animationsEnabled = false
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let monitor = Monitor(
            id: .init(displayId: 47_600), displayId: 47_600,
            frame: frame, visibleFrame: frame, hasNotch: false, name: "Accordion"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(name: "1", layoutType: layoutType, accordion: accordion)
        ]
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        for index in 0 ..< 3 {
            _ = WindowAdmissionTestSupport.track(
                WindowToken(pid: 476_001, windowId: 476_101 + index), in: workspaceId, controller: controller
            )
        }
        relayout(controller, workspaceId)
        return Fixture(controller: controller, engine: engine, workspaceId: workspaceId, monitor: monitor)
    }
}
