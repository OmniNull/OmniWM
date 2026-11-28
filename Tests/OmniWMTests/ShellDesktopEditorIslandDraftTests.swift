// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    func testIslandComponentAndRootDraftsSaveToTheirCapturedStyleAndTarget() async throws {
        let fixture = try await islandFixture()
        let editor = fixture.editor
        editor.beginComponentTextDraft("london", key: "label")
        let component = ShellEditorDraft.Key.component("london", option: "label")
        editor.updateDraft(component, .text("Home"))
        let componentDraft = try XCTUnwrap(editor.draft(component))
        let before = try document(fixture)
        _ = await editor.selectStyle("default")
        await editor.resolve(.discard)
        editor.setDraft(componentDraft)
        let componentSaved = await editor.saveDraft(component)
        XCTAssertTrue(componentSaved)
        var lake = try await fixture.configuration.previewConfig(profile: "lake")
        XCTAssertEqual(lake.island?.components.first { $0.id == "london" }?.options["label"], .string("Home"))
        XCTAssertEqual(editor.selectedStyle, "default")
        XCTAssertEqual(outsideLake(try document(fixture)), outsideLake(before))
        _ = await editor.selectStyle("lake")
        editor.beginIslandRootTextDraft(key: "backgroundColor")
        let root = ShellEditorDraft.Key.islandRoot("lake", option: "backgroundColor")
        editor.updateDraft(root, .text("#123456"))
        let rootDraft = try XCTUnwrap(editor.draft(root))
        _ = await editor.selectStyle("default")
        await editor.resolve(.discard)
        editor.setDraft(rootDraft)
        let rootSaved = await editor.saveDraft(root)
        XCTAssertTrue(rootSaved)
        lake = try await fixture.configuration.previewConfig(profile: "lake")
        XCTAssertEqual(
            ShellWidgetSettingsModel.values(widget: "lake", config: lake)["backgroundColor"],
            .string("#123456")
        )
        XCTAssertEqual(editor.selectedStyle, "default")
        XCTAssertEqual(fixture.configuration.config.profile, "default")
        XCTAssertEqual(outsideLake(try document(fixture)), outsideLake(before))
    }

    func testIslandTextAndLinesDraftsEnforceTheSelectedSchemasLengths() async throws {
        let fixture = try await islandFixture()
        let editor = fixture.editor
        editor.beginComponentTextDraft("london", key: "label")
        let component = ShellEditorDraft.Key.component("london", option: "label")
        XCTAssertEqual(editor.componentDescriptor("london")?.options["label"]?.maxLength, 48)
        editor.updateDraft(component, .text(String(repeating: "x", count: 49)))
        let before = try document(fixture)
        let saved = await editor.saveDraft(component)
        XCTAssertFalse(saved)
        XCTAssertTrue(editor.draft(component)?.dirty == true)
        XCTAssertNotNil(editor.draft(component)?.error)
        XCTAssertEqual(try document(fixture), before)
        editor.cancelDraft(component)
        try installIslandRoot("editor-root", in: fixture)
        try await fixture.configuration.set("editor-root", key: "root", table: "island", profile: "lake")
        try await fixture.configuration.refresh()
        await editor.reload()
        for (option, value) in [("caption", ShellEditorDraft.Value.text("Too long")), ("lines", .lines(["Too long"]))] {
            editor.beginIslandRootTextDraft(key: option)
            let key = ShellEditorDraft.Key.islandRoot("editor-root", option: option)
            XCTAssertEqual(editor.islandRootOptions[option]?.maxLength, 6)
            editor.updateDraft(key, value)
            let original = try document(fixture)
            let saved = await editor.saveDraft(key)
            XCTAssertFalse(saved)
            XCTAssertTrue(editor.draft(key)?.dirty == true)
            XCTAssertNotNil(editor.draft(key)?.error)
            XCTAssertEqual(try document(fixture), original)
            editor.cancelDraft(key)
        }
    }

    func testIslandRootDraftCannotSaveIntoAReplacementRootAfterReload() async throws {
        let fixture = try await islandFixture()
        try installIslandRoot("editor-root", in: fixture)
        try installIslandRoot("replacement-root", in: fixture)
        try await fixture.configuration.set("editor-root", key: "root", table: "island", profile: "lake")
        try await fixture.configuration.refresh()
        await fixture.editor.reload()
        fixture.editor.beginIslandRootTextDraft(key: "caption")
        let key = ShellEditorDraft.Key.islandRoot("editor-root", option: "caption")
        fixture.editor.updateDraft(key, .text("After"))
        let draft = try XCTUnwrap(fixture.editor.draft(key))
        try await fixture.configuration.set("replacement-root", key: "root", table: "island", profile: "lake")
        await fixture.editor.reload()
        XCTAssertEqual(fixture.editor.draft(key), draft)
        let before = try document(fixture)
        let saved = await fixture.editor.saveDraft(key)
        XCTAssertFalse(saved)
        XCTAssertEqual(try document(fixture), before)
        XCTAssertEqual(fixture.editor.draft(key)?.id, draft.id)
        XCTAssertEqual(fixture.editor.draft(key)?.profile, "lake")
        XCTAssertEqual(fixture.editor.draft(key)?.value, .text("After"))
        XCTAssertNotNil(fixture.editor.draft(key)?.error)
    }

    func testIslandReloadPreservesDirtyDraftsAndRefreshesCleanOnesInPlace() async throws {
        let fixture = try await islandFixture()
        let editor = fixture.editor
        editor.beginComponentTextDraft("london", key: "label")
        let component = ShellEditorDraft.Key.component("london", option: "label")
        let componentID = editor.draft(component)?.id
        _ = try await fixture.configuration.island(
            .set(id: "london", key: "label", value: .string("Home")),
            profile: "lake"
        )
        await editor.reload()
        XCTAssertEqual(editor.draft(component)?.id, componentID)
        XCTAssertEqual(editor.draft(component)?.value, .text("Home"))
        XCTAssertFalse(editor.draft(component)?.dirty == true)
        editor.updateDraft(component, .text("Draft"))
        let dirty = editor.draft(component)
        _ = try await fixture.configuration.island(
            .set(id: "london", key: "label", value: .string("Away")),
            profile: "lake"
        )
        await editor.reload()
        XCTAssertEqual(editor.draft(component), dirty)
        editor.cancelDraft(component)
        editor.beginIslandRootTextDraft(key: "backgroundColor")
        let root = ShellEditorDraft.Key.islandRoot("lake", option: "backgroundColor")
        let rootID = editor.draft(root)?.id
        _ = try await fixture.configuration.island(
            .rootSetting(key: "backgroundColor", value: .string("#123456")),
            profile: "lake"
        )
        await editor.reload()
        XCTAssertEqual(editor.draft(root)?.id, rootID)
        XCTAssertEqual(editor.draft(root)?.value, .text("#123456"))
        editor.updateDraft(root, .text("#ABCDEF"))
        let dirtyRoot = editor.draft(root)
        _ = try await fixture.configuration.island(
            .rootSetting(key: "backgroundColor", value: .string("#654321")),
            profile: "lake"
        )
        await editor.reload()
        XCTAssertEqual(editor.draft(root), dirtyRoot)
    }

    func testDirtyIslandDraftGuardsEveryContextAndCancelRetainsItsCapturedTarget() async throws {
        let transitions: [ShellDesktopEditor.Transition] = [
            .surface(.bar), .component("tokyo"), .widget("clock"), .style("default"), .useStyle,
            .leave(SettingsRoute(section: .general)), .leave(nil),
            .destination(.init(surface: .bar, widget: "clock", component: "london", group: nil))
        ]
        for transition in transitions {
            let fixture = try await islandFixture()
            _ = await fixture.editor.selectComponent("london")
            fixture.editor.beginComponentTextDraft("london", key: "label")
            let key = ShellEditorDraft.Key.component("london", option: "label")
            fixture.editor.updateDraft(key, .text("Home"))
            let draft = fixture.editor.draft(key)
            let destination = fixture.editor.destination
            let before = try document(fixture)
            let changed = await fixture.editor.request(transition)
            XCTAssertFalse(changed, "\(transition)")
            XCTAssertEqual(fixture.editor.pendingTransition, transition)
            XCTAssertEqual(fixture.editor.destination, destination)
            await fixture.editor.resolve(.cancel)
            XCTAssertNil(fixture.editor.pendingTransition)
            XCTAssertEqual(fixture.editor.destination, destination)
            XCTAssertEqual(fixture.editor.draft(key), draft)
            XCTAssertEqual(try document(fixture), before)
        }
    }

    func testIslandDirtyDraftSaveDiscardAndFailedSaveKeepTheCorrectDestination() async throws {
        for resolution in [ShellDesktopEditor.Resolution.save, .discard] {
            let fixture = try await islandFixture()
            _ = await fixture.editor.selectComponent("london")
            fixture.editor.beginComponentTextDraft("london", key: "label")
            let key = ShellEditorDraft.Key.component("london", option: "label")
            fixture.editor.updateDraft(key, .text("Home"))
            let changed = await fixture.editor.selectSurface(.bar)
            XCTAssertFalse(changed)
            await fixture.editor.resolve(resolution)
            XCTAssertEqual(fixture.editor.surface, .bar)
            XCTAssertNil(fixture.editor.pendingTransition)
            XCTAssertNil(fixture.editor.draft(key))
            let lake = try await fixture.configuration.previewConfig(profile: "lake")
            let label = lake.island?.components.first { $0.id == "london" }?.options["label"]
            switch resolution {
            case .save: XCTAssertEqual(label, .string("Home"))
            case .discard: XCTAssertEqual(label, .string("London"))
            case .cancel: XCTFail("Unexpected resolution")
            }
        }
        let fixture = try await islandFixture()
        _ = await fixture.editor.selectComponent("london")
        fixture.editor.beginComponentTextDraft("london", key: "label")
        let key = ShellEditorDraft.Key.component("london", option: "label")
        fixture.editor.updateDraft(key, .text("Home"))
        let draft = try XCTUnwrap(fixture.editor.draft(key))
        _ = await fixture.editor.selectSurface(.bar)
        let file = fixture.shell.appendingPathComponent("shell.luau")
        try Data("[broken".utf8).write(to: file)
        await fixture.editor.resolve(.save)
        XCTAssertEqual(fixture.editor.surface, .island)
        XCTAssertEqual(fixture.editor.selectedComponent, "london")
        XCTAssertEqual(fixture.editor.draft(key)?.id, draft.id)
        XCTAssertEqual(fixture.editor.draft(key)?.profile, "lake")
        XCTAssertTrue(fixture.editor.draft(key)?.dirty == true)
        XCTAssertNotNil(fixture.editor.draft(key)?.error)
        XCTAssertNotNil(fixture.editor.problem)
    }

    func testIslandWeatherUsesTheSharedRootDraftAndLeavesStyleOverlaysUnchanged() async throws {
        let fixture = try await islandFixture()
        _ = await fixture.editor.selectComponent("forecast")
        await fixture.editor.beginWeatherDraft()
        guard case var .weather(weather)? = fixture.editor.draft(.weather)?.value else {
            return XCTFail("Missing shared Weather draft")
        }
        XCTAssertEqual(weather.city, "Toronto")
        let before = try document(fixture)
        weather.city = "London"
        fixture.editor.updateDraft(.weather, .weather(weather))
        let saved = await fixture.editor.saveDraft(.weather)
        XCTAssertTrue(saved)
        let after = try document(fixture)
        XCTAssertEqual(after["profiles"], before["profiles"])
        guard case let .record(root)? = after["weather"] else { return XCTFail("Missing shared Weather") }
        XCTAssertEqual(root["city"], .string("London"))
    }
}
