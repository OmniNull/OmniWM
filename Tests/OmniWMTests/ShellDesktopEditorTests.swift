// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellDesktopEditorTests: XCTestCase {
    func testPreviewedStyleWritesOnlyTheSelectedProfile() async throws {
        let fixture = try await fixture()
        let before = try document(fixture)
        let active = fixture.configuration.config
        fixture.editor.set(58, key: "height")
        await fixture.saves.wait(1)
        fixture.editor.setWidget(.bool(false), widget: "clock", key: "date")
        await fixture.saves.wait(2)
        fixture.editor.selectScheme(.vibrant)
        await fixture.saves.wait(3)
        let selected = try await fixture.configuration.previewConfig(profile: "lake")
        XCTAssertEqual(selected.barOverride?.settings.height, 58)
        XCTAssertEqual(ShellWidgetSettingsModel.values(widget: "clock", config: selected)["date"], .bool(false))
        XCTAssertEqual(selected.wallpaperScheme, .vibrant)
        XCTAssertEqual(outsideLake(try document(fixture)), outsideLake(before))
        XCTAssertEqual(fixture.configuration.config, active)
        XCTAssertEqual(fixture.editor.scope, .previewing(active: "default"))
        XCTAssertNil(fixture.editor.status(for: "clock"))
    }

    func testBarResetDrainsContinuousValuesBeforeRemovingTheOverride() async throws {
        let fixture = try await fixture()
        let gate = Gate()
        let writer = ShellIslandConfigWriter(shellDirectory: fixture.shell, reloadReady: {})
        fixture.configuration.writer = writer
        let held = Task { try await writer.perform { _ in gate.block() } }
        await gate.wait()
        defer { gate.finish() }
        fixture.editor.set(51, key: "height", continuous: true)
        await waitForSaving(fixture.configuration)
        fixture.editor.set(62, key: "height", continuous: true)
        fixture.editor.reset()
        XCTAssertEqual(fixture.editor.pending(fixture.editor.barTarget("height"), as: Int?.self) ?? nil, 62)
        XCTAssertEqual(fixture.saves.count, 0)
        gate.finish()
        try await held.value
        await fixture.saves.wait(3)
        let drained = await fixture.editor.writes.drain()
        XCTAssertTrue(drained)
        let current = try document(fixture)
        guard case let .record(profiles)? = current["profiles"],
              case let .record(lake)? = profiles["lake"] else { return XCTFail("Missing Lake profile") }
        XCTAssertNil(lake["workspaceBar"])
        XCTAssertEqual(fixture.configuration.config.profile, "default")
    }

    func testDisplayResetDrainsBothContinuousValuesBeforeRemovingTheOverride() async throws {
        let fixture = try await fixture()
        let gate = Gate()
        let writer = ShellIslandConfigWriter(shellDirectory: fixture.shell, reloadReady: {})
        fixture.configuration.writer = writer
        let held = Task { try await writer.perform { _ in gate.block() } }
        await gate.wait()
        defer { gate.finish() }
        let monitor = display()
        fixture.editor.setDisplay(monitor, key: "height", value: 51, continuous: true) { $0.height = $1 }
        await waitForSaving(fixture.configuration)
        fixture.editor.setDisplay(monitor, key: "height", value: 62, continuous: true) { $0.height = $1 }
        fixture.editor.resetDisplay(monitor)
        XCTAssertEqual(fixture.saves.count, 0)
        gate.finish()
        try await held.value
        await fixture.saves.wait(3)
        let drained = await fixture.editor.writes.drain()
        XCTAssertTrue(drained)
        let config = try await fixture.configuration.previewConfig(profile: "lake")
        XCTAssertTrue(config.barOverride?.monitorOverrides.isEmpty == true)
        XCTAssertEqual(fixture.configuration.config.profile, "default")
    }

    func testUseStyleWaitsForThePendingWriteThenBecomesActive() async throws {
        let fixture = try await fixture()
        let held = HeldWrite()
        fixture.editor.writes.submit(51, for: fixture.editor.barTarget("height"), write: held.write)
        await held.entered.wait(1)
        let entered = Events()
        var completed = false
        let use = Task {
            entered.record()
            let result = await fixture.editor.useStyle()
            completed = true
            return result
        }
        await entered.wait(1)
        XCTAssertFalse(completed)
        XCTAssertEqual(fixture.configuration.config.profile, "default")
        held.finish()
        let changed = await use.value
        XCTAssertTrue(changed)
        XCTAssertEqual(fixture.configuration.config.profile, "lake")
        XCTAssertEqual(fixture.editor.scope, .active)
    }

    func testFailureDuringUseStyleDrainBlocksActivationAndRetainsTheFailure() async throws {
        let fixture = try await fixture()
        let held = HeldWrite()
        let target = fixture.editor.barTarget("height")
        fixture.editor.writes.submit(51, for: target, write: held.write)
        await held.entered.wait(1)
        let entered = Events()
        let use = Task {
            entered.record()
            return await fixture.editor.useStyle()
        }
        await entered.wait(1)
        held.finish(failing: true)
        let changed = await use.value
        XCTAssertFalse(changed)
        XCTAssertEqual(fixture.configuration.config.profile, "default")
        XCTAssertNotNil(fixture.editor.writes.failure(for: target))
        XCTAssertNotNil(fixture.editor.problem)
        XCTAssertTrue(fixture.editor.hasUnsavedChanges)
    }

    func testAlreadyFailedWriteBlocksUseStyleAndSetsTheProblem() async throws {
        let fixture = try await fixture()
        let held = HeldWrite()
        let target = fixture.editor.barTarget("height")
        fixture.editor.writes.submit(51, for: target, write: held.write)
        await held.entered.wait(1)
        held.finish(failing: true)
        let drained = await fixture.editor.writes.drain()
        XCTAssertFalse(drained)
        let changed = await fixture.editor.useStyle()
        XCTAssertFalse(changed)
        XCTAssertEqual(fixture.editor.pendingTransition, .useStyle)
        XCTAssertEqual(fixture.configuration.config.profile, "default")
        XCTAssertNotNil(fixture.editor.writes.failure(for: target))
        XCTAssertNotNil(fixture.editor.problem)
    }

    func testResetRefusesAFailedContinuousValueUntilItIsDiscarded() async throws {
        let fixture = try await fixture()
        let file = fixture.shell.appendingPathComponent("shell.luau")
        let original = try Data(contentsOf: file)
        try Data("[invalid".utf8).write(to: file)
        fixture.editor.set(51, key: "height", continuous: true)
        let drained = await fixture.editor.writes.drain()
        XCTAssertFalse(drained)
        try original.write(to: file)
        let target = fixture.editor.barTarget("height")
        XCTAssertNotNil(fixture.editor.writes.failure(for: target))
        let outcome = Events()
        fixture.configuration.onSave = { _ in outcome.record() }
        observeProblem(fixture.editor, changed: outcome)
        fixture.editor.reset()
        await outcome.wait(1)
        XCTAssertNotNil(fixture.editor.problem)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertNotNil(fixture.editor.writes.failure(for: target))
        fixture.editor.writes.discard(target)
        let nextSave = outcome.count + 1
        fixture.editor.reset()
        await outcome.wait(nextSave)
        let current = try document(fixture)
        guard case let .record(profiles)? = current["profiles"],
              case let .record(lake)? = profiles["lake"] else { return XCTFail("Missing Lake profile") }
        XCTAssertNil(lake["workspaceBar"])
        XCTAssertTrue(fixture.editor.writes.failures.isEmpty)
    }
}
