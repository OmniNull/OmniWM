// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class OpenAppHotkeyTests: XCTestCase {
    private let finderURL = URL(fileURLWithPath: ApplicationCatalogFilter.finderPath)
    private let chord = HotkeyTrigger.chord(KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey)))

    func testOpenAppActionsResolveFromBundleIdentifier() throws {
        let bundleID = try finderBundleID()
        let actionID = ActionCatalog.openAppPrefix + bundleID
        let command = HotkeyCommand.openApp(bundleID)
        let spec = try XCTUnwrap(ActionCatalog.spec(for: actionID))
        XCTAssertEqual(spec.command, command)
        XCTAssertEqual(spec.title, "Open \(FileManager.default.displayName(atPath: finderURL.path))")
        XCTAssertEqual(spec.defaultBinding, .unassigned)
        XCTAssertNil(spec.ipcCommandName)
        XCTAssertEqual(command.layoutCompatibility, .shared)
        XCTAssertEqual(ActionCatalog.layoutCompatibility(for: command), .shared)
        XCTAssertEqual(ActionCatalog.spec(for: command), spec)
        XCTAssertEqual(ActionCatalog.openAppBundleID(for: actionID), bundleID)
        for id in [ActionCatalog.openAppPrefix, ActionCatalog.openAppPrefix + "two words", bundleID] {
            XCTAssertNil(ActionCatalog.openAppBundleID(for: id), id)
            XCTAssertNil(ActionCatalog.spec(for: id), id)
        }
        let resolved = try HotkeyBindingRegistry.resolve([PersistedHotkeyBinding(id: actionID, trigger: chord)])
        XCTAssertEqual(resolved.first { $0.id == actionID }?.binding, chord)
    }

    func testOpenAppHotkeyOpensAnInstalledApplicationThatIsNotRunning() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleID = try finderBundleID()
        var opened: [URL] = []
        var requested: [LauncherApplicationResult] = []
        var recorded: [String] = []
        var environment = CommandPaletteEnvironment()
        environment.runningApplicationForResult = {
            requested.append($0)
            return nil
        }
        environment.mostRecentWindowForPID = { _, _ in
            XCTFail("No running app to query")
            return nil
        }
        environment.navigateToApplicationWindow = { _, _ in
            XCTFail("No running window to navigate to")
            return false
        }
        environment.openApplication = { url, completion in
            opened.append(url)
            completion(nil)
        }
        environment.recordLauncherLaunch = { _, target, _, _ in recorded.append(target) }
        environment.presentCommandFailure = { XCTFail($0) }
        let controller = makeController(root, environment: environment)

        XCTAssertEqual(
            controller.commandHandler.handleHotkeyInvocation(HotkeyInvocation(command: .openApp(bundleID))),
            .executed
        )
        XCTAssertEqual(opened, [finderURL])
        XCTAssertEqual(requested.map(\.bundleURL), [finderURL])
        XCTAssertEqual(requested.map(\.bundleIdentifier), [bundleID])
        XCTAssertEqual(requested.map(\.displayName), [FileManager.default.displayName(atPath: finderURL.path)])
        XCTAssertEqual(recorded, [finderURL.path])
    }

    func testOpenAppHotkeyNavigatesToMostRecentFloatingWindowWithoutOpeningApplication() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleID = try finderBundleID()
        let tiled = WindowToken(pid: 731_001, windowId: 1)
        let floating = WindowToken(pid: tiled.pid, windowId: 2)
        let otherApp = WindowToken(pid: 731_002, windowId: 3)
        var navigated: [WindowHandle] = []
        var environment = CommandPaletteEnvironment()
        environment.runningApplicationForResult = { item in
            XCTAssertEqual(item.bundleIdentifier, bundleID)
            return tiled.pid
        }
        environment.navigateToApplicationWindow = { _, handle in
            navigated.append(handle)
            return true
        }
        environment.openApplication = { _, _ in XCTFail("A running app with a managed window must not reopen") }
        environment.recordLauncherLaunch = { _, _, _, _ in }
        environment.presentCommandFailure = { XCTFail($0) }
        let controller = makeController(root, environment: environment)
        let manager = controller.workspaceManager
        let workspaceName = try XCTUnwrap(controller.settings.workspaces.configuredNames().first)
        let workspaceID = try XCTUnwrap(manager.workspaceId(for: workspaceName, createIfMissing: true))
        for (token, mode) in [(tiled, TrackedWindowMode.tiling), (floating, .floating), (otherApp, .tiling)] {
            manager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token),
                pid: token.pid, windowId: token.windowId, to: workspaceID, mode: mode
            )
            XCTAssertTrue(manager.setManagedFocus(token, in: workspaceID))
        }
        let floatingHandle = try XCTUnwrap(manager.handle(for: floating))
        XCTAssertEqual(manager.selectedManagedToken, otherApp)
        XCTAssertEqual(manager.focusSessionSnapshot.windowFocusHistory, [otherApp, floating, tiled])
        XCTAssertEqual(manager.focusSessionSnapshot.tiledFocusHistory, [otherApp, tiled])
        XCTAssertTrue(manager.mostRecentlyFocusedHandle(forPid: tiled.pid) === floatingHandle)

        XCTAssertEqual(
            controller.commandHandler.handleHotkeyInvocation(HotkeyInvocation(command: .openApp(bundleID))),
            .executed
        )
        XCTAssertEqual(navigated, [floatingHandle])
    }

    func testOpenAppHotkeyReturnsNotFoundForMissingApplication() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingBundleID = "org.omniwm.tests.absent.\(UUID().uuidString)"
        var environment = CommandPaletteEnvironment()
        environment.runningApplicationForResult = { _ in
            XCTFail("Missing app must not dispatch")
            return nil
        }
        environment.openApplication = { _, _ in XCTFail("Missing app must not open") }
        environment.presentCommandFailure = { XCTFail($0) }
        let controller = makeController(root, environment: environment)

        XCTAssertEqual(
            controller.commandHandler.handleHotkeyInvocation(HotkeyInvocation(command: .openApp(missingBundleID))),
            .notFound
        )
    }

    func testRemovingTheLastLauncherEntryForAnAppClearsItsShortcutAcrossTOMLReload() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var warnings: [Bool] = []
        var environment = CommandPaletteEnvironment()
        environment.confirmLauncherEntryRemoval = { _, clearsShortcut, _, reply in
            warnings.append(clearsShortcut)
            reply(true)
        }
        let controller = makeController(root, environment: environment)
        let settings = controller.settings
        let bundleID = try finderBundleID()
        let actionID = ActionCatalog.openAppPrefix + bundleID
        var changes: [String] = []
        settings.onDynamicHotkeysChanged = { changes.append(actionID) }
        var finder = LauncherEntry()
        finder.kind = .application
        finder.path = finderURL.path
        var otherFinder = LauncherEntry()
        otherFinder.kind = .application
        otherFinder.path = finderURL.path
        var command = LauncherEntry()
        command.command = "true"

        settings.launcher.entries = [finder, otherFinder, command]
        XCTAssertEqual(changes, [actionID])
        XCTAssertEqual(settings.hotkeyBindings.filter { $0.id.hasPrefix(ActionCatalog.openAppPrefix) }.map(\.id), [
            actionID
        ])
        settings.updateTrigger(for: actionID, newTrigger: chord)
        settings.updateModeKey(for: actionID, newModeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: 0))
        let assigned = try XCTUnwrap(settings.hotkeyBindings.first { $0.id == actionID })

        controller.commandPaletteController.removeLauncherEntry(finder.id, settings: settings)
        XCTAssertEqual(settings.launcher.entries.map(\.id), [otherFinder.id, command.id])
        XCTAssertEqual(settings.hotkeyBindings.first { $0.id == actionID }, assigned)
        XCTAssertEqual(warnings, [false])

        controller.commandPaletteController.removeLauncherEntry(otherFinder.id, settings: settings)
        XCTAssertEqual(settings.launcher.entries.map(\.id), [command.id])
        XCTAssertFalse(settings.hotkeyBindings.contains { $0.id == actionID })
        XCTAssertEqual(warnings, [false, true])
        XCTAssertEqual(changes, [actionID, actionID])

        settings.flushNow()
        let saved = try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL))
        XCTAssertFalse(saved.hotkeyBindings.contains { $0.id == actionID })
        let reloaded = makeSettings(root)
        XCTAssertNil(reloaded.configNotice)
        XCTAssertFalse(reloaded.hotkeyBindings.contains { $0.id == actionID })
    }

    func testRemovalWarnsOnlyWhenItClearsAShortcutOrModeKeyAndCancelKeepsBoth() throws {
        enum Assignment: CaseIterable {
            case none
            case shortcut
            case modeKey
        }
        let bundleID = try finderBundleID()
        let actionID = ActionCatalog.openAppPrefix + bundleID
        for assignment in Assignment.allCases {
            for confirms in [false, true] {
                let root = temporaryRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                var warnings: [Bool] = []
                var environment = CommandPaletteEnvironment()
                environment.confirmLauncherEntryRemoval = { _, clearsShortcut, _, reply in
                    warnings.append(clearsShortcut)
                    reply(confirms)
                }
                let controller = makeController(root, environment: environment)
                let settings = controller.settings
                var finder = LauncherEntry()
                finder.kind = .application
                finder.path = finderURL.path
                settings.launcher.entries = [finder]
                switch assignment {
                case .none: break
                case .shortcut: settings.updateTrigger(for: actionID, newTrigger: chord)
                case .modeKey:
                    settings.updateModeKey(
                        for: actionID, newModeKey: KeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: 0)
                    )
                }
                let before = settings.hotkeyBindings.first { $0.id == actionID }

                controller.commandPaletteController.removeLauncherEntry(finder.id, settings: settings)

                let context = "\(assignment) confirms=\(confirms)"
                XCTAssertEqual(warnings, [assignment != .none], context)
                if confirms {
                    XCTAssertTrue(settings.launcher.entries.isEmpty, context)
                    XCTAssertFalse(settings.hotkeyBindings.contains { $0.id == actionID }, context)
                } else {
                    XCTAssertEqual(settings.launcher.entries.map(\.id), [finder.id], context)
                    XCTAssertEqual(settings.hotkeyBindings.first { $0.id == actionID }, before, context)
                }
            }
        }
    }

    func testConfigureShortcutReconcilesAnApplicationInstalledAfterItsEntryWasSaved() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(root)
        let settings = controller.settings
        let navigation = SettingsNavigationModel()
        let page = LauncherSettingsPage(settings: settings, controller: controller, navigation: navigation)
        let bundleID = "org.omniwm.tests.later-installed"
        let actionID = ActionCatalog.openAppPrefix + bundleID
        let bundleURL = root.appendingPathComponent("Later Installed.app", isDirectory: true)
        var entry = LauncherEntry()
        entry.kind = .application
        entry.path = bundleURL.path
        settings.launcher.entries = [entry]
        settings.flushNow()
        XCTAssertNil(entry.bundleIdentifier)
        XCTAssertFalse(settings.hotkeyBindings.contains { $0.id == actionID })

        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL"],
            format: .xml, options: 0
        ).write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertEqual(entry.bundleIdentifier, bundleID)
        XCTAssertFalse(settings.hotkeyBindings.contains { $0.id == actionID })
        let destination = SettingsRoute(section: .hotkeys, itemID: actionID)
        var requestedRoutes: [SettingsRoute?] = []
        navigation.leaveGuard = { route in
            requestedRoutes.append(route)
            XCTAssertEqual(settings.hotkeyBindings.first { $0.id == actionID }?.command, .openApp(bundleID))
            return false
        }

        page.configureShortcut(bundleID: try XCTUnwrap(entry.bundleIdentifier))

        XCTAssertEqual(requestedRoutes, [destination])
        XCTAssertEqual(navigation.route, destination)
        XCTAssertEqual(settings.hotkeyBindings.first { $0.id == actionID }?.binding, .unassigned)
    }

    private func finderBundleID() throws -> String {
        try XCTUnwrap(Bundle(url: finderURL)?.bundleIdentifier)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeController(
        _ root: URL,
        environment: CommandPaletteEnvironment = CommandPaletteEnvironment()
    ) -> WMController {
        let controller = WMController(
            settings: makeSettings(root),
            clipboardHistoryDirectory: root.appendingPathComponent("clipboard"),
            diagnosticsDirectory: root.appendingPathComponent("diagnostics"),
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.commandPaletteController = CommandPaletteController(
            motionPolicy: MotionPolicy(animationsEnabled: false),
            environment: environment
        )
        return controller
    }

    private func makeSettings(_ root: URL) -> SettingsStore {
        SettingsStore(
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
    }
}
