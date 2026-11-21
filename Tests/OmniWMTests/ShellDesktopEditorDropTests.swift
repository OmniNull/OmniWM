// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    func testLocalCrossLaneDropUsesTheInsertionIndexAndSelectsTheMovedWidget() async throws {
        let fixture = try await fixture()
        try await fixture.configuration.editBar(profile: "lake") {
            $0.leading = ["clock", "weather"]
            $0.center = ["volume", "battery"]
            $0.trailing = ["omniwm"]
        }
        await fixture.editor.reload()
        let nextSave = fixture.saves.count + 1
        let accepted = fixture.editor.drop(fixture.editor.dragPayload(for: "clock"), into: .center, at: 1)
        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.editor.selectedWidget, "clock")
        await fixture.saves.wait(nextSave)
        let config = try await fixture.configuration.previewConfig(profile: "lake")
        XCTAssertEqual(config.leading, ["weather"])
        XCTAssertEqual(config.center, ["volume", "clock", "battery"])
        XCTAssertEqual(config.trailing, ["omniwm"])
    }

    func testSameLaneDropToLaterIndexAccountsForTheRemovedSource() async throws {
        let fixture = try await fixture()
        try await fixture.configuration.editBar(profile: "lake") {
            $0.leading = ["clock", "weather", "volume", "battery"]
        }
        await fixture.editor.reload()
        let nextSave = fixture.saves.count + 1
        let accepted = fixture.editor.drop(fixture.editor.dragPayload(for: "clock"), into: .leading, at: 3)
        XCTAssertTrue(accepted)
        await fixture.saves.wait(nextSave)
        let config = try await fixture.configuration.previewConfig(profile: "lake")
        XCTAssertEqual(config.leading, ["weather", "volume", "clock", "battery"])
    }

    private func priorityFixture(listing listed: [String]) async throws -> Fixture {
        let fixture = try await fixture()
        fixture.editor.settings.hiddenBar.enabled = false
        try await fixture.configuration.editBar(profile: "lake") {
            $0.leading = ["clock", "weather"]
            $0.center = ["volume"]
            $0.trailing = ["omniwm", "battery"]
        }
        try await fixture.configuration.editPriority(profile: "lake") { _ in listed }
        await fixture.editor.reload()
        return fixture
    }

    func testPriorityListsTheStylesBarWidgetsMostImportantFirst() async throws {
        let fixture = try await priorityFixture(listing: ["volume", "battery"])
        XCTAssertEqual(fixture.editor.priorityOrder, ["volume", "battery", "clock", "weather", "omniwm"])

        fixture.editor.settings.hiddenBar.enabled = true
        let hidden = try XCTUnwrap(fixture.editor.snapshot?.config.hiddenBarWidget)
        XCTAssertEqual(fixture.editor.priorityOrder, ["volume", "battery", "clock", "weather", "omniwm", hidden])
    }

    func testPriorityEditsRewriteTheOrderAndKeepListedWidgetsThatAreNotShown() async throws {
        let fixture = try await priorityFixture(listing: ["volume", "ghost", "battery"])
        XCTAssertEqual(fixture.editor.priorityOrder, ["volume", "battery", "clock", "weather", "omniwm"])

        var nextSave = fixture.saves.count + 1
        fixture.editor.shiftPriority("clock", by: -1)
        await fixture.saves.wait(nextSave)
        var config = try await fixture.configuration.previewConfig(profile: "lake")
        XCTAssertEqual(config.priority, ["volume", "clock", "battery", "weather", "omniwm", "ghost"])

        await fixture.editor.reload()
        nextSave = fixture.saves.count + 1
        XCTAssertTrue(fixture.editor.dropPriority(fixture.editor.priorityPayload(for: "omniwm"), at: 0))
        await fixture.saves.wait(nextSave)
        config = try await fixture.configuration.previewConfig(profile: "lake")
        XCTAssertEqual(config.priority, ["omniwm", "volume", "clock", "battery", "weather", "ghost"])
        XCTAssertEqual(config.leading, ["clock", "weather"])
        XCTAssertEqual(config.trailing, ["omniwm", "battery"])
    }

    func testQuickPriorityMovesComposeBeforeTheEditorReloads() async throws {
        let fixture = try await priorityFixture(listing: ["volume", "battery", "clock", "weather"])
        XCTAssertEqual(fixture.editor.priorityOrder, ["volume", "battery", "clock", "weather", "omniwm"])
        let nextSave = fixture.saves.count + 2
        fixture.editor.shiftPriority("volume", by: 1)
        fixture.editor.shiftPriority("omniwm", by: -1)
        await fixture.saves.wait(nextSave)
        let config = try await fixture.configuration.previewConfig(profile: "lake")
        XCTAssertEqual(config.priority, ["battery", "volume", "clock", "omniwm", "weather"])
    }

    func testPriorityAndLaneDropsRejectEachOthersPayloads() async throws {
        let fixture = try await fixture()
        let file = fixture.shell.appendingPathComponent("shell.toml")
        let original = try Data(contentsOf: file)
        let name = try XCTUnwrap(fixture.editor.priorityOrder.first)
        XCTAssertFalse(fixture.editor.drop(fixture.editor.priorityPayload(for: name), into: .center, at: 0))
        XCTAssertFalse(fixture.editor.dropPriority(fixture.editor.dragPayload(for: name), at: 0))
        XCTAssertFalse(fixture.editor.dropPriority("some foreign text containing \(name)", at: 0))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testDropsRejectForeignTextOtherEditorsAndStaleStylePayloads() async throws {
        let fixture = try await fixture()
        let other = ShellDesktopEditor(
            configuration: fixture.configuration, settings: fixture.editor.settings,
            controller: fixture.editor.controller
        )
        _ = await other.selectStyle("nocturne")
        let stale = fixture.editor.dragPayload(for: "clock")
        _ = await fixture.editor.selectStyle("nocturne")
        let file = fixture.shell.appendingPathComponent("shell.toml")
        let original = try Data(contentsOf: file)
        let snapshot = fixture.editor.snapshot?.config
        for payload in [
            "some foreign text containing clock", other.dragPayload(for: "clock"), stale,
            fixture.editor.dragPayload(for: "not-a-widget")
        ] {
            XCTAssertFalse(fixture.editor.drop(payload, into: .leading, at: 0))
            XCTAssertNil(fixture.editor.selectedWidget)
            XCTAssertEqual(fixture.editor.snapshot?.config, snapshot)
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testDropMovesTheWidgetButKeepsAnotherWidgetsDirtyDraftSelected() async throws {
        let fixture = try await fixture()
        let key = await dirtyText(fixture.editor)
        let original = fixture.editor.draft(key)
        let before = try XCTUnwrap(fixture.editor.layout)
        let destination: ShellLane = before.lane(of: "clock") == .leading ? .trailing : .leading
        let nextSave = fixture.saves.count + 1
        XCTAssertTrue(fixture.editor.drop(fixture.editor.dragPayload(for: "clock"), into: destination, at: 0))
        XCTAssertEqual(fixture.editor.selectedWidget, "omniwm")
        XCTAssertEqual(fixture.editor.draft(key), original)
        await fixture.saves.wait(nextSave)
        let config = try await fixture.configuration.previewConfig(profile: "lake")
        XCTAssertEqual(ShellBarLayout(config: config, shellDirectory: fixture.shell).lane(of: "clock"), destination)
        XCTAssertEqual(fixture.editor.draft(key), original)
    }

    func testNavigationGuardInterceptsLeavingButAllowsSameSectionRoutes() async throws {
        let fixture = try await fixture()
        let navigation = SettingsNavigationModel()
        let initial = SettingsRoute(section: .styles, itemID: "omniwm")
        navigation.proceed(to: initial)
        fixture.editor.attach(navigation)
        let key = await dirtyText(fixture.editor)
        let destination = SettingsRoute(section: .general)
        navigation.request(destination)
        XCTAssertEqual(navigation.route, initial)
        XCTAssertEqual(fixture.editor.pendingTransition, .leave(destination))
        XCTAssertTrue(fixture.editor.draft(key)?.dirty == true)
        await fixture.editor.resolve(.cancel)
        let local = SettingsRoute(section: .styles, tab: "bar", itemID: "clock")
        navigation.request(local)
        XCTAssertEqual(navigation.route, local)
        XCTAssertNil(fixture.editor.pendingTransition)
        XCTAssertTrue(fixture.editor.draft(key)?.dirty == true)
        navigation.request(destination)
        await fixture.editor.resolve(.discard)
        XCTAssertEqual(navigation.route, destination)
        fixture.editor.detach()
        XCTAssertNil(navigation.leaveGuard)
    }

    func testNavigationCloseUsesTheSameDirtyGuardAndDiscardCloses() async throws {
        let fixture = try await fixture()
        let navigation = SettingsNavigationModel()
        navigation.proceed(to: SettingsRoute(section: .styles))
        let closed = Events()
        navigation.closeWindow = { closed.record() }
        fixture.editor.attach(navigation)
        _ = await dirtyText(fixture.editor)
        XCTAssertTrue(navigation.leaveGuard?(nil) == true)
        XCTAssertEqual(fixture.editor.pendingTransition, .leave(nil))
        XCTAssertEqual(closed.count, 0)
        await fixture.editor.resolve(.cancel)
        XCTAssertEqual(closed.count, 0)
        XCTAssertTrue(navigation.leaveGuard?(nil) == true)
        await fixture.editor.resolve(.discard)
        XCTAssertEqual(closed.count, 1)
        fixture.editor.detach()
    }

    func testCleanNavigationAndCloseWaitForContinuousWritesToDrain() async throws {
        for closesWindow in [false, true] {
            let fixture = try await fixture()
            let navigation = SettingsNavigationModel()
            let initial = SettingsRoute(section: .styles)
            let destination = SettingsRoute(section: .general)
            navigation.proceed(to: initial)
            let closed = Events()
            navigation.closeWindow = { closed.record() }
            fixture.editor.attach(navigation)
            let routeChanges = Events()
            observeRoute(navigation, changed: routeChanges)
            let held = HeldWrite()
            fixture.editor.writes.submit(51, for: fixture.editor.barTarget("height"), write: held.write)
            await held.entered.wait(1)
            var intercepted = false
            if closesWindow {
                intercepted = navigation.leaveGuard?(nil) == true
                XCTAssertTrue(intercepted)
                XCTAssertEqual(closed.count, 0)
            } else {
                navigation.request(destination)
                XCTAssertEqual(navigation.route, initial)
            }
            held.finish()
            let drained = await fixture.editor.writes.drain()
            XCTAssertTrue(drained)
            if closesWindow {
                if intercepted { await closed.wait(1) }
                XCTAssertEqual(closed.count, 1)
            } else {
                await routeChanges.wait(1)
                XCTAssertEqual(navigation.route, destination)
            }
            fixture.editor.detach()
        }
    }
}
