// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
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

    func testScriptBindingsExecuteTheirDeclaredResizeAfterVMDestruction() async throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        controller.settings.hotkeyBindings = []
        controller.settings.ipcEnabled = false
        controller.settings.workspaceBar.enabled = false
        let directory = controller.settings.settingsFileURL.deletingLastPathComponent()
        let fileURL = directory.appendingPathComponent("init.luau")
        let increments = [("Control+Option+J", 4), ("Control+Option+K", 12)]
        let source = increments.map { chord, percent in
            #"wm.keymap.set("\#(chord)", wm.cmd("set-container-primary-span", "+\#(percent)%"))"#
        }.joined(separator: "\n")
        try ("local wm = omniwm\n" + source).write(to: fileURL, atomically: true, encoding: .utf8)
        defer {
            controller.stopConfigScript()
            controller.layoutRefreshController.resetState()
            try? FileManager.default.removeItem(at: fileURL)
        }
        let published = expectation(description: "Native resize bindings published")
        controller.startConfigScript(at: fileURL)
        let config = try XCTUnwrap(controller.configScript)
        config.onReloadProcessed = { published.fulfill() }
        await fulfillment(of: [published], timeout: failureBound)
        config.onReloadProcessed = nil
        XCTAssertNil(config.diagnostic)
        XCTAssertEqual(omni_config_live_vm_count(), 0)

        let guiRows = try increments.map { chord, percent in
            try HotkeyBinding(
                id: chord,
                command: .sizing(.setContainerPrimarySpan(.adjustProportion(CGFloat(percent)))),
                binding: XCTUnwrap(KeySymbolMapper.fromHumanReadable(chord))
            )
        }
        let plan = HotkeyCenter.registrationPlan(for: controller.hotkeys.configuration.bindings)
        XCTAssertEqual(plan, HotkeyCenter.registrationPlan(for: guiRows))
        guard case var .proportion(expectedWidth) = fixture.column.width else {
            return XCTFail("Fixture must start with a proportional column")
        }
        for (chord, percent) in increments {
            let binding = try XCTUnwrap(KeySymbolMapper.fromHumanReadable(chord))
            let registration = try XCTUnwrap(plan.registrations.first { $0.binding == binding })
            XCTAssertEqual(controller.commandHandler.performCommand(registration.command), .executed)
            expectedWidth += CGFloat(percent) / 100
            assertSpan(fixture, primary: true, expected: expectedWidth)
        }
        XCTAssertEqual(omni_config_live_vm_count(), 0)
    }

    func testFunctionShortcutResizesForTheAppCapturedAtPress() async throws {
        let textEdit = "com.apple.TextEdit"
        let textEditPercent = 12
        let otherPercent = 4
        let source = """
        local wm = omniwm
        local textEdit = wm.cmd("set-container-primary-span", "+\(textEditPercent)%")
        local other = wm.cmd("set-container-primary-span", "+\(otherPercent)%")
        wm.keymap.set("Control+Option+I", function(ctx)
            wm.dispatch(if ctx.bundleId == "\(textEdit)" then textEdit else other)
        end)
        """
        for (bundleId, expectedPercent) in [(textEdit, textEditPercent), ("test.other-app", otherPercent)] {
            let fixture = try makeFixture()
            let controller = fixture.controller
            defer {
                controller.stopConfigScript()
                controller.layoutRefreshController.resetState()
            }
            let workspace = try XCTUnwrap(controller.activeWorkspace())
            let token = fixture.window.token
            _ = controller.workspaceManager.setManagedFocus(token, in: workspace.id)
            _ = controller.appInfoCache.info(for: token.pid) { _ in
                AppInfoCache.AppInfo(name: bundleId, bundleId: bundleId, icon: nil, activationPolicy: .regular)
            }
            controller.settings.hotkeyBindings = []
            let file = controller.settings.settingsFileURL.deletingLastPathComponent()
                .appendingPathComponent("init.luau")
            let script = ConfigScriptController(fileURL: file, settings: controller.settings) { _ in }
            controller.configScript = script
            let mask = controller.settings.hyperKeyModifiers.carbonMask
            let evaluation = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: mask)
            XCTAssertTrue(script.apply(ConfigScriptLoad(versions: [:], result: .success(evaluation)), hyperMask: mask))
            guard case let .proportion(initialWidth) = fixture.column.width else {
                return XCTFail("Fixture must start with a proportional column")
            }
            let command = try XCTUnwrap(script.effectiveBindings.first?.command)
            XCTAssertEqual(
                controller.commandHandler.handleHotkeyInvocation(HotkeyInvocation(command: command)),
                .executed
            )
            await script.callbackQueue?.waitUntilParked()
            XCTAssertNil(script.diagnostic)
            assertSpan(fixture, primary: true, expected: initialWidth + CGFloat(expectedPercent) / 100)
        }
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
            XCTAssertEqual(value, expected, accuracy: CGFloat.rounding(operations: 20, at: fixture.secondarySpan))
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
