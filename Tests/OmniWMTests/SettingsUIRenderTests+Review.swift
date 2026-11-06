// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Observation
@testable import OmniWM
import SwiftUI
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    extension SettingsUIRenderTests {
        func testClockDraftAppearingBeforeItsSnapshotRendersRowsAfterReload() async throws {
            try await withReviewEditor { fixture, editor in
                let key = ShellEditorDraft.Key(widget: "world-clock", option: "zones")
                try await self.render(
                    Form { ShellDesktopClocksDraft(editor: editor) }.formStyle(.grouped),
                    fixture: fixture, windowClass: self.reviewCompact,
                    name: "review-clocks-after-cold-snapshot-539x480-dark",
                    requiredText: [
                        String(localized: "Label"),
                        String(localized: "Time Zone"),
                        String(localized: "Add Clock")
                    ]
                ) { _ in
                    XCTAssertNil(editor.snapshot)
                    XCTAssertNil(editor.draft(key))
                    await editor.reload()
                    while editor.draft(key) == nil {
                        await withCheckedContinuation { continuation in
                            withObservationTracking { _ = editor.draft(key) } onChange: { continuation.resume() }
                        }
                    }
                    XCTAssertNotNil(editor.snapshot)
                    XCTAssertFalse(editor.draft(key)?.dirty == true)
                }
            }
        }

        func testAddWidgetSheetRendersSearchDescriptionsAndNoMatchingRows() async throws {
            try await withReviewEditor { fixture, editor in
                await editor.reload()
                XCTAssertTrue(editor.layout?.addable.contains { $0.name == "world-clock" } == true)
                try await self.render(
                    ShellWidgetLibrary(editor: editor, target: .bar),
                    fixture: fixture, windowClass: self.reviewSheet,
                    name: "review-add-widgets-380x400-dark",
                    requiredText: [
                        String(localized: "Add Widget"),
                        String(localized: "Search widgets"),
                        String(localized: "Cancel")
                    ]
                )
                try await self.render(
                    ShellWidgetLibrary(editor: editor, target: .bar, query: "Time in the places"),
                    fixture: fixture, windowClass: self.reviewSheet,
                    name: "review-add-widgets-description-search-380x400-dark",
                    requiredText: [
                        String(localized: "World Clock"), String(localized: "Time in the places you choose."),
                        String(localized: "Add to")
                    ],
                    forbiddenText: [String(localized: "Calendar")]
                )
                try await self.render(
                    ShellWidgetLibrary(editor: editor, target: .bar, query: "__no_matching_widget__"),
                    fixture: fixture, windowClass: self.reviewSheet,
                    name: "review-add-widgets-no-match-380x400-dark",
                    requiredText: [String(localized: "Add Widget"), String(localized: "Cancel")],
                    forbiddenText: [
                        String(localized: "World Clock"),
                        String(localized: "Time in the places you choose.")
                    ]
                )
            }
        }

        func testEditorFormLoadingAndFailureHideSelectedStyleControls() async throws {
            try await withReviewEditor { fixture, editor in
                let absent = [String(localized: "Widget Lanes"), String(localized: "Position & Level")]
                XCTAssertNil(editor.snapshot)
                try await self.render(
                    ShellDesktopEditorForm(editor: editor), fixture: fixture, windowClass: self.reviewCompact,
                    name: "review-editor-loading-539x480-dark", requiredText: [String(localized: "Loading style…")],
                    forbiddenText: absent
                )
                _ = await editor.selectStyle("missing")
                XCTAssertNil(editor.snapshot)
                XCTAssertNotNil(editor.problem)
                try await self.render(
                    ShellDesktopEditorForm(editor: editor), fixture: fixture, windowClass: self.reviewCompact,
                    name: "review-editor-unavailable-539x480-dark", requiredText: [String(localized: "Retry")],
                    forbiddenText: absent + [String(localized: "Loading style…")]
                )
            }
        }

        func testEditorGlobalAndWidgetOptionsRenderTheirScopeLabels() async throws {
            try await withReviewEditor { fixture, editor in
                await editor.reload()
                try await self.render(
                    Form { ShellDesktopAllStyles(editor: editor) }.formStyle(.grouped),
                    fixture: fixture, windowClass: .init(size: CGSize(width: 819, height: 680), dark: false),
                    name: "review-global-scope-labels-819x680-light",
                    requiredText: [
                        String(localized: "Excluded Apps — All Monitors"),
                        String(localized: "App Icon Overrides — All Monitors"),
                        String(localized: "Shared by all styles")
                    ]
                )
                let selected = await editor.selectWidget("clock")
                XCTAssertTrue(selected)
                try await self.render(
                    Form { ShellDesktopWidgetInspector(editor: editor, widget: "clock") }.formStyle(.grouped),
                    fixture: fixture, windowClass: self.reviewCompact,
                    name: "review-widget-scope-labels-539x480-dark",
                    requiredText: [
                        String(localized: "Options"),
                        String(localized: "Shared by all displays in this style.")
                    ]
                )
            }
        }

        private var reviewCompact: WindowClass {
            .init(size: CGSize(width: 539, height: 480), dark: true)
        }

        private var reviewSheet: WindowClass {
            .init(size: CGSize(width: 380, height: 400), dark: true)
        }

        private func withReviewEditor(
            _ operation: @MainActor (Fixture, ShellDesktopEditor) async throws -> Void
        ) async throws {
            try requireNativeRendering()
            let fixture = try Fixture()
            try await fixture.prepare()
            let editor = ShellDesktopEditor(
                configuration: fixture.controller.workspaceBarManager.shellConfiguration,
                settings: fixture.settings, controller: fixture.controller
            )
            let original = fixture.controller.workspaceBarManager.shellConfiguration.config
            do {
                try await operation(fixture, editor)
                XCTAssertEqual(fixture.controller.workspaceBarManager.shellConfiguration.config, original)
                XCTAssertNil(fixture.controller.workspaceBarManager.shellHost)
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }
    }
#endif
