// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteLeaseTests: XCTestCase {
    func testPalettePausesFocusFollowsMouseIndependentlyOfStatusPanel() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMCommandPaletteLeaseTests-\(UUID().uuidString)", isDirectory: true)
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
        let controller = WMController(
            settings: settings,
            clipboardHistoryDirectory: root.appendingPathComponent("clipboard", isDirectory: true),
            diagnosticsDirectory: root.appendingPathComponent("diagnostics", isDirectory: true),
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        var environment = CommandPaletteEnvironment()
        environment.frontmostApplication = { nil }
        environment.runningApplication = { _ in nil }
        let palette = CommandPaletteController(
            motionPolicy: MotionPolicy(animationsEnabled: false),
            environment: environment,
            ownedWindowRegistry: registry
        )
        controller.focusPolicyEngine.screenshotSelectionActiveProvider = { false }
        controller.focusPolicyEngine.beginLease(owner: .statusPanel, reason: "status_panel", duration: nil)
        defer {
            if palette.isVisible {
                palette.toggle(wmController: controller)
            }
            if let panel = NSApp.windows.first(where: { $0.delegate === palette }) as? NSPanel {
                registry.unregister(panel)
                panel.close()
                panel.contentView = nil
                panel.delegate = nil
            }
            controller.focusPolicyEngine.endLease(owner: .statusPanel)
            try? FileManager.default.removeItem(at: root)
        }

        palette.show(wmController: controller)
        XCTAssertTrue(palette.isVisible)
        XCTAssertFalse(controller.focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange)

        controller.focusPolicyEngine.endLease(owner: .statusPanel)
        XCTAssertEqual(controller.focusPolicyEngine.activeLease?.owner, .commandPalette)
        XCTAssertFalse(controller.focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange)

        palette.toggle(wmController: controller)
        XCTAssertTrue(controller.focusPolicyEngine.evaluate(.focusFollowsMouse).allowsFocusChange)
    }
}
