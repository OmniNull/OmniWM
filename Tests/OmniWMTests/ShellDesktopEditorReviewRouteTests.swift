// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    func testSavingDismissesTheTransitionPromptBeforeTheDraftWriteCompletes() async throws {
        let fixture = try await fixture()
        let key = await dirtyText(fixture.editor)
        _ = await fixture.editor.selectWidget("clock")
        XCTAssertEqual(fixture.editor.pendingTransition, .widget("clock"))
        let gate = Gate()
        let writer = ShellIslandConfigWriter(shellDirectory: fixture.shell, reloadReady: {})
        fixture.configuration.writer = writer
        let held = Task { try await writer.perform { _ in gate.block() } }
        await gate.wait()
        defer { gate.finish() }
        let entered = Events()
        let resolution = Task {
            entered.record()
            await fixture.editor.resolve(.save)
        }
        await entered.wait(1)
        XCTAssertNil(fixture.editor.pendingTransition)
        XCTAssertTrue(fixture.editor.draft(key)?.saving == true)
        XCTAssertEqual(fixture.editor.selectedWidget, "omniwm")
        gate.finish()
        try await held.value
        await resolution.value
        XCTAssertNil(fixture.editor.draft(key))
        XCTAssertEqual(fixture.editor.selectedWidget, "clock")
    }

    func testFailedTransitionSaveRetainsTheDraftWithoutReopeningThePrompt() async throws {
        let fixture = try await fixture()
        let key = await dirtyText(fixture.editor)
        let original = try XCTUnwrap(fixture.editor.draft(key))
        _ = await fixture.editor.selectStyle("nocturne")
        let file = fixture.shell.appendingPathComponent("shell.luau")
        let saved = try Data(contentsOf: file)
        try Data("[invalid".utf8).write(to: file)
        defer { try? saved.write(to: file) }
        await fixture.editor.resolve(.save)
        XCTAssertNil(fixture.editor.pendingTransition)
        XCTAssertEqual(fixture.editor.selectedStyle, "lake")
        XCTAssertEqual(fixture.editor.selectedWidget, "omniwm")
        XCTAssertNotNil(fixture.editor.problem)
        let retained = try XCTUnwrap(fixture.editor.draft(key))
        XCTAssertEqual(retained.id, original.id)
        XCTAssertEqual(retained.profile, original.profile)
        XCTAssertEqual(retained.value, original.value)
        XCTAssertTrue(retained.dirty)
        XCTAssertFalse(retained.saving)
        XCTAssertNotNil(retained.error)
        try saved.write(to: file)
        let changed = await fixture.editor.selectStyle("nocturne")
        XCTAssertFalse(changed)
        XCTAssertEqual(fixture.editor.pendingTransition, .style("nocturne"))
        await fixture.editor.resolve(.save)
        XCTAssertNil(fixture.editor.pendingTransition)
        XCTAssertNil(fixture.editor.draft(key))
        XCTAssertEqual(fixture.editor.selectedStyle, "nocturne")
    }

    func testDirectWidgetSelectionReflectsTheRouteWithoutClearingSearch() async throws {
        let fixture = try await fixture()
        let navigation = SettingsNavigationModel()
        navigation.proceed(to: SettingsRoute(section: .styles, tab: "appearance"))
        fixture.editor.attach(navigation)
        defer { fixture.editor.detach() }
        navigation.searchText = "clock"
        let selected = await fixture.editor.selectWidget("clock")
        XCTAssertTrue(selected)
        XCTAssertEqual(navigation.route, SettingsRoute(section: .styles, itemID: "clock"))
        XCTAssertEqual(navigation.searchText, "clock")
        await fixture.editor.open(navigation.route)
        XCTAssertEqual(fixture.editor.selectedWidget, "clock")
        let deselected = await fixture.editor.selectWidget(nil)
        XCTAssertTrue(deselected)
        XCTAssertEqual(navigation.route, SettingsRoute(section: .styles))
        XCTAssertEqual(navigation.searchText, "clock")
    }

    func testCancelingAWidgetRouteReflectsTheAcceptedSelectionAndKeepsSearch() async throws {
        let fixture = try await fixture()
        let navigation = SettingsNavigationModel()
        navigation.proceed(to: SettingsRoute(section: .styles))
        fixture.editor.attach(navigation)
        defer { fixture.editor.detach() }
        let key = await dirtyText(fixture.editor)
        XCTAssertEqual(navigation.route, SettingsRoute(section: .styles, itemID: "omniwm"))
        let requested = SettingsRoute(section: .styles, itemID: "clock")
        navigation.request(requested)
        navigation.searchText = "Clock"
        await fixture.editor.open(requested)
        await fixture.editor.resolve(.cancel)
        XCTAssertEqual(fixture.editor.selectedWidget, "omniwm")
        XCTAssertTrue(fixture.editor.draft(key)?.dirty == true)
        XCTAssertEqual(navigation.route, SettingsRoute(section: .styles, itemID: "omniwm"))
        XCTAssertEqual(navigation.searchText, "Clock")
        navigation.request(requested)
        await fixture.editor.open(navigation.route)
        XCTAssertEqual(fixture.editor.pendingTransition, .destination(.init(
            surface: .bar, widget: "clock", component: nil, group: nil
        )))
    }

    func testFocusAndDropReflectTheSelectedWidgetWithoutClearingSearch() async throws {
        let fixture = try await fixture()
        let navigation = SettingsNavigationModel()
        navigation.proceed(to: SettingsRoute(section: .styles))
        fixture.editor.attach(navigation)
        defer { fixture.editor.detach() }
        navigation.searchText = "widget"
        fixture.editor.focus("clock")
        XCTAssertEqual(fixture.editor.selectedWidget, "clock")
        XCTAssertEqual(navigation.route.itemID, "clock")
        XCTAssertEqual(navigation.searchText, "widget")
        let nextSave = fixture.saves.count + 1
        let accepted = fixture.editor.drop(fixture.editor.dragPayload(for: "volume"), into: .leading, at: 0)
        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.editor.selectedWidget, "volume")
        XCTAssertEqual(navigation.route, SettingsRoute(section: .styles, itemID: "volume"))
        XCTAssertEqual(navigation.searchText, "widget")
        await fixture.saves.wait(nextSave)
    }

    func testAddFocusesTheNewWidgetAndReflectsItsRoute() async throws {
        let fixture = try await fixture()
        try await fixture.configuration.editBar(profile: "lake") { $0.remove("volume") }
        await fixture.editor.reload()
        XCTAssertNil(fixture.editor.layout?.lane(of: "volume"))
        let navigation = SettingsNavigationModel()
        navigation.proceed(to: SettingsRoute(section: .styles))
        fixture.editor.attach(navigation)
        defer { fixture.editor.detach() }
        navigation.searchText = "Volume"
        let nextSave = fixture.saves.count + 1
        let added = await fixture.editor.add("volume", to: .trailing)
        XCTAssertTrue(added)
        XCTAssertEqual(fixture.editor.selectedWidget, "volume")
        XCTAssertEqual(navigation.route, SettingsRoute(section: .styles, itemID: "volume"))
        XCTAssertEqual(navigation.searchText, "Volume")
        await fixture.saves.wait(nextSave)
        let stored = try await fixture.configuration.previewConfig(profile: "lake")
        XCTAssertEqual(stored.barLane(of: "volume"), .trailing)
    }

    func testAddingAWidgetKeepsAnotherWidgetsDirtyDraftAndRoute() async throws {
        let fixture = try await fixture()
        try await fixture.configuration.editBar(profile: "lake") { $0.remove("volume") }
        await fixture.editor.reload()
        let navigation = SettingsNavigationModel()
        navigation.proceed(to: SettingsRoute(section: .styles))
        fixture.editor.attach(navigation)
        defer { fixture.editor.detach() }
        let key = await dirtyText(fixture.editor)
        let original = fixture.editor.draft(key)
        navigation.searchText = "Volume"
        let nextSave = fixture.saves.count + 1
        let added = await fixture.editor.add("volume", to: .trailing)
        XCTAssertTrue(added)
        XCTAssertEqual(fixture.editor.selectedWidget, "omniwm")
        XCTAssertEqual(navigation.route, SettingsRoute(section: .styles, itemID: "omniwm"))
        XCTAssertEqual(navigation.searchText, "Volume")
        XCTAssertEqual(fixture.editor.draft(key), original)
        await fixture.saves.wait(nextSave)
        let stored = try await fixture.configuration.previewConfig(profile: "lake")
        XCTAssertEqual(stored.barLane(of: "volume"), .trailing)
        XCTAssertEqual(fixture.editor.draft(key), original)
    }

    func testRuntimeStatesHaveHumanTitles() {
        let locale = Locale(identifier: "en")
        for (state, title) in [
            ("loaded", "Loaded"), ("loading", "Loading"), ("failed", "Failed"),
            ("fallback", "Using built-in fallback")
        ] {
            XCTAssertEqual(ShellWidgetSettingsModel.title(state, locale: locale), title)
        }
    }
}
