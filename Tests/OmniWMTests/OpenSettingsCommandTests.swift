// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class OpenSettingsCommandTests: XCTestCase {
    func testOneCatalogCommandReachesShortcutsThePaletteTheCLIAndLuau() async throws {
        let request = try XCTUnwrap(IPCCommandRequest(commandWords: ["open-settings"]))
        XCTAssertEqual(request, .openSettings)
        XCTAssertNil(IPCCommandRequest(commandWords: ["open-settings", "hotkeys"]))
        XCTAssertEqual(HotkeyCommand(direct: request), .openSettings)
        XCTAssertTrue(IPCAutomationManifest.commandDescriptors.contains {
            $0.name == .openSettings && $0.arguments.isEmpty
        })
        let spec = try XCTUnwrap(ActionCatalog.allSpecs().first { $0.command == .openSettings })
        XCTAssertEqual(spec.ipcCommandName, .openSettings)
        XCTAssertEqual(spec.layoutCompatibility, .shared)
        let hyperComma = KeyBinding(keyCode: UInt32(kVK_ANSI_Comma), modifiers: HyperKeyModifiers.default.carbonMask)
        XCTAssertEqual(spec.defaultBinding, hyperComma)
        for other in ActionCatalog.defaultHotkeyBindings() where other.id != spec.id {
            XCTAssertFalse(other.binding.conflicts(with: .chord(hyperComma)), other.id)
        }
        let evaluation = try await ConfigScriptLoader().evaluate(
            Data("omniwm.keymap.set('Hyper+Comma', omniwm.cmd.openSettings())".utf8),
            hyperMask: HyperKeyModifiers.default.carbonMask
        )
        XCTAssertEqual(evaluation.bindings.map(\.command), [.openSettings])
        XCTAssertEqual(evaluation.bindings.map(\.chord), [hyperComma])
    }

    func testTheCommandOpensSettingsAndBringsItBackFromAnotherWorkspace() async throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let settings = fixture.makeSettingsController()
        controller.settingsWindowController = settings

        XCTAssertEqual(controller.commandHandler.performCommand(.openSettings), .executed)
        let window = try XCTUnwrap(settings.window)
        let token = WindowToken(ownWindow: window)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.workspaceId, fixture.first)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        if let request = controller.intentLedger.activeManagedRequest {
            _ = controller.cancelManagedFocusRequest(request)
        }
        await fixture.activate(fixture.second)
        XCTAssertEqual(controller.activeWorkspace()?.id, fixture.second)

        XCTAssertEqual(controller.commandHandler.performCommand(.openSettings), .executed)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertTrue(settings.window === window)
        XCTAssertEqual(fixture.manager.windows.count, 1)
        XCTAssertEqual(controller.activeWorkspace()?.id, fixture.first)
        XCTAssertEqual(
            controller.workspaceManager.pendingFocusedToken ?? controller.workspaceManager.nativeManagedFocusToken,
            token
        )
    }

    func testTheCommandKeepsTheSharedGuards() throws {
        XCTAssertTrue(CommandHandler.shouldIgnoreCommand(.openSettings, isOverviewOpen: true))
        XCTAssertFalse(CommandHandler.shouldIgnoreCommand(.openSettings, isOverviewOpen: false))
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        let settings = fixture.makeSettingsController()
        fixture.controller.settingsWindowController = settings
        fixture.controller.isEnabled = false

        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.openSettings), .ignoredDisabled)
        XCTAssertNil(settings.window)
    }

    func testTheSettingsMenuCommandShowsSettingsOnlyOnceTheAppIsReady() throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        let settings = fixture.makeSettingsController()
        fixture.controller.settingsWindowController = settings
        let bootstrap = AppBootstrapState()

        bootstrap.showSettings()
        XCTAssertFalse(bootstrap.isReady)
        XCTAssertNil(settings.window)

        bootstrap.settings = fixture.controller.settings
        bootstrap.controller = fixture.controller
        bootstrap.showSettings()
        XCTAssertTrue(bootstrap.isReady)
        XCTAssertEqual(settings.window?.isVisible, true)
    }
}
