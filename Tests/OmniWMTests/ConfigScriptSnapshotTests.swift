// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptSnapshotTests: XCTestCase {
    private typealias Fixture = ConfigScriptCallbackQueueTests.Fixture

    private func check(_ fixture: Fixture, reads: [String], body: [String]) async throws {
        let options = reads.map(\.debugDescription).joined(separator: ", ")
        let script = ["omniwm.command('Inspect', function(ctx)"] + body + ["end, {reads = {\(options)}})"]
        fixture.apply(try await fixture.load(script))
        let fn = try XCTUnwrap(fixture.script.acceptedCommands.first?.function)
        XCTAssertEqual(fixture.press(.configFunction(fn)), .executed)
        await fixture.script.callbackQueue?.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testNativeMembershipOrderAndOnlyCachedFieldsReachDeclaredLists() async throws {
        let fixture = try Fixture(test: self)
        let manager = fixture.controller.workspaceManager
        let here = try XCTUnwrap(manager.workspaceId(named: fixture.origin))
        let there = try XCTUnwrap(manager.workspaceId(named: fixture.destination))
        let monitor = try XCTUnwrap(manager.monitor(for: here))
        let names = ["first floating", "in another workspace", "no metadata", "empty title"]
        let tokens = names.indices.reversed().map { WindowToken(pid: getpid(), windowId: Int(getpid()) + $0) }
        for (index, token) in tokens.enumerated() {
            let workspace = index == 1 ? there : here
            let mode: TrackedWindowMode = index == 0 ? .floating : .tiling
            _ = manager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token), pid: token.pid, windowId: token.windowId, to: workspace,
                mode: mode, isMinimized: index == 0,
                managedReplacementMetadata: index == 2 ? nil : .init(
                    bundleId: "lookup.fixture", workspaceId: workspace, mode: mode,
                    title: index == 3 ? "" : names[index]
                )
            )
        }
        XCTAssertTrue(manager.markNativeFullscreenSuspended(tokens[1], ownsNativeFocus: false))
        fixture.controller.axEventHandler.windowTitleProvider = { _ in XCTFail("Lookups must use cached titles")
            return nil
        }
        let ids = tokens.map { IPCWindowOpaqueID.encode(
            token: $0,
            sessionToken: fixture.controller.automationSessionToken
        ) }
        try await check(fixture, reads: ["workspaceWindows"], body: [
            "assert(ctx.windows == nil and ctx.workspaces == nil and ctx.monitors == nil)",
            "assert(table.isfrozen(ctx.workspaceWindows) and table.isfrozen(ctx.truncated))",
            "assert(ctx.truncated.workspaceWindows == false and ctx.truncated.windows == nil)",
            "local a, b, c = table.unpack(ctx.workspaceWindows)",
            "assert(#ctx.workspaceWindows == 3 and a.id == '\(ids[0])' and b.id == '\(ids[2])' and c.id == '\(ids[3])')",
            "assert(table.isfrozen(a) and a.floating and a.minimized and not a.fullscreen)",
            "assert(a.title == '\(names[0])' and a.bundleId == 'lookup.fixture' and a.workspace == '\(fixture.origin)')",
            "assert(a.monitor == '\(IPCDisplayRef.identifier(monitor.id))' and b.title == nil and c.title == '')"
        ])
        try await check(fixture, reads: ["windows", "workspaces", "monitors"], body: [
            "assert(ctx.workspaceWindows == nil and ctx.truncated.workspaceWindows == nil)",
            "assert(#ctx.windows == \(names.count) and ctx.windows[#ctx.windows].id == '\(ids[1])')",
            "assert(ctx.windows[#ctx.windows].fullscreen and ctx.windows[#ctx.windows].workspace == '\(fixture.destination)')",
            "local workspaces = {}",
            "for _, w in ctx.workspaces do workspaces[w.name] = w end",
            "assert(workspaces['\(fixture.origin)'].id == '\(here.uuidString)')",
            "assert(workspaces['\(fixture.destination)'].id == '\(there.uuidString)')",
            "assert(ctx.monitors[1].id == '\(IPCDisplayRef.identifier(monitor.id))' and ctx.monitors[1].name ~= nil)"
        ])
    }

    func testRowLimitPreservesThePrefixAndLeavesOtherListsAvailable() async throws {
        let fixture = try Fixture(test: self)
        let here = try XCTUnwrap(fixture.controller.activeWorkspace()?.id)
        let manager = fixture.controller.workspaceManager
        let count = ConfigScriptSnapshot.rowLimit
        let tokens = (0 ... count).map { WindowToken(pid: getpid(), windowId: Int(getpid()) + $0) }
        for token in tokens { _ = WindowAdmissionTestSupport.track(token, in: here, controller: fixture.controller) }
        let last = IPCWindowOpaqueID.encode(
            token: tokens[count - 1],
            sessionToken: fixture.controller.automationSessionToken
        )
        try await check(fixture, reads: ["workspaceWindows", "windows", "monitors"], body: [
            "assert(#ctx.workspaceWindows == \(count) and #ctx.windows == \(count))",
            "assert(ctx.workspaceWindows[\(count)].id == '\(last)' and ctx.windows[\(count)].id == '\(last)')",
            "assert(ctx.truncated.workspaceWindows and ctx.truncated.windows and not ctx.truncated.monitors)",
            "assert(#ctx.monitors == \(manager.monitors.count))"
        ])
    }

    func testOversizedCachedTitlePublishesOnlyCompleteRowsAndMarksTruncation() async throws {
        let fixture = try Fixture(test: self)
        let workspace = try XCTUnwrap(fixture.controller.activeWorkspace()?.id)
        let titles = ["kept", String(repeating: "X", count: ConfigScriptSnapshot.byteLimit), "after"]
        for (index, title) in titles.enumerated() {
            let token = WindowToken(pid: getpid(), windowId: Int(getpid()) + index)
            _ = fixture.controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token), pid: token.pid, windowId: token.windowId, to: workspace,
                managedReplacementMetadata: .init(workspaceId: workspace, mode: .tiling, title: title)
            )
        }
        try await check(fixture, reads: ["windows", "workspaces"], body: [
            "assert(#ctx.windows == 1 and ctx.windows[1].title == 'kept' and ctx.truncated.windows)",
            "assert(#ctx.workspaces > 0 and not ctx.truncated.workspaces)"
        ])
    }
}
