// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
private final class FakeKittyProcesses {
    var installed = true
    var helperAvailable = true
    var contextAvailable = true
    var settings = KittyQuakeSettings()
    var commandStatus: Int32? = 0
    var controlOutput: ExternalTerminalProcess.Output? = FakeKittyProcesses.reply()
    var startSucceeds = true
    var existingInstance: Bool? = false
    var suspendNextControl = false
    private(set) var commands: [[String]] = []
    private(set) var controls: [[String]] = []
    private(set) var starts: [[String]] = []
    private(set) var queriedGroups: [String] = []
    private(set) var exitHandlers: [@MainActor @Sendable (Int32) -> Void] = []
    private var suspendedControl: CheckedContinuation<ExternalTerminalProcess.Output?, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var context: KittyQuakeControlContext? {
        guard contextAvailable else { return nil }
        return KittyQuakeControlContext(
            settings: settings,
            screen: .init(
                frame: CGRect(x: -800, y: 100, width: 800, height: 1000),
                visibleFrame: CGRect(x: -800, y: 100, width: 800, height: 960),
                scale: 2
            ),
            barBottom: 1032
        )
    }

    var environment: KittyQuickAccessTerminal.Environment {
        KittyQuickAccessTerminal.Environment(
            kittenURL: { [self] in installed ? URL(fileURLWithPath: "/virtual/kitty.app/Contents/MacOS/kitten") : nil },
            runCommand: { [self] _, arguments in
                commands.append(arguments)
                notifyWaiters()
                return commandStatus
            },
            runControl: { [self] _, arguments in await runControl(arguments) },
            helperURL: { [self] in helperAvailable ? URL(fileURLWithPath: "/virtual/kitty-quake-control.py") : nil },
            startInstance: { [self] _, arguments, onExit in
                starts.append(arguments)
                exitHandlers.append(onExit)
                notifyWaiters()
                return startSucceeds ? NSObject() : nil
            },
            isInstanceRunning: { [self] group in
                queriedGroups.append(group)
                return existingInstance
            }
        )
    }

    var eventCount: Int {
        commands.count + controls.count + starts.count
    }

    static func reply(opacityNeedsRestart: Bool = false) -> ExternalTerminalProcess.Output {
        .init(status: 0, data: Data("{\"opacityNeedsRestart\":\(opacityNeedsRestart)}".utf8))
    }

    func waitForEvents(_ count: Int) async {
        while eventCount < count {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func resumeControl(_ output: ExternalTerminalProcess.Output?) {
        suspendedControl?.resume(returning: output)
        suspendedControl = nil
    }

    private func runControl(_ arguments: [String]) async -> ExternalTerminalProcess.Output? {
        controls.append(arguments)
        notifyWaiters()
        guard suspendNextControl else { return controlOutput }
        suspendNextControl = false
        return await withCheckedContinuation { suspendedControl = $0 }
    }

    private func notifyWaiters() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class KittyQuickAccessTerminalTests: XCTestCase {
    func testToggleUsesTheOwnedSocketAndEncodesPreferencesSeparatelyFromContext() async throws {
        let (terminal, fake) = makeTerminal()
        markSocketReady(terminal)
        fake.settings = KittyQuakeSettings(
            autoHide: false,
            opacity: 0,
            placement: .init(position: .bottom, widthPercent: 75, heightPercent: 40)
        )

        await terminal.toggle().value

        let arguments = try XCTUnwrap(fake.controls.first)
        XCTAssertEqual(Array(arguments.dropLast()), [
            "@", "--to", "unix:\(terminal.socketPath)", "kitten", "--match=all", "/virtual/kitty-quake-control.py"
        ])
        let payload = try request(arguments)
        XCTAssertEqual(payload["operation"] as? String, "toggle")
        let settings = try XCTUnwrap(payload["settings"] as? NSDictionary)
        XCTAssertEqual(settings, [
            "autoHide": false, "opacity": 0,
            "placement": ["position": "bottom", "widthPercent": 75, "heightPercent": 40]
        ] as NSDictionary)
        XCTAssertNil(settings["screen"])
        XCTAssertEqual(payload["barBottom"] as? Double, 1032)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertTrue(fake.starts.isEmpty)
        XCTAssertNil(terminal.problem)
    }

    func testApplyOnlyContactsAnExistingSession() async throws {
        let (terminal, fake) = makeTerminal()
        await terminal.applySettings().value
        XCTAssertEqual(fake.eventCount, 0)
        markSocketReady(terminal)

        await terminal.applySettings().value

        let arguments = try XCTUnwrap(fake.controls.first)
        XCTAssertEqual(try request(arguments)["operation"] as? String, "apply")
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertTrue(fake.starts.isEmpty)
    }

    func testFailedApplyReportsInSettingsWithoutLaunchingOrPresentingAToggleAlert() async {
        let (terminal, fake) = makeTerminal()
        markSocketReady(terminal)
        fake.controlOutput = nil
        var reported: [KittyQuickAccessTerminal.Problem] = []
        terminal.onToggleFailure = { reported.append($0) }
        await terminal.applySettings().value
        XCTAssertEqual(terminal.problem, .commandRejected)
        XCTAssertTrue(reported.isEmpty)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertTrue(fake.starts.isEmpty)
    }

    func testUnsentApplyRevisionsCoalesceAndEncodeTheLatestSettings() async throws {
        let (terminal, fake) = makeTerminal()
        markSocketReady(terminal)
        fake.suspendNextControl = true
        let toggle = terminal.toggle()
        await fake.waitForEvents(1)
        fake.settings.opacity = 0.4
        let superseded = terminal.applySettings()
        fake.settings.opacity = 0.6
        let latest = terminal.applySettings()
        fake.resumeControl(FakeKittyProcesses.reply())
        await toggle.value
        await superseded.value
        await latest.value

        XCTAssertEqual(fake.controls.count, 2)
        let arguments = try XCTUnwrap(fake.controls.last)
        let payload = try request(arguments)
        XCTAssertEqual(payload["operation"] as? String, "apply")
        XCTAssertEqual((payload["settings"] as? [String: Any])?["opacity"] as? Double, 0.6)
        XCTAssertTrue(fake.starts.isEmpty)
    }

    func testSuccessfulToggleReportsOpacityRestartRequirementWithoutAModalFailure() async {
        let (terminal, fake) = makeTerminal()
        markSocketReady(terminal)
        fake.controlOutput = FakeKittyProcesses.reply(opacityNeedsRestart: true)
        var reported: [KittyQuickAccessTerminal.Problem] = []
        terminal.onToggleFailure = { reported.append($0) }

        await terminal.toggle().value

        XCTAssertEqual(terminal.problem, .opacityNeedsRestart)
        XCTAssertTrue(reported.isEmpty)
        XCTAssertEqual(fake.controls.count, 1)
        XCTAssertTrue(fake.commands.isEmpty)
    }

    func testMalformedAndFailedControlRepliesKeepAResponsiveSession() async {
        let outputs: [ExternalTerminalProcess.Output?] = [
            .init(status: 0, data: Data("not-json".utf8)),
            .init(status: 0, data: Data("{}".utf8)),
            .init(status: 1, data: FakeKittyProcesses.reply().data), nil
        ]
        for output in outputs {
            let (terminal, fake) = makeTerminal()
            markSocketReady(terminal)
            fake.controlOutput = output
            fake.existingInstance = true
            await terminal.toggle().value
            XCTAssertEqual(terminal.problem, .commandRejected)
            XCTAssertEqual(fake.commands, [terminal.probeArguments])
            XCTAssertTrue(fake.starts.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: terminal.socketPath))
        }
    }

    func testMissingHelperOrContextCannotLaunchOrControlAReadyInstance() async {
        for helperAvailable in [false, true] {
            let (terminal, fake) = makeTerminal()
            markSocketReady(terminal)
            fake.helperAvailable = helperAvailable
            fake.contextAvailable = !helperAvailable
            var reported: [KittyQuickAccessTerminal.Problem] = []
            terminal.onToggleFailure = { reported.append($0) }
            await terminal.toggle().value
            XCTAssertEqual(reported, [.controlsUnavailable])
            XCTAssertEqual(fake.eventCount, 0)
        }
    }

    func testToggleWithoutKittyReportsNotInstalledVisibly() async {
        let (terminal, fake) = makeTerminal()
        fake.installed = false
        var reported: [KittyQuickAccessTerminal.Problem] = []
        terminal.onToggleFailure = { reported.append($0) }
        await terminal.toggle().value
        XCTAssertEqual(terminal.problem, .notInstalled)
        XCTAssertEqual(reported, [.notInstalled])
        XCTAssertEqual(fake.eventCount, 0)
    }

    func testColdStartStaysHiddenAndEnablesLiveOpacityForTheNewSession() async {
        let (terminal, fake) = makeTerminal()
        await terminal.toggle().value
        XCTAssertEqual(fake.starts, [[
            "quick-access-terminal", "--instance-group=omniwm-quake",
            "-o", "start_as_hidden=yes", "-o", "kitty_override=allow_remote_control=socket-only",
            "-o", "kitty_override=dynamic_background_opacity=yes", "--", "--listen-on=unix:\(terminal.socketPath)"
        ]])
        XCTAssertEqual(terminal.problem, .starting)
        XCTAssertTrue(fake.controls.isEmpty)
    }

    func testHideAndToggleDuringColdStartNeverDeliverADeferredShow() async {
        let (terminal, fake) = makeTerminal()
        await terminal.activate().value
        await terminal.hide().value
        await terminal.toggle().value
        await terminal.activate().value
        XCTAssertEqual(fake.starts.count, 1)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertTrue(fake.controls.isEmpty)
        markSocketReady(terminal)
        await terminal.hide().value
        XCTAssertEqual(fake.commands, [terminal.visibilityArguments("hide")])
    }

    func testActivateReusesAReadyInstanceWithoutStartingAnother() async {
        let (terminal, fake) = makeTerminal()
        markSocketReady(terminal)
        await terminal.activate().value
        XCTAssertEqual(fake.commands, [terminal.probeArguments])
        XCTAssertTrue(fake.starts.isEmpty)
        XCTAssertNil(terminal.problem)
    }

    func testFailedControlAndProbeReplaceOnlyAStaleUnlockedInstance() async {
        for existingInstance in [false, true] {
            let (terminal, fake) = makeTerminal()
            markSocketReady(terminal)
            fake.controlOutput = .init(status: 1, data: Data())
            fake.commandStatus = 1
            fake.existingInstance = existingInstance
            await terminal.toggle().value
            XCTAssertEqual(fake.controls.count, 1)
            XCTAssertEqual(fake.commands, [terminal.probeArguments])
            XCTAssertEqual(fake.queriedGroups, ["panel-omniwm-quake"])
            XCTAssertEqual(terminal.problem, existingInstance ? .commandRejected : .starting)
            XCTAssertEqual(fake.starts.count, existingInstance ? 0 : 1)
            XCTAssertEqual(FileManager.default.fileExists(atPath: terminal.socketPath), existingInstance)
        }
    }

    func testRelaunchDuringNativeStartupDoesNotSendASingleInstanceToggle() async {
        let (terminal, fake) = makeTerminal()
        fake.existingInstance = true
        await terminal.activate().value
        await terminal.toggle().value
        await terminal.hide().value
        XCTAssertEqual(fake.eventCount, 0)
        XCTAssertEqual(terminal.problem, .commandRejected)
        XCTAssertEqual(fake.queriedGroups, ["panel-omniwm-quake", "panel-omniwm-quake"])
    }

    func testFailedSpawnIsReportedVisibly() async {
        let (terminal, fake) = makeTerminal()
        fake.startSucceeds = false
        var reported: [KittyQuickAccessTerminal.Problem] = []
        terminal.onToggleFailure = { reported.append($0) }
        await terminal.toggle().value
        XCTAssertEqual(terminal.problem, .launchFailed)
        XCTAssertEqual(reported, [.launchFailed])
    }

    func testInstanceExitReleasesOwnershipAndReportsNonzeroStatus() async {
        let (terminal, fake) = makeTerminal()
        await terminal.activate().value
        fake.exitHandlers[0](1)
        XCTAssertEqual(terminal.problem, .instanceExited(1))
        await terminal.activate().value
        XCTAssertEqual(fake.starts.count, 2)
    }

    func testDeselectionCancelsQueuedControlsAndHidesAfterAnInflightControl() async {
        let (terminal, fake) = makeTerminal()
        markSocketReady(terminal)
        fake.suspendNextControl = true
        let toggle = terminal.toggle()
        await fake.waitForEvents(1)
        let staleToggle = terminal.toggle()
        let staleApply = terminal.applySettings()
        let hide = terminal.hide()
        fake.resumeControl(FakeKittyProcesses.reply(opacityNeedsRestart: true))
        await toggle.value
        await staleToggle.value
        await staleApply.value
        await hide.value
        XCTAssertEqual(fake.controls.count, 1)
        XCTAssertEqual(fake.commands, [terminal.visibilityArguments("hide")])
        XCTAssertNil(terminal.problem)
    }

    func testLiveCommandAndControlCaptureTheirActualExitAndBoundedOutput() async throws {
        let live = KittyQuickAccessTerminal.Environment.live
        let success = await live.runCommand(URL(fileURLWithPath: "/usr/bin/true"), [])
        let failure = await live.runCommand(URL(fileURLWithPath: "/usr/bin/false"), [])
        let missing = await live.runCommand(URL(fileURLWithPath: "/nonexistent/kitten"), [])
        XCTAssertEqual(success, 0)
        XCTAssertEqual(failure, 1)
        XCTAssertNil(missing)
        let json = "{\"opacityNeedsRestart\":false}"
        let output = await live.runControl(URL(fileURLWithPath: "/usr/bin/printf"), ["%s", json])
        let failedOutput = await live.runControl(URL(fileURLWithPath: "/usr/bin/false"), [])
        let absentOutput = await live.runControl(URL(fileURLWithPath: "/nonexistent/kitten"), [])
        let oversized = await live.runControl(
            URL(fileURLWithPath: "/usr/bin/printf"),
            ["%s", String(repeating: "x", count: 5000)]
        )
        XCTAssertEqual(output?.status, 0)
        XCTAssertEqual(output?.data, Data(json.utf8))
        let captured = try XCTUnwrap(output)
        XCTAssertFalse(try JSONDecoder().decode(KittyQuakeControlReply.self, from: captured.data).opacityNeedsRestart)
        XCTAssertEqual(failedOutput?.status, 1)
        XCTAssertNil(absentOutput)
        XCTAssertNil(oversized)
    }

    func testLiveControlHelperIsPresentInTheProductResources() throws {
        let helper = try XCTUnwrap(KittyQuickAccessTerminal.Environment.live.helperURL())
        XCTAssertEqual(helper.lastPathComponent, "kitty-quake-control.py")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: helper.path))
    }

    func testLiveInstanceReportsItsExit() async {
        let live = KittyQuickAccessTerminal.Environment.live
        var handle: AnyObject?
        let status: Int32 = await withCheckedContinuation { continuation in
            handle = live
                .startInstance(URL(fileURLWithPath: "/usr/bin/false"), []) { continuation.resume(returning: $0) }
            if handle == nil { continuation.resume(returning: -1) }
        }
        XCTAssertNotNil(handle)
        XCTAssertEqual(status, 1)
    }

    func testControllerRoutesKittySelectionWithoutStartingGhostty() async throws {
        let (controller, root) = makeController()
        let (terminal, fake) = makeTerminal(directory: root)
        controller.kittyQuickAccessTerminal = terminal
        controller.settings.quakeTerminal.provider = .kitty
        controller.settings.quakeTerminal.enabled = true
        controller.setQuakeTerminalEnabled(true)
        await fake.waitForEvents(1)
        await terminal.applySettings().value
        XCTAssertEqual(controller.appliedQuakeTerminalSelection, .kitty)
        XCTAssertNil(controller.quakeTerminalController.window)
        XCTAssertEqual(fake.starts, [terminal.instanceArguments])
        markSocketReady(terminal)
        controller.setQuakeTerminalEnabled(true)
        controller.toggleQuakeTerminal()
        await fake.waitForEvents(2)
        XCTAssertEqual(fake.controls.count, 1)
        let arguments = try XCTUnwrap(fake.controls.first)
        XCTAssertEqual(try request(arguments)["operation"] as? String, "toggle")
        XCTAssertNil(controller.quakeTerminalController.window)
        controller.settings.quakeTerminal.enabled = false
        controller.setQuakeTerminalEnabled(false)
        await fake.waitForEvents(3)
        XCTAssertNil(controller.appliedQuakeTerminalSelection)
        XCTAssertEqual(fake.commands.last, terminal.visibilityArguments("hide"))
        controller.toggleQuakeTerminal()
        await terminal.activate().value
        XCTAssertEqual(fake.controls.count, 1)
    }

    func testProviderDefaultsToGhosttyAndRoundTripsThroughLuau() throws {
        XCTAssertEqual(SettingsExport.QuakeTerminal.defaults().provider, .ghostty)
        var export = SettingsExport.defaults()
        export.quakeTerminal.provider = .kitty
        export.quakeTerminal.kitty = KittyQuakeSettings(autoHide: true, opacity: 0.5)
        let data = try SettingsLuauDocument.initialSource(export)
        let tree = try SettingsLuauFixture.fields(in: data)
        guard case let .record(quake) = try XCTUnwrap(tree["quakeTerminal"])
        else { return XCTFail("Expected quakeTerminal table") }
        XCTAssertNotNil(quake["provider"])
        XCTAssertEqual(try SettingsLuauFixture.decode(data), export)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("provider = \"kitty\""))
    }

    func testMissingProviderImportsAsGhostty() throws {
        let settings = makeSettings(root: makeDirectory())
        settings.quakeTerminal.provider = .kitty
        var export = SettingsExport.defaults()
        export.quakeTerminal.provider = nil
        settings.applyExport(try SettingsLuauFixture.decode(SettingsLuauDocument.initialSource(export)))
        XCTAssertEqual(settings.quakeTerminal.provider, .ghostty)
    }

    private func request(_ arguments: [String]) throws -> [String: Any] {
        let data = Data(try XCTUnwrap(arguments.last).utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeTerminal(directory: URL? = nil) -> (KittyQuickAccessTerminal, FakeKittyProcesses) {
        let root = directory ?? makeDirectory()
        let fake = FakeKittyProcesses()
        let terminal = KittyQuickAccessTerminal(
            environment: fake.environment,
            socketPath: root.appendingPathComponent("k.sock", isDirectory: false).path,
            context: { fake.context }
        )
        return (terminal, fake)
    }

    private func markSocketReady(_ terminal: KittyQuickAccessTerminal) {
        FileManager.default.createFile(atPath: terminal.socketPath, contents: Data())
    }

    private func makeDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "okq-\(UUID().uuidString.prefix(8))",
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
