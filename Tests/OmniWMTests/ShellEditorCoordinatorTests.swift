// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import Synchronization
import TOML
import XCTest

@MainActor
final class ShellEditorCoordinatorTests: XCTestCase {
    func testInactiveProfileLaneEditsAndResetKeepOtherProfilesAndActiveState() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        let original = try document(fixture.shell)
        let active = configuration.config
        let defaults = try await configuration.previewConfig(profile: "lake")
        try await configuration.editBar(profile: "lake") {
            $0.leading = ["clock"]
            $0.center = ["weather"]
            $0.trailing = ["volume"]
        }
        let edited = try await configuration.editorSnapshot(profile: "lake")
        XCTAssertEqual(edited.layout.leading, ["clock"])
        XCTAssertEqual(edited.layout.center, ["weather"])
        XCTAssertEqual(edited.layout.trailing, ["volume"])
        try assertUnchangedOutside("lake", original: original, fixture: fixture, active: active)
        try await configuration.resetBarLayout(profile: "lake")
        let reset = try await configuration.editorSnapshot(profile: "lake")
        XCTAssertEqual(reset.layout.leading, defaults.leading)
        XCTAssertEqual(reset.layout.center, defaults.center)
        XCTAssertEqual(reset.layout.trailing, defaults.trailing)
        for lane in ["leading", "center", "trailing"] {
            XCTAssertNil(try node(["profiles", "lake", lane], in: fixture.shell))
        }
        try assertUnchangedOutside("lake", original: original, fixture: fixture, active: active)
    }

    func testInactiveProfileMonitorSetAndResetAreScoped() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        let original = try document(fixture.shell)
        let active = configuration.config
        let display = monitor()
        try await configuration.updateMonitor(display, profile: "lake") { $0.height = 72 }
        let edited = try await configuration.previewConfig(profile: "lake")
        XCTAssertEqual(
            MonitorSettingsStore.get(for: display, in: edited.barOverride?.monitorOverrides ?? [])?.height,
            72
        )
        try assertUnchangedOutside("lake", original: original, fixture: fixture, active: active)
        try await configuration.updateMonitor(display, profile: "lake", change: nil)
        let reset = try await configuration.previewConfig(profile: "lake")
        XCTAssertTrue(reset.barOverride?.monitorOverrides.isEmpty == true)
        XCTAssertNil(try node(["profiles", "lake", "monitorBarOverrides"], in: fixture.shell))
        try assertUnchangedOutside("lake", original: original, fixture: fixture, active: active)
    }

    func testInactiveProfileThemeResetAndSchemeUseTheirOwnStyle() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        let original = try document(fixture.shell)
        let active = configuration.config
        let lake = try await configuration.previewConfig(profile: "lake")
        let changed = try await configuration.selectTheme("nocturne", profile: "lake")
        XCTAssertTrue(changed)
        XCTAssertEqual(try node(["profiles", "lake", "theme"], in: fixture.shell), .string("nocturne"))
        try assertUnchangedOutside("lake", original: original, fixture: fixture, active: active)
        let reset = try await configuration.selectTheme(lake.styleThemeName, profile: "lake")
        XCTAssertTrue(reset)
        XCTAssertNil(try node(["profiles", "lake", "theme"], in: fixture.shell))
        let schemeChanged = try await configuration.selectScheme(.vibrant, profile: "lake")
        XCTAssertTrue(schemeChanged)
        XCTAssertEqual(try node(["profiles", "lake", "scheme"], in: fixture.shell), .string("vibrant"))
        let selected = try await configuration.previewConfig(profile: "lake")
        XCTAssertEqual(selected.themeName, lake.styleThemeName)
        XCTAssertEqual(selected.wallpaperScheme, .vibrant)
        try assertUnchangedOutside("lake", original: original, fixture: fixture, active: active)
    }

    func testInactiveProfileStatsAddsOnlyItsMissingAnchorAndKeepsItWhenDisabled() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        try await configuration.editBar(profile: "lake") { $0.trailing = ["clock"] }
        let original = try document(fixture.shell)
        let active = configuration.config
        try await configuration.setSystemStatsEnabled(true, profile: "lake")
        var lake = try await configuration.previewConfig(profile: "lake")
        let widget = try XCTUnwrap(lake.systemStatsWidget)
        XCTAssertEqual(lake.trailing, ["clock", widget])
        XCTAssertEqual(lake.barOverride?.systemStatsButton, true)
        try assertUnchangedOutside("lake", original: original, fixture: fixture, active: active)
        try await configuration.setSystemStatsEnabled(true, profile: "lake")
        lake = try await configuration.previewConfig(profile: "lake")
        XCTAssertEqual(lake.trailing, ["clock", widget])
        try await configuration.setSystemStatsEnabled(false, profile: "lake")
        lake = try await configuration.previewConfig(profile: "lake")
        XCTAssertEqual(lake.trailing, ["clock", widget])
        XCTAssertEqual(lake.barOverride?.systemStatsButton, false)
        try assertUnchangedOutside("lake", original: original, fixture: fixture, active: active)
    }

    func testInactiveProfileScalarSetAndResetPreserveOtherTables() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        let original = try document(fixture.shell)
        let active = configuration.config
        try await configuration.set(62, key: "height", profile: "lake")
        let edited = try await configuration.previewConfig(profile: "lake")
        XCTAssertEqual(edited.barOverride?.settings.height, 62)
        try assertUnchangedOutside("lake", original: original, fixture: fixture, active: active)
        try await configuration.reset(profile: "lake")
        XCTAssertNil(try node(["profiles", "lake", "workspaceBar"], in: fixture.shell))
        try assertUnchangedOutside("lake", original: original, fixture: fixture, active: active)
    }

    func testUnknownExplicitProfilesRejectAllEditsWithoutAnyWrite() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        let bytes = try Data(contentsOf: fixture.shell.appendingPathComponent("shell.toml"))
        let active = configuration.config
        let revision = configuration.revision
        let writes = Mutex(0)
        configuration.writer = ShellIslandConfigWriter(shellDirectory: fixture.shell, writeFile: { data, url in
            writes.withLock { $0 += 1 }
            try SettingsFileAccess.writeAtomically(data, at: url)
        }, reloadReady: {})
        let operations: [(String, @MainActor () async throws -> Void)] = [
            ("editBar", { try await configuration.editBar(profile: "absent") { $0.leading = [] } }),
            ("resetBarLayout", { try await configuration.resetBarLayout(profile: "absent") }),
            ("updateMonitor", { try await configuration.updateMonitor(self.monitor(), profile: "absent") {
                $0.height = 72
            } }),
            ("resetMonitor", { try await configuration.updateMonitor(self.monitor(), profile: "absent", change: nil) }),
            ("selectTheme", { _ = try await configuration.selectTheme("nocturne", profile: "absent") }),
            ("selectScheme", { _ = try await configuration.selectScheme(.vibrant, profile: "absent") }),
            ("setSystemStatsEnabled", { try await configuration.setSystemStatsEnabled(true, profile: "absent") }),
            ("set", { try await configuration.set(72, key: "height", profile: "absent") }),
            ("reset", { try await configuration.reset(profile: "absent") }),
            (
                "setWidgetValue",
                { try await configuration.setWidgetValue(.bool(false), widget: "clock", key: "date", profile: "absent")
                }
            ),
            (
                "setWidgetOptions",
                { try await configuration.setWidgetOptions("ignored", widget: "clock", key: "date", profile: "absent") }
            ),
            ("editorSnapshot", { _ = try await configuration.editorSnapshot(profile: "absent") })
        ]
        for (name, operation) in operations {
            do {
                try await operation()
                XCTFail("\(name) accepted an unknown profile")
            } catch {
                XCTAssertEqual((error as NSError).code, CocoaError.fileNoSuchFile.rawValue, name)
            }
        }
        XCTAssertEqual(writes.withLock { $0 }, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.shell.appendingPathComponent("shell.toml")), bytes)
        XCTAssertEqual(configuration.config, active)
        XCTAssertEqual(configuration.revision, revision)
    }

    func testNilTargetsKeepEditingTheActiveProfile() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        let original = try document(fixture.shell)
        try await configuration.set(50, key: "height")
        XCTAssertEqual(configuration.config.barOverride?.settings.height, 50)
        try await configuration.editBar { $0.leading = ["clock"] }
        XCTAssertEqual(configuration.config.leading, ["clock"])
        try await configuration.resetBarLayout()
        XCTAssertEqual(Array(configuration.config.leading.prefix(3)), ["apple-menu", "app-menu", "omniwm"])
        try await configuration.updateMonitor(monitor()) { $0.height = 72 }
        XCTAssertEqual(configuration.config.barOverride?.monitorOverrides.first?.height, 72)
        try await configuration.updateMonitor(monitor(), change: nil)
        XCTAssertTrue(configuration.config.barOverride?.monitorOverrides.isEmpty == true)
        _ = try await configuration.selectTheme("nocturne")
        XCTAssertEqual(configuration.config.themeName, "nocturne")
        _ = try await configuration.selectScheme(.vibrant)
        XCTAssertEqual(configuration.config.wallpaperScheme, .vibrant)
        try await configuration.setSystemStatsEnabled(false)
        XCTAssertEqual(configuration.config.barOverride?.systemStatsButton, false)
        try await configuration.reset()
        XCTAssertNil(try node(["profiles", "default", "workspaceBar"], in: fixture.shell))
        let current = try document(fixture.shell)
        XCTAssertEqual(outside("default", in: current), outside("default", in: original))
        XCTAssertEqual(configuration.config.profile, "default")
    }

    func testEditorSnapshotsUseTheSelectedProfilesLayoutSchemasAndThemes() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        let active = try await configuration.editorSnapshot(profile: "default")
        XCTAssertEqual(active.config, configuration.config)
        XCTAssertEqual(active.layout, configuration.barLayout)
        XCTAssertEqual(active.schemas, configuration.widgetSchemas)
        XCTAssertEqual(active.themes, configuration.themes)
        let lake = try await configuration.editorSnapshot(profile: "lake")
        XCTAssertEqual(lake.config.profile, "lake")
        XCTAssertEqual(lake.layout, ShellBarLayout(config: lake.config, shellDirectory: fixture.shell))
        XCTAssertEqual(lake.schemas["clock"]?.options["date"]?.defaultValue, .bool(false))
        XCTAssertEqual(active.schemas["clock"]?.options["date"]?.defaultValue, .bool(true))
        XCTAssertTrue(lake.themes.contains("lake-only"))
        XCTAssertFalse(active.themes.contains("lake-only"))
        XCTAssertEqual(lake.themes, ShellProfiles.themes(of: lake.config))
        XCTAssertEqual(configuration.config.profile, "default")
    }

    func testConfigOnlySnapshotChangesReuseSchemasUntilAFullMetadataRefresh() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        let first = try await configuration.editorSnapshot(profile: "lake")
        try write(schema(true), to: "lake/widgets/clock/settings.toml", in: fixture.shell)
        try await configuration.editBar(profile: "lake") { $0.trailing = ["clock"] }
        let changed = try await configuration.editorSnapshot(profile: "lake")
        XCTAssertEqual(changed.layout.trailing, ["clock"])
        XCTAssertEqual(changed.schemas, first.schemas)
        XCTAssertEqual(changed.schemas["clock"]?.options["date"]?.defaultValue, .bool(false))
        try write(schema(false), to: "lake/widgets/new-widget/settings.toml", in: fixture.shell)
        try write(
            "function render(ctx) return ui.box{} end",
            to: "lake/widgets/new-widget/init.luau",
            in: fixture.shell
        )
        try await configuration.refresh()
        let refreshed = try await configuration.editorSnapshot(profile: "lake")
        XCTAssertEqual(refreshed.layout.trailing, ["clock"])
        XCTAssertEqual(refreshed.schemas["clock"]?.options["date"]?.defaultValue, .bool(true))
        XCTAssertNotNil(refreshed.schemas["new-widget"])
        XCTAssertTrue(refreshed.layout.addable.contains { $0.name == "new-widget" })
    }

    func testInactiveSnapshotRefreshesAddedAndRemovedUnselectedThemes() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        let first = try await configuration.editorSnapshot(profile: "lake")
        XCTAssertFalse(first.themes.contains("new-palette"))
        try write("", to: "lake/themes/new-palette.toml", in: fixture.shell)
        try await configuration.refresh()
        let added = try await configuration.editorSnapshot(profile: "lake")
        XCTAssertEqual(added.config, first.config)
        XCTAssertTrue(added.themes.contains("new-palette"))
        XCTAssertEqual(added.schemas, first.schemas)
        try FileManager.default.removeItem(at: fixture.shell.appendingPathComponent("lake/themes/lake-only.toml"))
        try await configuration.refresh()
        let removed = try await configuration.editorSnapshot(profile: "lake")
        XCTAssertFalse(removed.themes.contains("lake-only"))
        XCTAssertTrue(removed.themes.contains("new-palette"))
    }

    func testDisappearedExplicitProfileCannotRedirectBarOrMonitorEditsToDefault() async throws {
        for editsMonitor in [false, true] {
            let fixture = try await fixture()
            let configuration = fixture.configuration
            let file = fixture.shell.appendingPathComponent("shell.toml")
            let original = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: fixture.shell.appendingPathComponent("lake"))
            let context = editsMonitor ? "updateMonitor" : "editBar"
            do {
                if editsMonitor {
                    try await configuration.updateMonitor(monitor(), profile: "lake") { $0.height = 91 }
                } else {
                    try await configuration.editBar(profile: "lake") { $0.leading = ["weather"] }
                }
                XCTFail("\(context) redirected an explicit edit after the profile disappeared")
            } catch let error as ShellBarLayout.Unreadable {
                XCTAssertEqual(error.problem, "lake", context)
            } catch {
                XCTFail("Unexpected \(context) error: \(error)")
            }
            XCTAssertEqual(try Data(contentsOf: file), original, context)
            XCTAssertEqual(configuration.config.profile, "default", context)
        }
    }

    func testFirstLoadPublishesOneSourceGenerationAndUnchangedRefreshKeepsIt() async throws {
        let shell = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellEditorGenerationTests-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: shell) }
        let configuration = ShellConfigurationCoordinator(shellDirectory: shell)
        XCTAssertEqual(configuration.sourceGeneration, 0)
        try await configuration.ensureLoaded()
        XCTAssertEqual(configuration.sourceGeneration, 1)
        try await configuration.ensureLoaded()
        try await configuration.refresh()
        XCTAssertEqual(configuration.sourceGeneration, 1)
    }

    func testRootOnlySettingChangesKeepSourceGeneration() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        configuration.stopObserving()
        let generation = configuration.sourceGeneration
        let revision = configuration.revision
        try await configuration.set(51, key: "height", profile: "default")
        XCTAssertEqual(configuration.config.barOverride?.settings.height, 51)
        XCTAssertGreaterThan(configuration.revision, revision)
        XCTAssertEqual(configuration.sourceGeneration, generation)
        try await configuration.refresh()
        XCTAssertEqual(configuration.sourceGeneration, generation)
    }

    func testSourceFileEditsInvalidateBeforeReturningWithObservationStopped() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        configuration.stopObserving()
        let original = configuration.config
        var generation = configuration.sourceGeneration
        for source in ["return {}", "return { value = 23 }", nil] {
            let changed = try await configuration.editFile(refreshMetadata: false) { directory in
                let file = directory.appendingPathComponent("lake/widgets/clock/editor-generation.luau")
                if let source {
                    try Data(source.utf8).write(to: file)
                } else {
                    try FileManager.default.removeItem(at: file)
                }
                return true
            }
            XCTAssertTrue(changed)
            generation += 1
            XCTAssertEqual(configuration.sourceGeneration, generation)
            XCTAssertEqual(configuration.config, original)
            try await configuration.refresh()
            XCTAssertEqual(configuration.sourceGeneration, generation)
        }
    }

    func testThemeAndAssetEditsInvalidateWithoutChangingEffectiveConfig() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        configuration.stopObserving()
        let original = configuration.config
        var generation = configuration.sourceGeneration
        for path in ["lake/themes/new-palette.toml", "lake/editor-preview.asset"] {
            let changed = try await configuration.editFile(refreshMetadata: false) { directory in
                try Data("".utf8).write(to: directory.appendingPathComponent(path))
                return true
            }
            XCTAssertTrue(changed)
            generation += 1
            XCTAssertEqual(configuration.sourceGeneration, generation, path)
            XCTAssertEqual(configuration.config, original, path)
            try await configuration.refresh()
            XCTAssertEqual(configuration.sourceGeneration, generation, path)
        }
    }

    func testRootSettingSaveConsumesNonRootTOMLChangeExactlyOnce() async throws {
        let fixture = try await fixture()
        let configuration = fixture.configuration
        configuration.stopObserving()
        let generation = configuration.sourceGeneration
        let file = fixture.shell.appendingPathComponent("default/shell.toml")
        let source = try String(contentsOf: file, encoding: .utf8)
        let changed = try ShellTOMLText.settingNodes([(["leading"], .array([.string("clock")]))], in: source)
        try Data(changed.utf8).write(to: file)
        XCTAssertNotEqual(configuration.config.leading, ["clock"])
        try await configuration.set(52, key: "height", profile: "default")
        XCTAssertEqual(configuration.config.leading, ["clock"])
        XCTAssertEqual(configuration.config.barOverride?.settings.height, 52)
        XCTAssertEqual(configuration.sourceGeneration, generation + 1)
        try await configuration.refresh()
        XCTAssertEqual(configuration.sourceGeneration, generation + 1)
    }

    private struct Fixture {
        let shell: URL
        let configuration: ShellConfigurationCoordinator
    }

    private func fixture() async throws -> Fixture {
        let shell = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellEditorTests-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: shell) }
        try ShellStyleFixture.installAll(into: shell)
        let configuration = ShellConfigurationCoordinator(shellDirectory: shell)
        try await configuration.ensureLoaded()
        try write("""
        profile = "default"
        [weather]
        city = "Toronto"
        [profiles.default.workspaceBar]
        height = 34
        [profiles.lake.workspaceBar]
        height = 40
        [profiles.nocturne.workspaceBar]
        height = 46
        """, to: "shell.toml", in: shell)
        try write("function render(ctx) return ui.box{} end", to: "lake/widgets/clock/init.luau", in: shell)
        try write(schema(false), to: "lake/widgets/clock/settings.toml", in: shell)
        try write("", to: "lake/themes/lake-only.toml", in: shell)
        try await configuration.refresh()
        XCTAssertEqual(configuration.config.profile, "default")
        XCTAssertNil(configuration.metadataError)
        return Fixture(shell: shell, configuration: configuration)
    }

    private func monitor() -> Monitor {
        Monitor(
            id: .init(displayId: 94_611), displayId: 94_611,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876), hasNotch: false, name: "Editor display"
        )
    }

    private func schema(_ date: Bool) -> String {
        """
        [options.date]
        type = "boolean"
        title = "Show date"
        default = \(date)
        """
    }

    private func write(_ text: String, to path: String, in shell: URL) throws {
        let file = shell.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((text + "\n").utf8).write(to: file)
    }

    private func document(_ shell: URL) throws -> [String: TOMLNode] {
        try TOMLDecoder().decode(
            [String: TOMLNode].self,
            from: Data(contentsOf: shell.appendingPathComponent("shell.toml"))
        )
    }

    private func node(_ path: [String], in shell: URL) throws -> TOMLNode? {
        var current: TOMLNode? = .table(try document(shell))
        for key in path {
            guard case let .table(table)? = current else { return nil }
            current = table[key]
        }
        return current
    }

    private func outside(_ profile: String, in document: [String: TOMLNode]) -> [String: TOMLNode] {
        var result = document
        if case var .table(profiles)? = result["profiles"] {
            profiles[profile] = nil
            result["profiles"] = .table(profiles)
        }
        return result
    }

    private func assertUnchangedOutside(
        _ profile: String, original: [String: TOMLNode], fixture: Fixture, active: ShellConfig,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(
            outside(profile, in: try document(fixture.shell)),
            outside(profile, in: original),
            file: file,
            line: line
        )
        XCTAssertEqual(fixture.configuration.config, active, file: file, line: line)
    }
}
