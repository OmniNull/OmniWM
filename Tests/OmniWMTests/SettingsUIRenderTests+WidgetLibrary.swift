// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    extension SettingsUIRenderTests {
        func testSharedWidgetLibraryRendersEachTargetAtBothWindowClasses() async throws {
            try requireNativeRendering()
            let fixture = try Fixture()
            try await fixture.prepare()
            do {
                let configuration = fixture.controller.workspaceBarManager.shellConfiguration
                let editor = ShellDesktopEditor(
                    configuration: configuration, settings: fixture.settings, controller: fixture.controller
                )
                await editor.reload()
                for windowClass in windowClasses {
                    for target in [ShellDesktopEditor.LibraryTarget.bar, .island] {
                        try await render(
                            ShellWidgetLibrary(editor: editor, target: target, query: "Time in the places"),
                            fixture: fixture, windowClass: windowClass,
                            name: "settings-library-\(target == .bar ? "bar" : "island")-\(windowClass.suffix)",
                            requiredText: [
                                target == .bar ? String(localized: "Add Widget") :
                                    String(localized: "Add Island Widget"),
                                target == .bar ? String(localized: "World Clock") : String(localized: "Clock"),
                                String(localized: "Time in the places you choose.")
                            ]
                        )
                    }
                }
                try await renderDrawerLibrary(fixture: fixture, editor: editor)
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }

        private func renderDrawerLibrary(fixture: Fixture, editor: ShellDesktopEditor) async throws {
            let configuration = fixture.controller.workspaceBarManager.shellConfiguration
            let changed = await editor.selectStyle("celestial")
            XCTAssertTrue(changed)
            for (name, source) in [
                ("fixture-static", "function render(ctx) return ui.box{} end"),
                ("fixture-broken", "error('Broken drawer library fixture')")
            ] {
                let folder = configuration.shellDirectory.appendingPathComponent("celestial/widgets/" + name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(source.utf8).write(to: folder.appendingPathComponent("init.luau"))
            }
            try await configuration.refresh()
            await editor.reload()
            for windowClass in windowClasses {
                try await render(
                    ShellWidgetLibrary(editor: editor, target: .drawer("dashboard"), query: "fixture")
                        .frame(width: 480).frame(maxWidth: .infinity, maxHeight: .infinity),
                    fixture: fixture, windowClass: windowClass,
                    name: "settings-library-drawer-no-panel-\(windowClass.suffix)",
                    requiredText: [
                        String(localized: "Add Widget"),
                        "Fixture Static", "Broken drawer library fixture",
                        String(localized: "No panel")
                    ]
                ) { _ in
                    let request = try XCTUnwrap(editor.panelRequest(editor.drawerCandidates("dashboard")))
                    let values = try await ShellSettingsPreview.panels(for: request)
                    XCTAssertEqual(values["fixture-static"], .missing)
                    guard case let .failed(message)? = values["fixture-broken"] else {
                        return XCTFail("The broken candidate must report its load failure")
                    }
                    XCTAssertTrue(message.contains("Broken drawer library fixture"))
                }
                XCTAssertNil(fixture.controller.workspaceBarManager.shellHost)
            }
        }
    }
#endif
