// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    extension SettingsUIRenderTests {
        func testIslandGalleryShowsFailedAddWithoutLosingItsContext() async throws {
            try requireNativeRendering()
            let fixture = try Fixture()
            try await fixture.prepare()
            do {
                let configuration = fixture.controller.workspaceBarManager.shellConfiguration
                let editor = ShellDesktopEditor(
                    configuration: configuration,
                    settings: fixture.settings,
                    controller: fixture.controller
                )
                await editor.reload()
                let original = try Data(contentsOf: configuration.shellDirectory.appendingPathComponent("shell.toml"))
                let message = "No component named missing is installed"
                for windowClass in windowClasses {
                    editor.problem = nil
                    try await render(
                        IslandGalleryReview(editor: editor), fixture: fixture, windowClass: windowClass,
                        name: "settings-island-gallery-error-\(windowClass.suffix)",
                        requiredText: [
                            String(localized: "Add Island Widget"),
                            String(localized: "Search widgets"),
                            message
                        ]
                    ) { _ in
                        let added = await editor.addComponent("missing")
                        XCTAssertFalse(added)
                        XCTAssertEqual(editor.problem, message)
                    }
                    XCTAssertEqual(
                        try Data(contentsOf: configuration.shellDirectory.appendingPathComponent("shell.toml")),
                        original
                    )
                    XCTAssertNil(fixture.controller.workspaceBarManager.shellHost)
                }
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }

        func testUnavailableIslandRetainsPlacementControls() async throws {
            try requireNativeRendering()
            let fixture = try Fixture()
            try await fixture.prepare()
            do {
                let configuration = fixture.controller.workspaceBarManager.shellConfiguration
                let source = try XCTUnwrap(configuration.config.widget("lake"))
                try Data("[options.bad]\ntype = 'invalid'".utf8)
                    .write(to: source.deletingLastPathComponent().appendingPathComponent("settings.toml"))
                try await configuration.refresh()
                let editor = ShellDesktopEditor(
                    configuration: configuration,
                    settings: fixture.settings,
                    controller: fixture.controller
                )
                await editor.reload()
                XCTAssertNotNil(editor.snapshot?.islandProblem)
                XCTAssertNil(editor.snapshot?.island)
                let navigation = SettingsNavigationModel()
                for windowClass in windowClasses {
                    try await render(
                        ShellIslandEditorForm(editor: editor).environment(navigation), fixture: fixture,
                        windowClass: windowClass,
                        name: "settings-island-unavailable-placement-\(windowClass.suffix)",
                        requiredText: [
                            String(localized: "Island settings unavailable"),
                            String(localized: "Placement"),
                            String(localized: "Show On"),
                            String(localized: "Native Fullscreen")
                        ]
                    )
                    XCTAssertNil(fixture.controller.workspaceBarManager.shellHost)
                }
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }

        private struct IslandGalleryReview: View {
            let editor: ShellDesktopEditor

            var body: some View {
                ShellWidgetLibrary(editor: editor, target: .island)
            }
        }
    }
#endif
