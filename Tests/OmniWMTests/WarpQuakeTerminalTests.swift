// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

@MainActor
final class WarpQuakeTerminalTests: XCTestCase {
    func testWarpProviderDisplayName() {
        XCTAssertEqual(QuakeTerminalProvider.warp.displayName, "Warp")
    }

    func testNewWindowURLPrefersStableAndFallsBackToPreview() {
        XCTAssertEqual(
            WarpQuakeTerminal.resolveNewWindowURL(isInstalled: { _ in true }, home: "/Users/a b")?.absoluteString,
            "warp://action/new_window?path=/Users/a%20b"
        )
        XCTAssertEqual(
            WarpQuakeTerminal.resolveNewWindowURL(isInstalled: { $0 == "dev.warp.Warp-Preview" }, home: "/h")?
                .absoluteString,
            "warppreview://action/new_window?path=/h"
        )
        XCTAssertNil(WarpQuakeTerminal.resolveNewWindowURL(isInstalled: { _ in false }, home: "/h"))
    }

    func testWarpProviderRoundTripsThroughTOML() throws {
        var export = SettingsExport.defaults()
        export.quakeTerminal.provider = .warp
        let data = try SettingsTOMLCodec.encode(export)
        let tree = try TOMLDecoder().decode([String: TOMLNode].self, from: data)
        guard case let .table(quake) = try XCTUnwrap(tree["quakeTerminal"])
        else { return XCTFail("Expected quakeTerminal table") }
        XCTAssertNotNil(quake["provider"])
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), export)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("provider = \"warp\""))
    }

    func testSwitchingAwayFromWarpHidesTerminal() {
        let (controller, _) = makeController()
        let terminal = WarpQuakeTerminal(controller: controller)
        controller.warpQuakeTerminal = terminal
        controller.settings.quakeTerminal.provider = .warp
        controller.settings.quakeTerminal.enabled = true
        controller.setQuakeTerminalEnabled(true)
        XCTAssertEqual(controller.appliedQuakeTerminalSelection, .warp)
        XCTAssertEqual(terminal.hideCallCount, 0)

        controller.setQuakeTerminalProvider(.ghostty)
        XCTAssertEqual(controller.appliedQuakeTerminalSelection, .ghostty)
        XCTAssertEqual(terminal.hideCallCount, 1)

        controller.setQuakeTerminalProvider(.warp)
        XCTAssertEqual(controller.appliedQuakeTerminalSelection, .warp)

        controller.setQuakeTerminalEnabled(false)
        XCTAssertNil(controller.appliedQuakeTerminalSelection)
        XCTAssertEqual(terminal.hideCallCount, 2)
    }

    func testToggleWhenNotInstalledReportsProblem() async {
        let (controller, _) = makeController()
        let terminal = WarpQuakeTerminal(controller: controller)
        terminal.newWindowURLProvider = { nil }
        var reportedProblem: WarpQuakeTerminal.Problem?
        terminal.onToggleFailure = { reportedProblem = $0 }
        await terminal.toggle().value
        XCTAssertEqual(terminal.problem, .notInstalled)
        XCTAssertEqual(reportedProblem, .notInstalled)
    }

    func testInactiveWorkspaceHideKeepsQuakeReason() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 73_101
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 73_102),
            pid: pid,
            windowId: 73_102,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.setHiddenState(
            HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .quake),
            for: token
        )
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let monitor = controller.workspaceManager.monitors.first ?? Monitor.fallback()
        controller.layoutRefreshController.hideWindow(
            entry,
            monitor: monitor,
            side: .right,
            reason: .workspaceInactive,
            observedFrame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        XCTAssertEqual(controller.workspaceManager.hiddenState(for: token)?.reason, .quake)
    }

    func testRevealAfterWorkspaceSwitchClearsInactiveFrameGate() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 73_201
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 73_202),
            pid: pid,
            windowId: 73_202,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.setHiddenState(
            HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .quake),
            for: token
        )
        controller.axManager.markWindowInactive(token.windowId)
        let terminal = WarpQuakeTerminal(controller: controller)
        terminal.setTokenForTests(token)
        await terminal.toggle().value
        XCTAssertFalse(controller.axManager.inactiveWorkspaceWindowIds.contains(token.windowId))
    }

    func testScratchpadRevealPathLeavesQuakeWindowParked() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid: pid_t = 73_301
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 73_302),
            pid: pid,
            windowId: 73_302,
            to: workspaceId,
            mode: .floating
        )
        let quakeState = HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .quake)
        controller.workspaceManager.setHiddenState(quakeState, for: token)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let monitor = controller.workspaceManager.monitors.first ?? Monitor.fallback()
        XCTAssertFalse(controller.layoutRefreshController.unhideWindow(entry, monitor: monitor))
        XCTAssertEqual(controller.workspaceManager.hiddenState(for: token), quakeState)
    }

    func testRevealPlacesWindowFromCurrentQuakeSettings() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 73_400),
            displayId: 73_400,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Warp test"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))
        let pid: pid_t = 73_401
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 73_402),
            pid: pid,
            windowId: 73_402,
            to: workspaceId,
            mode: .floating
        )
        controller.workspaceManager.updateFloatingGeometry(
            frame: CGRect(x: 400, y: 225, width: 800, height: 450),
            for: token,
            referenceMonitor: monitor
        )
        controller.workspaceManager.setHiddenState(
            HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .quake),
            for: token
        )
        controller.settings.quakeTerminal.monitorMode = .mainMonitor
        controller.settings.quakeTerminal.position = .top
        controller.settings.quakeTerminal.widthPercent = 100
        controller.settings.quakeTerminal.heightPercent = 40
        let terminal = WarpQuakeTerminal(controller: controller)
        terminal.setTokenForTests(token)
        await terminal.toggle().value
        XCTAssertEqual(
            controller.workspaceManager.floatingState(for: token)?.lastFrame,
            CGRect(x: 0, y: 540, width: 1600, height: 360)
        )
    }

    func testLaunchAdoptsWindowAdmittedWhileOpenRuns() async throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let pid = ProcessInfo.processInfo.processIdentifier
        let terminal = WarpQuakeTerminal(controller: controller)
        terminal.windowWaitTimeout = .milliseconds(200)
        terminal.newWindowURLProvider = { URL(string: "warp://action/new_window?path=/") }
        var admitted: WindowToken?
        terminal.urlOpener = { _, _ in
            admitted = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: 73_502),
                pid: pid,
                windowId: 73_502,
                to: workspaceId,
                mode: .tiling
            )
            return NSRunningApplication.current
        }
        await terminal.toggle().value
        XCTAssertNotNil(admitted)
        XCTAssertEqual(terminal.token, admitted)
        XCTAssertNotEqual(terminal.problem, .windowNotFound)
    }

    func testNoteWindowRemovedClearsToken() {
        let (controller, _) = makeController()
        let terminal = WarpQuakeTerminal(controller: controller)
        let token = WindowToken(pid: 1234, windowId: 5678)
        terminal.setTokenForTests(token)
        XCTAssertEqual(terminal.token, token)
        terminal.noteWindowRemoved(WindowToken(pid: 9999, windowId: 8888))
        XCTAssertEqual(terminal.token, token)
        terminal.noteWindowRemoved(token)
        XCTAssertNil(terminal.token)
    }

    private func makeDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "owq-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeSettings(root: URL) -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
    }

    private func makeController() -> (WMController, URL) {
        let root = makeDirectory()
        let controller = WMController(
            settings: makeSettings(root: root),
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        addTeardownBlock { @MainActor in
            controller.hasStartedServices = false
            controller.workspaceBarManager.cleanup()
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
            await controller.workspaceBarManager.flushShellForQuit()
        }
        return (controller, root)
    }
}
