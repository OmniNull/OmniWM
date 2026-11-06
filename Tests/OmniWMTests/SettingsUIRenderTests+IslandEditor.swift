// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    extension SettingsUIRenderTests {
        func testIslandEditorFullWindowSubstatesAtBothWindowClasses() async throws {
            try requireNativeRendering()
            for windowClass in windowClasses {
                for state in IslandEditorState.allCases {
                    let fixture = try Fixture()
                    try await fixture.prepare()
                    do {
                        let configuration = fixture.controller.workspaceBarManager.shellConfiguration
                        try await prepareIslandFixture(fixture, state: state)
                        let original = try Data(contentsOf: configuration.shellDirectory
                            .appendingPathComponent("shell.toml"))
                        let navigation = SettingsNavigationModel()
                        navigation.proceed(to: SettingsRoute(
                            section: .styles, tab: state == .bar ? nil : "island",
                            itemID: state.componentSelected ? "london" : nil
                        ))
                        let ready = IslandEditorReady()
                        let root = islandEditorView(
                            fixture: fixture,
                            state: state,
                            navigation: navigation,
                            ready: ready
                        )
                        try await render(
                            root, fixture: fixture, windowClass: windowClass, section: .styles,
                            name: "settings-island-\(state.rawValue)-\(windowClass.suffix)",
                            requiredText: state.labels,
                            requiredObservations: state == .dirtyDraft ? [] : [
                                String(localized: "Bar"),
                                String(localized: "Island"), String(localized: "Drawers")
                            ],
                            editorFormScrollOffset: state.scrollOffset(dark: windowClass.dark)
                        ) { scale in
                            try await self.verifyIslandEditor(
                                try await ready.value(), state: state, windowClass: windowClass, scale: scale
                            )
                        }
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

        private func islandEditorView(
            fixture: Fixture, state: IslandEditorState, navigation: SettingsNavigationModel, ready: IslandEditorReady
        ) -> some View {
            SettingsView(
                settings: fixture.settings, controller: fixture.controller,
                windowCornerPreferences: fixture.corners, updateCoordinator: nil, navigation: navigation
            )
            .environment(\.shellDesktopEditorReady, ShellDesktopEditorObserver { editor in
                if state == .dirtyDraft {
                    editor.beginComponentTextDraft("london", key: "label")
                    let key = ShellEditorDraft.Key.component("london", option: "label")
                    editor.updateDraft(key, .text("Work clock"))
                    let changed = await editor.selectSurface(.bar)
                    XCTAssertFalse(changed)
                }
                ready.finish(.success(editor))
            })
            .overlay(alignment: .bottomTrailing) {
                if let caption = state.fixtureCaption {
                    Text(caption).font(.caption).padding(4).background(.regularMaterial).padding(8)
                }
            }
        }

        private func verifyIslandEditor(
            _ editor: ShellDesktopEditor, state: IslandEditorState, windowClass: WindowClass, scale: CGFloat
        ) async throws {
            XCTAssertEqual(editor.surface, state == .bar ? .bar : .island)
            if state.componentSelected {
                XCTAssertEqual(editor.selectedComponent, "london")
            }
            if state == .dirtyDraft {
                XCTAssertEqual(editor.pendingTransition, .surface(.bar))
                XCTAssertTrue(editor.draft(.component("london", option: "label"))?.dirty == true)
            }
            if let snapshot = editor.snapshot, snapshot.config.island != nil, state != .unavailable {
                _ = try await ShellSettingsPreview.cachedImage(for: .init(
                    config: snapshot.config,
                    surface: state == .bar ? .bar : .island(expanded: false),
                    style: state == .bar ? try XCTUnwrap(editor.previewStyle) : ShellBarStyle(),
                    scale: scale, dark: windowClass.dark,
                    fullWidth: state == .bar
                        ? editor.barOverride?.settings.fullWidth ?? editor.barSettings.fullWidth
                        : editor.islandFullWidth,
                    sourceGeneration: editor.configuration.sourceGeneration,
                    display: state == .bar ? editor.previewDisplay : nil
                ))
            }
        }

        private enum IslandEditorState: String, CaseIterable {
            case widgets
            case inspector
            case component
            case componentOptions = "component-options"
            case dirtyDraft = "dirty-draft"
            case focusRibbon = "focus-ribbon"
            case absent
            case styleDefined = "style-defined"
            case unavailable
            case bar

            var componentSelected: Bool {
                self == .component || self == .componentOptions || self == .dirtyDraft
            }

            func scrollOffset(dark: Bool) -> CGFloat? {
                switch self {
                case .inspector,
                     .component: dark ? 415 : 390
                case .componentOptions: dark ? 570 : 430
                case .styleDefined: 160
                default: nil
                }
            }

            var fixtureCaption: String? {
                switch self {
                case .absent: "Controlled fixture: no island"
                case .styleDefined: "Controlled fixture: style-defined island"
                case .unavailable: "Controlled fixture: invalid island catalog"
                default: nil
                }
            }

            var labels: [String] {
                let stateLabels = switch self {
                case .widgets: [String(localized: "Island Widgets")]
                case .inspector: [String(localized: "Appearance"), String(localized: "Expanded width")]
                case .component: ["Clock", String(localized: "Enabled"), String(localized: "Placement")]
                case .componentOptions: [String(localized: "Options"), "London"]
                case .dirtyDraft: [String(localized: "Save"), String(localized: "Discard"), String(localized: "Cancel")]
                case .focusRibbon: [String(localized: "Focus Ribbon")]
                case .absent: [String(localized: "This style has no Dynamic Island.")]
                case .styleDefined: [String(localized: "Placement")]
                case .unavailable: [String(localized: "Island settings unavailable")]
                case .bar: [String(localized: "Bar Widgets")]
                }
                return stateLabels + (fixtureCaption.map { [$0] } ?? [])
            }
        }

        private func prepareIslandFixture(_ fixture: Fixture, state: IslandEditorState) async throws {
            let configuration = fixture.controller.workspaceBarManager.shellConfiguration
            guard state == .focusRibbon || state.fixtureCaption != nil else { return }
            _ = try await configuration.selectProfile("default")
            guard state.fixtureCaption != nil else { return }
            let source = configuration.shellDirectory.appendingPathComponent("default/shell.toml")
            let original = try String(contentsOf: source, encoding: .utf8)
            if state == .absent {
                try Data(ShellTOMLText.settingNodes([(["island"], nil)], in: original).utf8).write(to: source)
            } else {
                let folder = configuration.shellDirectory.appendingPathComponent("default/widgets/fixture-island")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("function render(ctx) return ui.text{text='Style island',size=18} end".utf8)
                    .write(to: folder.appendingPathComponent("init.luau"))
                if state == .unavailable {
                    try Data("[options.bad]\ntype = 'invalid'".utf8)
                        .write(to: folder.appendingPathComponent("settings.toml"))
                }
                try Data(ShellTOMLText.settingNodes(
                    [(["island", "root"], .string("fixture-island"))], in: original
                ).utf8).write(to: source)
            }
            try await configuration.refresh()
        }

        @MainActor
        private final class IslandEditorReady {
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
    }
#endif
