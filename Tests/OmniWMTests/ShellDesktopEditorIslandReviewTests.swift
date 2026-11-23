// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    func testFailedRoutedSaveRestoresTheRetainedRouteAndLetsTheSameResultOpenAgain() async throws {
        let fixture = try await islandFixture()
        let navigation = SettingsNavigationModel()
        let retained = SettingsRoute(section: .styles, tab: "island", itemID: "london")
        navigation.proceed(to: retained)
        fixture.editor.attach(navigation)
        defer { fixture.editor.detach() }
        await fixture.editor.open(retained)
        fixture.editor.beginComponentTextDraft("london", key: "label")
        let key = ShellEditorDraft.Key.component("london", option: "label")
        fixture.editor.updateDraft(key, .text("Work clock"))
        let original = fixture.editor.destination
        let requested = SettingsRoute(section: .styles, itemID: "clock")
        navigation.request(requested)
        await fixture.editor.open(navigation.route)
        XCTAssertNotNil(fixture.editor.pendingTransition)
        let file = fixture.shell.appendingPathComponent("shell.luau")
        let contents = try Data(contentsOf: file)
        try Data("[invalid".utf8).write(to: file)
        defer { try? contents.write(to: file) }
        await fixture.editor.resolve(.save)
        XCTAssertEqual(navigation.route, retained)
        XCTAssertEqual(fixture.editor.destination, original)
        XCTAssertNil(fixture.editor.pendingTransition)
        XCTAssertTrue(fixture.editor.draft(key)?.dirty == true)
        XCTAssertNotNil(fixture.editor.draft(key)?.error)
        XCTAssertNotNil(fixture.editor.problem)
        try contents.write(to: file)
        navigation.request(requested)
        XCTAssertEqual(navigation.route, requested)
        await fixture.editor.open(navigation.route)
        XCTAssertEqual(fixture.editor.pendingTransition, .destination(.init(
            surface: .bar, widget: "clock", component: "london", group: nil
        )))
        await fixture.editor.resolve(.save)
        XCTAssertEqual(navigation.route, requested)
        XCTAssertEqual(fixture.editor.surface, .bar)
        XCTAssertNil(fixture.editor.draft(key))
        XCTAssertEqual(fixture.saves.count, 1)
    }

    func testFailureWhileDrainingARoutedSelectionRestoresTheRetainedRoute() async throws {
        let fixture = try await islandFixture()
        let navigation = SettingsNavigationModel()
        let retained = SettingsRoute(section: .styles, tab: "island")
        navigation.proceed(to: retained)
        fixture.editor.attach(navigation)
        defer { fixture.editor.detach() }
        let held = HeldWrite()
        let target = fixture.editor.islandRootTarget("radius")
        fixture.editor.writes.submit(30, for: target, write: held.write)
        await held.entered.wait(1)
        let requested = SettingsRoute(section: .styles, itemID: "clock")
        navigation.request(requested)
        let entered = Events()
        let opening = Task {
            entered.record()
            await fixture.editor.open(navigation.route)
        }
        await entered.wait(1)
        XCTAssertEqual(fixture.editor.surface, .island)
        XCTAssertEqual(navigation.route, requested)
        held.finish(failing: true)
        await opening.value
        XCTAssertEqual(navigation.route, retained)
        XCTAssertEqual(fixture.editor.surface, .island)
        XCTAssertNotNil(fixture.editor.writes.failure(for: target))
        navigation.request(requested)
        await fixture.editor.open(navigation.route)
        XCTAssertNotNil(fixture.editor.pendingTransition)
        await fixture.editor.resolve(.discard)
        XCTAssertEqual(fixture.editor.surface, .bar)
        XCTAssertEqual(navigation.route, requested)
    }

    func testFailureWhileDrainingALeaveClearsPendingMonitorSetupAndRuleDraft() async throws {
        for rule in [false, true] {
            let fixture = try await islandFixture()
            let navigation = SettingsNavigationModel()
            let retained = SettingsRoute(section: .styles, tab: "island")
            navigation.proceed(to: retained)
            fixture.editor.attach(navigation)
            defer { fixture.editor.detach() }
            let held = HeldWrite()
            let target = fixture.editor.islandRootTarget("radius")
            fixture.editor.writes.submit(30, for: target, write: held.write)
            await held.entered.wait(1)
            let failed = Events()
            observeProblem(fixture.editor, changed: failed)
            if rule { navigation.presentRuleDraft(AppRuleDraft()) }
            else { navigation.requestMonitorSetupPresentation() }
            XCTAssertEqual(navigation.route, retained)
            XCTAssertFalse(fixture.editor.hasUnsavedChanges)
            if !rule { XCTAssertTrue(navigation.hasPendingMonitorSetupPresentation) }
            held.finish(failing: true)
            await failed.wait(1)
            XCTAssertEqual(navigation.route, retained)
            XCTAssertNotNil(fixture.editor.writes.failure(for: target))
            XCTAssertFalse(navigation.hasPendingMonitorSetupPresentation)
            navigation.proceed(to: SettingsRoute(section: .appRules))
            XCTAssertNil(navigation.ruleEditorState.requestedDraft)
        }
    }

    func testRemovingTheSelectedWeatherOrCalendarDropsItsSharedWeatherDraftAfterSuccess() async throws {
        for id in ["agenda", "forecast"] {
            let fixture = try await islandFixture()
            let selected = await fixture.editor.selectComponent(id)
            XCTAssertTrue(selected)
            await fixture.editor.beginWeatherDraft()
            guard case var .weather(weather)? = fixture.editor.draft(.weather)?.value else {
                return XCTFail("Missing Weather draft")
            }
            weather.city = "Belfast"
            fixture.editor.updateDraft(.weather, .weather(weather))
            XCTAssertTrue(fixture.editor.hasUnsavedChanges)
            let root = try document(fixture)["weather"]
            await islandEdit(fixture) { fixture.editor.removeComponent(id) }
            XCTAssertNil(fixture.editor.component(id))
            XCTAssertNil(fixture.editor.selectedComponent)
            XCTAssertNil(fixture.editor.draft(.weather))
            XCTAssertFalse(fixture.editor.hasUnsavedChanges)
            XCTAssertEqual(try document(fixture)["weather"], root)
        }
    }

    func testFailedRemovalKeepsTheSelectedComponentsSharedWeatherDraft() async throws {
        let fixture = try await islandFixture()
        _ = await fixture.editor.selectComponent("forecast")
        await fixture.editor.beginWeatherDraft()
        guard case var .weather(weather)? = fixture.editor.draft(.weather)?.value else {
            return XCTFail("Missing Weather draft")
        }
        weather.city = "Belfast"
        fixture.editor.updateDraft(.weather, .weather(weather))
        let original = fixture.editor.draft(.weather)
        let held = HeldWrite()
        let target = fixture.editor.islandRootTarget("radius")
        fixture.editor.writes.submit(30, for: target, write: held.write)
        await held.entered.wait(1)
        held.finish(failing: true)
        let drained = await fixture.editor.writes.drain()
        XCTAssertFalse(drained)
        let failed = Events()
        observeProblem(fixture.editor, changed: failed)
        fixture.editor.removeComponent("forecast")
        await failed.wait(1)
        XCTAssertNotNil(fixture.editor.component("forecast"))
        XCTAssertEqual(fixture.editor.selectedComponent, "forecast")
        XCTAssertEqual(fixture.editor.draft(.weather), original)
        XCTAssertTrue(fixture.editor.hasUnsavedChanges)
        XCTAssertEqual(fixture.saves.count, 0)
    }

    func testGroupOnlyIslandRoutesKeepDirtyDraftsAndFailedWritesWithoutPrompting() async throws {
        let fixture = try await islandFixture()
        let navigation = SettingsNavigationModel()
        navigation.proceed(to: SettingsRoute(section: .styles, tab: "island"))
        fixture.editor.attach(navigation)
        defer { fixture.editor.detach() }
        fixture.editor.beginIslandRootTextDraft(key: "backgroundColor")
        let key = ShellEditorDraft.Key.islandRoot("lake", option: "backgroundColor")
        fixture.editor.updateDraft(key, .text("#123456"))
        let draft = fixture.editor.draft(key)
        XCTAssertTrue(draft?.dirty == true)
        let held = HeldWrite()
        let target = fixture.editor.islandRootTarget("radius")
        fixture.editor.writes.submit(30, for: target, write: held.write)
        await held.entered.wait(1)
        held.finish(failing: true)
        let drained = await fixture.editor.writes.drain()
        XCTAssertFalse(drained)
        let failure = fixture.editor.writes.failure(for: target)
        for group in ["appearance", "interaction", "placement"] {
            let route = SettingsRoute(section: .styles, tab: "island", anchor: group)
            navigation.request(route)
            await fixture.editor.open(navigation.route)
            XCTAssertEqual(navigation.route, route)
            XCTAssertEqual(fixture.editor.group, group)
            XCTAssertNil(fixture.editor.pendingTransition)
            XCTAssertEqual(fixture.editor.draft(key), draft)
            XCTAssertEqual(fixture.editor.writes.failure(for: target), failure)
            XCTAssertNil(fixture.editor.problem)
        }
        XCTAssertEqual(fixture.saves.count, 0)
    }
}
