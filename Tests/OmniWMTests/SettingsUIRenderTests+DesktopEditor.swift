// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    extension SettingsUIRenderTests {
        func testStylesEditorFullWindowSubstatesAtBothWindowClasses() async throws {
            try requireNativeRendering()
            for windowClass in windowClasses {
                for state in EditorState.allCases {
                    let fixture = try Fixture()
                    try await fixture.prepare()
                    do {
                        let configuration = fixture.controller.workspaceBarManager.shellConfiguration
                        _ = try await configuration.selectProfile("default")
                        let original = try Data(contentsOf: configuration.shellDirectory
                            .appendingPathComponent("shell.toml"))
                        let navigation = SettingsNavigationModel()
                        navigation.proceed(to: SettingsRoute(
                            section: .styles, itemID: state == .widget ? "clock" : nil
                        ))
                        let ready = EditorReady()
                        let root = SettingsView(
                            settings: fixture.settings, controller: fixture.controller,
                            windowCornerPreferences: fixture.corners, updateCoordinator: nil, navigation: navigation
                        )
                        .environment(\.shellDesktopEditorReady, ShellDesktopEditorObserver { editor in
                            do {
                                try await self.prepareEditor(editor, state: state)
                                ready.finish(.success(editor))
                            } catch { ready.finish(.failure(error)) }
                        })
                        try await render(
                            root, fixture: fixture, windowClass: windowClass, section: .styles,
                            name: "settings-editor-\(state.rawValue)-\(windowClass.suffix)",
                            requiredText: state.labels, scrollEditorForm: state == .widget || state == .display,
                            editorFormScrollOffset: state == .widget && windowClass.size.width == 760 ? 340 : nil
                        ) { scale in
                            let editor = try await ready.value()
                            try await self.prepareEditorPreviews(editor, dark: windowClass.dark, scale: scale)
                            XCTAssertEqual(editor.selectedStyle, state.profile)
                            if state == .widget { XCTAssertEqual(editor.selectedWidget, "clock") }
                            if state == .display { XCTAssertNotNil(editor.selectedMonitor) }
                            if state == .dirtyDraft {
                                XCTAssertEqual(editor.pendingTransition, .style("default"))
                                XCTAssertTrue(editor.draft(.weather)?.dirty == true)
                            }
                        }
                        XCTAssertEqual(configuration.config.profile, "default")
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

        private enum EditorState: String, CaseIterable {
            case active
            case previewing
            case widget
            case display
            case dirtyDraft = "dirty-draft"

            var profile: String {
                self == .active || self == .widget ? "default" : "lake"
            }

            var labels: [String] {
                switch self {
                case .active:
                    [String(localized: "Active"), String(localized: "Bar Widgets")]
                case .previewing:
                    [String(localized: "Use Style"), String(localized: "Bar Widgets")]
                case .widget:
                    [
                        String(localized: "Active"),
                        String(localized: "Bar Settings"),
                        String(localized: "Clock"),
                        String(localized: "Source"),
                        String(localized: "Options")
                    ]
                case .display:
                    [String(localized: "Use Style"), String(localized: "Display"), String(localized: "Style default")]
                case .dirtyDraft:
                    [String(localized: "Save"), String(localized: "Discard"), String(localized: "Cancel")]
                }
            }
        }

        @MainActor
        private final class EditorReady {
            private var result: Result<ShellDesktopEditor, Error>?
            private var continuation: CheckedContinuation<ShellDesktopEditor, Error>?

            func finish(_ value: Result<ShellDesktopEditor, Error>) {
                guard result == nil else { return }
                result = value
                continuation?.resume(with: value)
                continuation = nil
            }

            func value() async throws -> ShellDesktopEditor {
                if let result { return try result.get() }
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
        }

        private func prepareEditor(_ editor: ShellDesktopEditor, state: EditorState) async throws {
            if state.profile != "default" {
                let changed = await editor.selectStyle(state.profile)
                XCTAssertTrue(changed)
            }
            switch state {
            case .active,
                 .previewing,
                 .widget: break
            case .display:
                editor.selectMonitor(try XCTUnwrap(editor.monitors.first, "A native display is required").id)
            case .dirtyDraft:
                let selected = await editor.selectWidget("control-center")
                XCTAssertTrue(selected)
                await editor.beginWeatherDraft()
                guard case var .weather(weather)? = editor.draft(.weather)?.value else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                weather.city = "London"
                editor.updateDraft(.weather, .weather(weather))
                let changed = await editor.selectStyle("default")
                XCTAssertFalse(changed)
            }
        }

        private func prepareEditorPreviews(_ editor: ShellDesktopEditor, dark: Bool, scale: CGFloat) async throws {
            let snapshot = try XCTUnwrap(editor.snapshot)
            let style = try XCTUnwrap(editor.previewStyle)
            _ = try await ShellSettingsPreview.cachedImage(for: .init(
                config: snapshot.config, surface: .bar, style: style, scale: scale, dark: dark,
                fullWidth: editor.barOverride?.settings.fullWidth ?? editor.barSettings.fullWidth,
                sourceGeneration: editor.configuration.sourceGeneration, display: editor.previewDisplay
            ))
        }
    }
#endif
