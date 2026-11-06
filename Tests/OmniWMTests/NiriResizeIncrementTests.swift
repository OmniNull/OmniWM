// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class NiriResizeIncrementTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let column: NiriContainer
        let window: NiriWindow
        let secondarySpan: CGFloat
    }

    func testContainerPrimaryResizeUsesCurrentIncrement() throws {
        try assertResize(
            grow: .resizeContainerPrimarySpan(grow: true),
            shrink: .resizeContainerPrimarySpan(grow: false),
            primary: true
        )
    }

    func testWindowPrimaryResizeUsesCurrentIncrement() throws {
        try assertResize(
            grow: .resizeWindowPrimarySpan(grow: true),
            shrink: .resizeWindowPrimarySpan(grow: false),
            primary: true
        )
    }

    func testWindowSecondaryResizeUsesCurrentIncrement() throws {
        try assertResize(
            grow: .resizeWindowSecondarySpan(grow: true),
            shrink: .resizeWindowSecondarySpan(grow: false),
            primary: false
        )
    }

    func testLiteralIPCResizeKeepsItsAmount() throws {
        let requests: [(IPCSizingCommand, Bool)] = [
            (.setContainerPrimarySpan(change: .adjustProportion(10)), true),
            (.setWindowPrimarySpan(change: .adjustProportion(10)), true),
            (.setWindowSecondarySpan(change: .adjustProportion(10)), false)
        ]
        for (request, primary) in requests {
            let fixture = try makeFixture()
            defer { fixture.controller.layoutRefreshController.resetState() }
            fixture.controller.settings.niri.resizeStepPercent = 7
            let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "resize-test")
            XCTAssertEqual(router.handle(.sizing(request)), .executed)
            assertSpan(fixture, primary: primary, expected: primary ? 0.6 : 300 + fixture.secondarySpan * 0.1)
        }
    }

    func testConfiguredAndLiteralSizingCommandsRejectDwindle() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        fixture.controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(name: "1", layoutType: .dwindle)
        ]
        let actions: [SizingAction] = [
            .resizeContainerPrimarySpan(grow: true), .resizeContainerPrimarySpan(grow: false),
            .resizeWindowPrimarySpan(grow: true), .resizeWindowPrimarySpan(grow: false),
            .resizeWindowSecondarySpan(grow: true), .resizeWindowSecondarySpan(grow: false)
        ]
        for action in actions {
            XCTAssertEqual(HotkeyCommand.sizing(action).layoutCompatibility, .niri)
            XCTAssertEqual(fixture.controller.commandHandler.performCommand(.sizing(action)), .ignoredLayoutMismatch)
        }
        let router = IPCCommandRouter(controller: fixture.controller, sessionToken: "resize-test")
        for amount in [-10.0, 5.0, 10.0] {
            let requests: [IPCSizingCommand] = [
                .setContainerPrimarySpan(change: .adjustProportion(amount)),
                .setWindowPrimarySpan(change: .adjustProportion(amount)),
                .setWindowSecondarySpan(change: .adjustProportion(amount))
            ]
            for request in requests {
                let command = HotkeyCommand(ipc: request)
                XCTAssertEqual(command.layoutCompatibility, .niri)
                XCTAssertEqual(router.handle(.sizing(request)), .ignoredLayoutMismatch)
            }
        }
    }

    private func assertResize(grow: SizingAction, shrink: SizingAction, primary: Bool) throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let base: CGFloat = primary ? 0.5 : 300
        let span: CGFloat = primary ? 1 : fixture.secondarySpan
        let handler = fixture.controller.commandHandler

        XCTAssertEqual(handler.performCommand(.sizing(grow)), .executed)
        assertSpan(fixture, primary: primary, expected: base + span * 0.05)
        XCTAssertEqual(handler.performCommand(.sizing(shrink)), .executed)
        assertSpan(fixture, primary: primary, expected: base)

        fixture.controller.layoutRefreshController.resetState()
        fixture.controller.settings.niri.resizeStepPercent = 7
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefreshTask)
        assertSpan(fixture, primary: primary, expected: base)
        XCTAssertEqual(handler.performCommand(.sizing(grow)), .executed)
        assertSpan(fixture, primary: primary, expected: base + span * 0.07)
        XCTAssertEqual(handler.performCommand(.sizing(shrink)), .executed)
        assertSpan(fixture, primary: primary, expected: base)
    }

    private func assertSpan(_ fixture: Fixture, primary: Bool, expected: CGFloat) {
        if primary {
            guard case let .proportion(value) = fixture.column.width else {
                return XCTFail("Expected proportional container span")
            }
            XCTAssertEqual(value, expected)
        } else {
            guard case let .fixed(value) = fixture.window.height else {
                return XCTFail("Expected fixed window span")
            }
            XCTAssertEqual(value, expected, accuracy: 0.000001)
        }
    }

    private func makeFixture() throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMNiriResizeIncrementTests")
        controller.motionPolicy.animationsEnabled = false
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let monitor = Monitor(
            id: .init(displayId: 47_500), displayId: 47_500,
            frame: frame, visibleFrame: frame, hasNotch: false, name: "Resize Increment"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let tokens = [
            WindowToken(pid: 475_001, windowId: 475_101),
            WindowToken(pid: 475_002, windowId: 475_102)
        ]
        for token in tokens {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        let window = engine.addWindow(token: tokens[0], to: workspaceId, afterSelection: nil)
        let sibling = engine.addWindow(token: tokens[1], to: workspaceId, afterSelection: window.id)
        let column = try XCTUnwrap(engine.findColumn(containing: window, in: workspaceId))
        let siblingColumn = try XCTUnwrap(engine.findColumn(containing: sibling, in: workspaceId))
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            column.appendChild(sibling)
            siblingColumn.remove()
            column.width = .proportion(0.5)
            window.height = .fixed(300)
            engine.activateWindow(window.id, in: workspaceId)
        }
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: window.id, focusedToken: tokens[0], in: workspaceId, onMonitor: monitor.id
        )
        return Fixture(
            controller: controller, column: column, window: window,
            secondarySpan: controller.niriWorkingFrame(for: monitor).height - controller.innerGap(for: monitor)
        )
    }
}
