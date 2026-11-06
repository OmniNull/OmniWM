// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    extension SettingsUIRenderTests {
        func testDrawerEditorFullWindowSubstatesAtBothWindowClasses() async throws {
            try requireNativeRendering()
            for windowClass in windowClasses {
                for state in DrawerEditorState.allCases {
                    let fixture = try Fixture()
                    try await fixture.prepare()
                    do {
                        let configuration = fixture.controller.workspaceBarManager.shellConfiguration
                        try await prepareDrawerFixture(fixture, state: state)
                        let original = try Data(contentsOf: configuration.shellDirectory
                            .appendingPathComponent("shell.toml"))
                        try await renderDrawerState(fixture, state: state, windowClass: windowClass)
                        XCTAssertEqual(
                            try Data(contentsOf: configuration.shellDirectory.appendingPathComponent("shell.toml")),
                            original
                        )
                        XCTAssertNil(fixture.controller.workspaceBarManager.shellHost)
                    } catch {
                        await fixture.close()
                        throw error
                    }
                    await fixture.close()
                }
            }
        }

        func testSeededAddDrawerSheetDisplaysValidationAndWriteErrors() async throws {
            try requireNativeRendering()
            let fixture = try Fixture()
            try await fixture.prepare()
            do {
                let configuration = fixture.controller.workspaceBarManager.shellConfiguration
                _ = try await configuration.selectProfile("celestial")
                let editor = ShellDesktopEditor(
                    configuration: configuration,
                    settings: fixture.settings,
                    controller: fixture.controller
                )
                await editor.reload()
                _ = try await ShellSettingsPreview
                    .panels(for: XCTUnwrap(editor.panelRequest(editor.drawerCandidates(nil))))
                let file = configuration.shellDirectory.appendingPathComponent("shell.toml")
                let original = try Data(contentsOf: file)
                for windowClass in windowClasses {
                    try await renderAddDrawerCases(
                        editor,
                        fixture: fixture,
                        windowClass: windowClass,
                        original: original
                    )
                }
                XCTAssertNil(fixture.controller.workspaceBarManager.shellHost)
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }

        func testDrawerDeleteConfirmationRendersWithoutDeletingAnything() async throws {
            try requireNativeRendering()
            let fixture = try Fixture()
            try await fixture.prepare()
            do {
                try await prepareDrawerFixture(fixture, state: .user)
                let configuration = fixture.controller.workspaceBarManager.shellConfiguration
                let editor = ShellDesktopEditor(
                    configuration: configuration,
                    settings: fixture.settings,
                    controller: fixture.controller
                )
                await editor.reload()
                let drawer = try XCTUnwrap(editor.drawer("tools"))
                let original = try Data(contentsOf: configuration.shellDirectory.appendingPathComponent("shell.toml"))
                for windowClass in windowClasses {
                    try await render(
                        Form { ShellDrawerInspector(editor: editor, drawer: drawer, confirmingDelete: true) }
                            .formStyle(.grouped).environment(SettingsNavigationModel()),
                        fixture: fixture, windowClass: windowClass,
                        name: "settings-drawers-delete-confirmation-\(windowClass.suffix)",
                        requiredText: [
                            String(localized: "Delete Drawer"),
                            String(localized: "Cancel"),
                            "Its shortcut binding will be kept."
                        ]
                    )
                    XCTAssertEqual(
                        try Data(contentsOf: configuration.shellDirectory.appendingPathComponent("shell.toml")),
                        original
                    )
                }
                XCTAssertNil(fixture.controller.workspaceBarManager.shellHost)
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }

        private func renderDrawerState(
            _ fixture: Fixture,
            state: DrawerEditorState,
            windowClass: WindowClass
        ) async throws {
            let configuration = fixture.controller.workspaceBarManager.shellConfiguration
            let navigation = SettingsNavigationModel()
            navigation.proceed(to: SettingsRoute(
                section: .styles, tab: "drawers", itemID: state.userDrawer ? "tools" : nil
            ))
            let ready = DrawerEditorReady()
            let root = SettingsView(
                settings: fixture.settings, controller: fixture.controller,
                windowCornerPreferences: fixture.corners, updateCoordinator: nil, navigation: navigation
            )
            .environment(\.shellDesktopEditorReady, ShellDesktopEditorObserver { editor in
                ready.finish(editor)
            })
            try await render(
                root, fixture: fixture, windowClass: windowClass, section: .styles,
                name: "settings-drawers-\(state.rawValue)-\(windowClass.suffix)",
                requiredText: state.labels,
                requiredObservations: [
                    String(localized: "Bar"),
                    String(localized: "Island"),
                    String(localized: "Drawers")
                ],
                editorFormScrollOffset: state == .inspector ? windowClass.dark ? 420 : 300 : nil
            ) { scale in
                let editor = await ready.value()
                XCTAssertEqual(editor.surface, .drawers)
                XCTAssertEqual(editor.selectedStyle, state == .empty ? "default" : "celestial")
                XCTAssertEqual(
                    editor.selectedDrawer,
                    state == .empty ? nil : state.userDrawer ? "tools" : "dashboard"
                )
                if let drawer = editor.selectedDrawer {
                    let config = try XCTUnwrap(editor.drawerPreviewConfig)
                    _ = try await ShellSettingsPreview.cachedImage(for: .init(
                        config: config, surface: .drawer(drawer), style: ShellBarStyle(),
                        scale: scale, dark: windowClass.dark, fullWidth: false,
                        sourceGeneration: configuration.sourceGeneration
                    ))
                    _ = try await ShellSettingsPreview
                        .panels(for: XCTUnwrap(editor.panelRequest(editor.drawerMembers(drawer).sorted())))
                }
            }
        }

        private func renderAddDrawerCases(
            _ editor: ShellDesktopEditor, fixture: Fixture, windowClass: WindowClass, original: Data
        ) async throws {
            let file = editor.configuration.shellDirectory.appendingPathComponent("shell.toml")
            editor.problem = nil
            try await render(
                ShellAddDrawerSheet(
                    editor: editor,
                    initialName: "bad.name",
                    initialEdge: .left,
                    initialWidget: "weather"
                )
                .frame(width: 480)
                .frame(maxWidth: .infinity, maxHeight: .infinity),
                fixture: fixture, windowClass: windowClass,
                name: "settings-drawers-add-name-error-\(windowClass.suffix)",
                requiredText: [
                    String(localized: "Add Drawer"),
                    "bad.name",
                    String(localized: "Drawer names can't contain periods.")
                ]
            )
            XCTAssertEqual(try Data(contentsOf: file), original)
            try Data("[invalid".utf8).write(to: file)
            let invalid = try Data(contentsOf: file)
            let previous = editor.selectedDrawer
            let added = await editor.addDrawer(name: "tools", edge: .left, widget: "weather")
            XCTAssertFalse(added)
            XCTAssertEqual(editor.selectedDrawer, previous)
            let problem = try XCTUnwrap(editor.problem)
            try await render(
                ShellAddDrawerSheet(editor: editor, initialName: "tools", initialEdge: .left, initialWidget: "weather")
                    .frame(width: 480)
                    .frame(maxWidth: .infinity, maxHeight: .infinity),
                fixture: fixture, windowClass: windowClass,
                name: "settings-drawers-add-write-error-\(windowClass.suffix)",
                requiredText: [
                    String(localized: "Add Drawer"),
                    "tools",
                    String(localized: "Left"),
                    String(localized: "Weather"),
                    problem
                ]
            )
            XCTAssertEqual(try Data(contentsOf: file), invalid)
            try original.write(to: file)
        }

        private enum DrawerEditorState: String, CaseIterable {
            case preset
            case user
            case inspector
            case empty

            var userDrawer: Bool {
                self == .user || self == .inspector
            }

            var labels: [String] {
                switch self {
                case .preset: [String(localized: "Dashboard"), String(localized: "Add Drawer…")]
                case .user: [String(localized: "Dashboard"), "Tools"]
                case .inspector: [String(localized: "Hover Area Depth"), String(localized: "Limit Hover Area Length")]
                case .empty: [String(localized: "This style has no drawers."), String(localized: "Add Drawer…")]
                }
            }
        }

        private func prepareDrawerFixture(_ fixture: Fixture, state: DrawerEditorState) async throws {
            let configuration = fixture.controller.workspaceBarManager.shellConfiguration
            _ = try await configuration.selectProfile(state == .empty ? "default" : "celestial")
            if state.userDrawer {
                try await configuration.addDrawer("tools", edge: .left, widget: "weather", profile: "celestial")
                try await configuration.editDrawerWidgets("tools", profile: "celestial") { $0 += ["clock", "volume"] }
                try await configuration.set(true, key: "hover", table: "drawer.tools", profile: "celestial")
            }
        }

        @MainActor
        private final class DrawerEditorReady {
            private var editor: ShellDesktopEditor?
            private var continuation: CheckedContinuation<ShellDesktopEditor, Never>?

            func finish(_ editor: ShellDesktopEditor) {
                guard self.editor == nil else { return }
                self.editor = editor
                continuation?.resume(returning: editor)
                continuation = nil
            }

            func value() async -> ShellDesktopEditor {
                if let editor { return editor }
                return await withCheckedContinuation { continuation = $0 }
            }
        }
    }
#endif
