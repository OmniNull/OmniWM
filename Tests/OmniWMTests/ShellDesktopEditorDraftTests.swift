// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
extension ShellDesktopEditorTests {
    func testEveryDirtyTransitionWaitsAndCancelKeepsItsDraftAndTargets() async throws {
        let transitions: [ShellDesktopEditor.Transition] = [
            .style("nocturne"), .widget("clock"), .useStyle,
            .leave(SettingsRoute(section: .general)), .leave(nil)
        ]
        for transition in transitions {
            let fixture = try await fixture()
            let key = await dirtyText(fixture.editor)
            let draft = fixture.editor.draft(key)
            let snapshot = fixture.editor.snapshot
            let bytes = try Data(contentsOf: fixture.shell.appendingPathComponent("shell.luau"))
            let changed = await fixture.editor.request(transition)
            XCTAssertFalse(changed, "\(transition)")
            XCTAssertEqual(fixture.editor.pendingTransition, transition)
            XCTAssertEqual(fixture.editor.selectedStyle, "lake")
            XCTAssertEqual(fixture.editor.selectedWidget, "omniwm")
            XCTAssertEqual(fixture.editor.snapshot?.config, snapshot?.config)
            XCTAssertEqual(fixture.editor.draft(key), draft)
            XCTAssertEqual(fixture.configuration.config.profile, "default")
            await fixture.editor.resolve(.cancel)
            XCTAssertNil(fixture.editor.pendingTransition)
            XCTAssertEqual(fixture.editor.draft(key), draft)
            XCTAssertEqual(fixture.editor.selectedStyle, "lake")
            XCTAssertEqual(fixture.editor.selectedWidget, "omniwm")
            XCTAssertEqual(try Data(contentsOf: fixture.shell.appendingPathComponent("shell.luau")), bytes)
        }
    }

    func testDiscardCompletesEveryPendingTransitionWithoutSavingTheDraft() async throws {
        let destination = SettingsRoute(section: .general, tab: "discard-destination")
        let transitions: [ShellDesktopEditor.Transition] = [
            .style("nocturne"), .widget("clock"), .useStyle, .leave(destination), .leave(nil)
        ]
        for transition in transitions {
            let fixture = try await fixture()
            let navigation = SettingsNavigationModel()
            navigation.proceed(to: SettingsRoute(section: .styles))
            let closed = Events()
            navigation.closeWindow = { closed.record() }
            fixture.editor.attach(navigation)
            let key = await dirtyText(fixture.editor)
            _ = await fixture.editor.request(transition)
            await fixture.editor.resolve(.discard)
            XCTAssertNil(fixture.editor.pendingTransition)
            XCTAssertNil(fixture.editor.draft(key))
            assertCompletedTransition(
                transition, fixture: fixture, navigation: navigation, closed: closed, destination: destination
            )
            let lake = try await fixture.configuration.previewConfig(profile: "lake")
            XCTAssertNotEqual(
                ShellWidgetSettingsModel.values(widget: "omniwm", config: lake)["iconColor"],
                .string("#123456FF")
            )
            fixture.editor.detach()
        }
    }

    func testSaveCompletesEachTransitionOnlyAfterTheCapturedDraftPersists() async throws {
        let destination = SettingsRoute(section: .general)
        let transitions: [ShellDesktopEditor.Transition] = [
            .style("nocturne"), .widget("clock"), .useStyle, .leave(destination), .leave(nil)
        ]
        for transition in transitions {
            let fixture = try await fixture()
            let navigation = SettingsNavigationModel()
            navigation.proceed(to: SettingsRoute(section: .styles))
            let closed = Events()
            navigation.closeWindow = { closed.record() }
            fixture.editor.attach(navigation)
            let key = await dirtyText(fixture.editor)
            _ = await fixture.editor.request(transition)
            let gate = Gate()
            let writer = ShellIslandConfigWriter(shellDirectory: fixture.shell, reloadReady: {})
            fixture.configuration.writer = writer
            let held = Task { try await writer.perform { _ in gate.block() } }
            await gate.wait()
            let entered = Events()
            let resolution = Task {
                entered.record()
                await fixture.editor.resolve(.save)
            }
            await entered.wait(1)
            XCTAssertNil(fixture.editor.pendingTransition)
            XCTAssertEqual(fixture.editor.selectedStyle, "lake")
            XCTAssertEqual(fixture.editor.selectedWidget, "omniwm")
            XCTAssertEqual(navigation.section, .styles)
            XCTAssertEqual(closed.count, 0)
            gate.finish()
            try await held.value
            await resolution.value
            XCTAssertNil(fixture.editor.pendingTransition)
            XCTAssertNil(fixture.editor.draft(key))
            let lake = try await fixture.configuration.previewConfig(profile: "lake")
            XCTAssertEqual(
                ShellWidgetSettingsModel.values(widget: "omniwm", config: lake)["iconColor"],
                .string("#123456FF")
            )
            assertCompletedTransition(
                transition, fixture: fixture, navigation: navigation, closed: closed, destination: destination
            )
            fixture.editor.detach()
        }
    }

    func testFailedSaveKeepsTheDirtyDraftTargetAndReportsTheProblem() async throws {
        let transitions: [ShellDesktopEditor.Transition] = [
            .style("nocturne"), .widget("clock"), .useStyle,
            .leave(SettingsRoute(section: .general)), .leave(nil)
        ]
        for transition in transitions {
            let fixture = try await fixture()
            let key = await dirtyText(fixture.editor)
            let original = try XCTUnwrap(fixture.editor.draft(key))
            _ = await fixture.editor.request(transition)
            let file = fixture.shell.appendingPathComponent("shell.luau")
            let saved = try Data(contentsOf: file)
            try Data("[invalid".utf8).write(to: file)
            await fixture.editor.resolve(.save)
            XCTAssertNil(fixture.editor.pendingTransition)
            XCTAssertNotNil(fixture.editor.problem)
            XCTAssertEqual(fixture.editor.selectedStyle, "lake")
            XCTAssertEqual(fixture.editor.selectedWidget, "omniwm")
            let retained = try XCTUnwrap(fixture.editor.draft(key))
            XCTAssertEqual(retained.id, original.id)
            XCTAssertEqual(retained.profile, "lake")
            XCTAssertEqual(retained.value, original.value)
            XCTAssertTrue(retained.dirty)
            XCTAssertFalse(retained.saving)
            XCTAssertNotNil(retained.error)
            try saved.write(to: file)
        }
    }

    func testWorldClockSaveUsesItsCapturedStyleAfterSelectionChanges() async throws {
        let fixture = try await fixture()
        fixture.editor.beginClocksDraft()
        let key = ShellEditorDraft.Key(widget: "world-clock", option: "zones")
        let value = [ShellWorldClockEntry(label: "Toronto", zone: "America/Toronto")]
        fixture.editor.updateDraft(key, .clocks(value))
        let captured = try XCTUnwrap(fixture.editor.draft(key))
        _ = await fixture.editor.selectStyle("nocturne")
        await fixture.editor.resolve(.discard)
        fixture.editor.setDraft(captured)
        let saved = await fixture.editor.saveDraft(key)
        XCTAssertTrue(saved)
        let lake = try await fixture.configuration.previewConfig(profile: "lake")
        let nocturne = try await fixture.configuration.previewConfig(profile: "nocturne")
        XCTAssertEqual(ShellWidgetSettingsModel.clocks(config: lake).map(\.label), ["Toronto"])
        XCTAssertNotEqual(ShellWidgetSettingsModel.clocks(config: nocturne).map(\.label), ["Toronto"])
        XCTAssertEqual(fixture.editor.selectedStyle, "nocturne")
        XCTAssertEqual(fixture.configuration.config.profile, "default")
    }

    func testOverlongTextIsRejectedWithoutSavingOrDiscardingTheDraft() async throws {
        let fixture = try await fixture()
        let key = await dirtyText(fixture.editor, value: "1234567890")
        XCTAssertEqual(fixture.editor.schema(for: "omniwm")?.options["iconColor"]?.maxLength, 9)
        let original = try Data(contentsOf: fixture.shell.appendingPathComponent("shell.luau"))
        let saved = await fixture.editor.saveDraft(key)
        XCTAssertFalse(saved)
        XCTAssertTrue(fixture.editor.draft(key)?.dirty == true)
        XCTAssertNotNil(fixture.editor.draft(key)?.error)
        XCTAssertEqual(try Data(contentsOf: fixture.shell.appendingPathComponent("shell.luau")), original)
    }

    func testWeatherReadsAndWritesOnlyTheSharedRootTable() async throws {
        let fixture = try await fixture()
        await fixture.editor.beginWeatherDraft()
        guard case var .weather(weather)? = fixture.editor.draft(.weather)?.value else {
            return XCTFail("Missing Weather draft")
        }
        XCTAssertEqual(weather.city, "Toronto")
        let before = try document(fixture)
        weather.city = "London"
        weather.fahrenheit = true
        fixture.editor.updateDraft(.weather, .weather(weather))
        let saved = await fixture.editor.saveDraft(.weather)
        XCTAssertTrue(saved)
        let current = try document(fixture)
        XCTAssertEqual(current["profiles"], before["profiles"])
        guard case let .record(root)? = current["weather"] else { return XCTFail("Missing shared Weather") }
        XCTAssertEqual(root["city"], .string("London"))
        XCTAssertEqual(root["units"], .string("fahrenheit"))
        XCTAssertEqual(fixture.configuration.config.profile, "default")
    }

    func testReloadKeepsDirtyDraftAndRefreshesCleanDraft() async throws {
        let fixture = try await fixture()
        let key = await dirtyText(fixture.editor)
        let dirty = try XCTUnwrap(fixture.editor.draft(key))
        try await fixture.configuration.setWidgetValue(
            .string("#ABCDEF00"),
            widget: "omniwm",
            key: "iconColor",
            profile: "lake"
        )
        await fixture.editor.reload()
        XCTAssertEqual(fixture.editor.draft(key), dirty)
        fixture.editor.cancelDraft(key)
        fixture.editor.beginTextDraft(widget: "omniwm", key: "iconColor")
        XCTAssertEqual(fixture.editor.draft(key)?.value, .text("#ABCDEF00"))
        let oldID = fixture.editor.draft(key)?.id
        try await fixture.configuration.setWidgetValue(
            .string("#123400FF"),
            widget: "omniwm",
            key: "iconColor",
            profile: "lake"
        )
        await fixture.editor.reload()
        XCTAssertEqual(fixture.editor.draft(key)?.value, .text("#123400FF"))
        XCTAssertFalse(fixture.editor.draft(key)?.dirty == true)
        XCTAssertEqual(fixture.editor.draft(key)?.id, oldID)
    }

    func testDraftSaveRetainsItsValueAndTargetWhenContinuousWritesHaveFailed() async throws {
        let fixture = try await fixture()
        let key = await dirtyText(fixture.editor)
        let draft = try XCTUnwrap(fixture.editor.draft(key))
        let held = HeldWrite()
        let target = fixture.editor.barTarget("height")
        fixture.editor.writes.submit(51, for: target, write: held.write)
        await held.entered.wait(1)
        held.finish(failing: true)
        let drained = await fixture.editor.writes.drain()
        XCTAssertFalse(drained)
        let file = fixture.shell.appendingPathComponent("shell.luau")
        let original = try Data(contentsOf: file)
        let saved = await fixture.editor.saveDraft(key)
        XCTAssertFalse(saved)
        let retained = fixture.editor.draft(key)
        XCTAssertEqual(retained?.id, draft.id)
        XCTAssertEqual(retained?.profile, "lake")
        XCTAssertEqual(retained?.value, draft.value)
        XCTAssertNotNil(retained?.error)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertNotNil(fixture.editor.writes.failure(for: target))
    }

    private func assertCompletedTransition(
        _ transition: ShellDesktopEditor.Transition, fixture: Fixture, navigation: SettingsNavigationModel,
        closed: Events, destination: SettingsRoute
    ) {
        switch transition {
        case .style: XCTAssertEqual(fixture.editor.selectedStyle, "nocturne")
        case .widget: XCTAssertEqual(fixture.editor.selectedWidget, "clock")
        case .useStyle: XCTAssertEqual(fixture.editor.scope, .active)
        case .leave(.some): XCTAssertEqual(navigation.route, destination)
        case .leave(nil): XCTAssertEqual(closed.count, 1)
        case .surface,
             .component,
             .drawer,
             .destination: XCTFail("Unexpected selection transition")
        }
    }
}
