// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    func testIslandActionsWriteOnlyTheSelectedStyle() async throws {
        let fixture = try await islandFixture()
        let editor = fixture.editor
        let before = try document(fixture)
        let active = fixture.configuration.config
        let added = await editor.addComponent("world-clock")
        XCTAssertTrue(added)
        let id = try XCTUnwrap(editor.selectedComponent)
        XCTAssertEqual(editor.component(id)?.widget, "world-clock")
        try assertIslandScope(fixture, before: before, active: active)
        await islandEdit(fixture) { editor.setComponentEnabled(id, false) }
        XCTAssertEqual(editor.component(id)?.enabled, false)
        await islandEdit(fixture) { editor.setComponentEnabled(id, true) }
        await islandEdit(fixture) { editor.moveComponent(id, to: 0) }
        XCTAssertEqual(editor.islandComponents.first?.id, id)
        await islandEdit(fixture) { editor.shiftComponent(id, by: 1) }
        XCTAssertEqual(editor.islandComponents[1].id, id)
        await islandEdit(fixture) { editor.setComponentRegion(id, "side") }
        XCTAssertEqual(editor.islandRootValues["regions"], .strings([id + ":side"]))
        await islandEdit(fixture) { editor.setComponentOption(id, key: "seconds", value: .bool(true)) }
        XCTAssertEqual(editor.component(id)?.options["seconds"], .bool(true))
        editor.setComponentOption("agenda", key: "leadMinutes", value: .number(10), continuous: true)
        let componentDrained = await editor.writes.drain()
        XCTAssertTrue(componentDrained)
        XCTAssertEqual(editor.component("agenda")?.options["leadMinutes"], .number(10))
        await islandEdit(fixture) { editor.setIslandRoot("radius", value: .number(30)) }
        XCTAssertEqual(editor.islandRootValues["radius"], .number(30))
        editor.setIslandRoot("radius", value: .number(32), continuous: true)
        let rootDrained = await editor.writes.drain()
        XCTAssertTrue(rootDrained)
        XCTAssertEqual(editor.islandRootValues["radius"], .number(32))
        await islandEdit(fixture) { editor.setIslandPlacement("notch", key: "displays") }
        XCTAssertEqual(editor.island?.displays, .notch)
        await islandEdit(fixture) { editor.setIslandPlacement("show", key: "fullscreen") }
        XCTAssertEqual(editor.island?.fullscreen, .show)
        await islandEdit(fixture) { editor.setIslandPlacement(800, key: "width") }
        await islandEdit(fixture) { editor.setIslandPlacement(400, key: "height") }
        XCTAssertEqual(editor.island?.size, CGSize(width: 800, height: 400))
        try assertIslandScope(fixture, before: before, active: active)
        await islandEdit(fixture) { editor.removeComponent(id) }
        XCTAssertNil(editor.component(id))
        try assertIslandScope(fixture, before: before, active: active)
    }

    func testIslandDragUsesInsertionIndicesAndRejectsForeignStaleUnknownAndSamePositionPayloads() async throws {
        let fixture = try await islandFixture()
        let editor = fixture.editor
        let ids = editor.islandComponents.map(\.id)
        let first = try XCTUnwrap(ids.first)
        let payload = editor.componentDragPayload(for: first)
        XCTAssertFalse(editor.dropComponent("clock", at: 1))
        XCTAssertFalse(editor.dropComponent(["omniwm-island", "foreign", "lake", first].joined(separator: "\n"), at: 2))
        XCTAssertFalse(editor.dropComponent(
            ["omniwm-island", editor.dragToken, "default", first].joined(separator: "\n"),
            at: 2
        ))
        XCTAssertFalse(editor.dropComponent(editor.componentDragPayload(for: "unknown"), at: 2))
        XCTAssertFalse(editor.dropComponent(payload, at: 0))
        XCTAssertFalse(editor.dropComponent(payload, at: 1))
        XCTAssertEqual(fixture.saves.count, 0)
        await islandEdit(fixture) { XCTAssertTrue(editor.dropComponent(payload, at: 3)) }
        var expected = ids
        expected.removeFirst()
        expected.insert(first, at: 2)
        XCTAssertEqual(editor.islandComponents.map(\.id), expected)
        XCTAssertEqual(editor.selectedComponent, first)
        let stale = editor.componentDragPayload(for: first)
        let switched = await editor.selectStyle("default")
        XCTAssertTrue(switched)
        XCTAssertFalse(editor.dropComponent(stale, at: 0))
    }

    func testIslandAddAndDropKeepAnotherComponentsDirtyDraft() async throws {
        let fixture = try await islandFixture()
        let editor = fixture.editor
        let selected = await editor.selectComponent("london")
        XCTAssertTrue(selected)
        editor.beginComponentTextDraft("london", key: "label")
        let key = ShellEditorDraft.Key.component("london", option: "label")
        editor.updateDraft(key, .text("Home"))
        let draft = editor.draft(key)
        let added = await editor.addComponent("world-clock")
        XCTAssertTrue(added)
        XCTAssertEqual(editor.selectedComponent, "london")
        XCTAssertEqual(editor.draft(key), draft)
        await islandEdit(fixture) {
            XCTAssertTrue(editor.dropComponent(editor.componentDragPayload(for: "tokyo"), at: 0))
        }
        XCTAssertEqual(editor.selectedComponent, "london")
        XCTAssertEqual(editor.draft(key), draft)
    }

    func testEveryBundledIslandKindAndSelectedCatalogResolveFromTheSnapshot() async throws {
        let fixture = try await fixture()
        for style in ["default", "celestial", "matrix", "nocturne", "sakura", "wayline"] {
            let changed = await fixture.editor.selectStyle(style)
            XCTAssertTrue(changed)
            await fixture.editor.reload()
            XCTAssertEqual(fixture.editor.islandKind, .focusRibbon, style)
            XCTAssertEqual(fixture.editor.island?.root, "focus-ribbon", style)
        }
        let changed = await fixture.editor.selectStyle("lake")
        XCTAssertTrue(changed)
        XCTAssertEqual(fixture.editor.islandKind, .composed)
        XCTAssertEqual(fixture.editor.island?.root, "lake")
        XCTAssertTrue(fixture.editor.islandEntries.contains { $0.widget == "world-clock" && $0.descriptor != nil })
        XCTAssertEqual(fixture.editor.islandEntries, fixture.editor.snapshot?.island?.entries)
        let vitreus = await fixture.editor.selectStyle("vitreus")
        XCTAssertTrue(vitreus)
        await fixture.editor.reload()
        XCTAssertEqual(fixture.editor.islandKind, .composed)
        XCTAssertEqual(fixture.editor.island?.root, "vitreus")
        XCTAssertEqual(fixture.editor.islandRootOptions["layout"]?.defaultValue, .string("island"))
        for widget in ["desk-focus", "desk-pad"] {
            XCTAssertTrue(fixture.editor.islandEntries.contains { $0.widget == widget && $0.descriptor != nil }, widget)
        }
        XCTAssertTrue(fixture.configuration.catalog?.entries.isEmpty == true)
        XCTAssertEqual(fixture.configuration.config.profile, "default")
    }

    func testControlledAbsentStyleDefinedAndUnavailableStatesKeepTheirMeaning() async throws {
        let fixture = try await fixture(style: "default")
        let base = fixture.shell.appendingPathComponent("default/shell.toml")
        let text = try String(contentsOf: base, encoding: .utf8)
        try Data(ShellTOMLText.settingNodes([(["island"], nil)], in: text).utf8).write(to: base)
        try await fixture.configuration.refresh()
        await fixture.editor.reload()
        XCTAssertEqual(fixture.editor.islandKind, .absent)
        XCTAssertNil(fixture.editor.island)
        XCTAssertTrue(fixture.editor.islandRootOptions.isEmpty)
        XCTAssertTrue(fixture.editor.islandComponents.isEmpty)
        fixture.editor.settings.island.enabled = false
        XCTAssertTrue(fixture.editor.islandToggleDisabled)
        fixture.editor.settings.island.enabled = true
        XCTAssertFalse(fixture.editor.islandToggleDisabled)
        let changed = await fixture.editor.selectStyle("lake")
        XCTAssertTrue(changed)
        fixture.editor.settings.island.enabled = false
        XCTAssertEqual(fixture.configuration.config.profile, "default")
        XCTAssertNotNil(fixture.editor.island)
        XCTAssertFalse(fixture.editor.islandToggleDisabled)
        _ = try await fixture.configuration.selectProfile("lake")
        let previewed = await fixture.editor.selectStyle("default")
        XCTAssertTrue(previewed)
        XCTAssertEqual(fixture.editor.scope, .previewing(active: "lake"))
        XCTAssertNil(fixture.editor.island)
        XCTAssertTrue(fixture.editor.islandToggleDisabled)
        fixture.editor.settings.island.enabled = true
        XCTAssertFalse(fixture.editor.islandToggleDisabled)
        let returned = await fixture.editor.selectStyle("lake")
        XCTAssertTrue(returned)
        try installIslandRoot("editor-root", in: fixture, schema: false)
        try await fixture.configuration.set("editor-root", key: "root", table: "island", profile: "lake")
        try await fixture.configuration.refresh()
        await fixture.editor.reload()
        XCTAssertEqual(fixture.editor.islandKind, .styleDefined)
        XCTAssertNotNil(fixture.editor.island)
        XCTAssertTrue(fixture.editor.islandRootOptions.isEmpty)
        XCTAssertFalse(fixture.editor.islandToggleDisabled)
        try Data("[options.caption]\ntype = \"invalid\"".utf8).write(
            to: fixture.shell.appendingPathComponent("lake/widgets/editor-root/settings.toml")
        )
        try await fixture.configuration.refresh()
        await fixture.editor.reload()
        guard case .unavailable = fixture.editor.islandKind else { return XCTFail("Catalog failure was hidden") }
        XCTAssertNotNil(fixture.editor.snapshot?.islandProblem)
        XCTAssertNil(fixture.editor.snapshot?.island)
    }

    func islandFixture() async throws -> Fixture {
        let fixture = try await fixture()
        let selected = await fixture.editor.selectSurface(.island)
        XCTAssertTrue(selected)
        XCTAssertEqual(fixture.editor.islandKind, .composed)
        return fixture
    }

    func islandEdit(_ fixture: Fixture, _ operation: @MainActor () -> Void) async {
        let save = fixture.saves.count + 1
        operation()
        await fixture.saves.wait(save)
        await fixture.editor.reload()
    }

    func assertIslandScope(_ fixture: Fixture, before: [String: TOMLNode], active: ShellConfig) throws {
        XCTAssertEqual(outsideLake(try document(fixture)), outsideLake(before))
        XCTAssertEqual(fixture.configuration.config, active)
        XCTAssertEqual(fixture.editor.selectedStyle, "lake")
        XCTAssertEqual(fixture.editor.scope, .previewing(active: "default"))
    }

    func installIslandRoot(_ name: String, in fixture: Fixture, schema: Bool = true) throws {
        let folder = fixture.shell.appendingPathComponent("lake/widgets/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("function render(ctx) return ui.box{w=20,h=20} end".utf8)
            .write(to: folder.appendingPathComponent("init.luau"))
        if schema {
            try Data("""
            [options.caption]
            type = "string"
            title = "Caption"
            default = "Before"
            maxLength = 6
            [options.lines]
            type = "strings"
            title = "Lines"
            default = ["One"]
            maxLength = 6
            """.utf8).write(to: folder.appendingPathComponent("settings.toml"))
        }
    }
}
