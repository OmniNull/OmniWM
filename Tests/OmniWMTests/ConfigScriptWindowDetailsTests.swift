// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptWindowDetailsTests: XCTestCase {
    private let displays: [Monitor] = {
        let primary = NiriGatherFixture.monitor(displayId: 1)
        let secondary = NiriGatherFixture.monitor(displayId: primary.displayId + 1, x: primary.frame.maxX)
        return [primary, secondary]
    }()

    private struct WindowRow {
        let token: WindowToken
        let id: String
        let workspace: String
        let display: Monitor
        let bundle: String

        var emptyTitleBytes: Int {
            let fields = [id, bundle, "", workspace, display.id.scriptIdentifier]
            return fields.reduce(MemoryLayout<UInt8>.size) { $0 + MemoryLayout<UInt32>.size + $1.utf8.count }
        }

        var expectation: String {
            let frame = display.visibleFrame
            return "{ id = '\(id)', pid = \(token.pid), number = \(token.windowId), " +
                "x = \(frame.minX), y = \(frame.minY), w = \(frame.width), h = \(frame.height) }"
        }
    }

    func testDetailsCannotSpendSharedBaseBytesOrTakeFramesAndColumnsWithThem() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: displays)
        let base = fixture.base
        let controller = base.controller
        let manager = base.manager
        let rows = displays.enumerated().map { offset, display in
            let id = offset + 1
            return WindowRow(
                token: base.token(id), id: fixture.id(id), workspace: String(id), display: display,
                bundle: "details.\(id)"
            )
        }
        for row in rows {
            let workspace = base.workspace(row.workspace)
            XCTAssertEqual(manager.addWindow(
                WindowAdmissionTestSupport.axRef(for: row.token), pid: row.token.pid, windowId: row.token.windowId,
                to: workspace,
                managedReplacementMetadata: .init(
                    bundleId: row.bundle, workspaceId: workspace, mode: .tiling, title: ""
                )
            ), row.token)
            manager.withEngineMutationScope {
                _ = base.engine.addWindow(token: row.token, to: workspace, afterSelection: nil)
            }
        }
        let first = try XCTUnwrap(rows.first)
        let last = try XCTUnwrap(rows.last)
        try await fixture.focus(rows.startIndex + 1, on: first.workspace)
        for row in rows {
            controller.axManager.confirmFrameWrite(for: row.token.windowId, frame: row.display.visibleFrame)
        }
        let headerSize = MemoryLayout<UInt64>.size
        let emptyBytes = rows.reduce(headerSize) { $0 + $1.emptyTitleBytes }
        let fittingTitle = String(repeating: "x", count: ConfigScriptSnapshot.byteLimit - emptyBytes)
        let longApp = String(repeating: "A", count: ConfigScriptSnapshot.detailByteLimit / rows.count)
        let expected = rows.map(\.expectation).joined(separator: ", ")
        let scenarios = [
            (title: fittingTitle, app: "short", baseCut: false, detailCut: false),
            (title: fittingTitle + "x", app: "short", baseCut: true, detailCut: false),
            (title: fittingTitle, app: longApp, baseCut: false, detailCut: true)
        ]
        var pool = ConfigScriptSnapshotPool()
        for scenario in scenarios {
            for row in rows {
                controller.appInfoCache.evict(pid: row.token.pid)
                _ = controller.appInfoCache.info(for: row.token.pid) { _ in
                    .init(name: scenario.app, bundleId: row.bundle, icon: nil, activationPolicy: .regular)
                }
            }
            XCTAssertTrue(manager.updateManagedReplacementTitle(scenario.title, for: last.token))
            let source = mixedListeners(
                expected: expected, appBytes: scenario.app.utf8.count, titleBytes: scenario.title.utf8.count,
                baseCut: scenario.baseCut, detailCut: scenario.detailCut
            )
            let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
            let generation = try XCTUnwrap(result.generation)
            let reads = result.events.reduce(into: ConfigScriptReads()) { $0.formUnion($1.reads) }
            XCTAssertEqual(reads, [
                .workspaceWindows, .windows, .workspaceWindowDetails, .windowDetails,
                .workspaceWindowFrames, .windowFrames, .workspaceWindowColumns, .windowColumns
            ])
            let snapshot = controller.configScriptSnapshot(
                reads: reads, target: controller.configScriptTarget(), pool: &pool
            )
            for listener in result.events {
                _ = try await generation.invoke(
                    function: listener.function, event: ConfigScriptEventPayload(name: "observed"), snapshot: snapshot
                )
            }
        }
    }

    func testColumnDetailsFollowProjectedMembership() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [displays[0]])
        let base = fixture.base
        let manager = base.manager
        let workspace = base.workspace("1")
        let original = [1, 2, 3]
        let excluded = try XCTUnwrap(original.first)
        let projected = original.dropFirst()
        base.add(original, to: workspace)
        for window in projected {
            base.stack(window, onto: excluded, in: workspace)
        }
        manager.withEngineMutationScope(in: workspace) {
            base.engine.setProjectionExclusions([base.token(excluded)], in: workspace)
        }

        var pool = ConfigScriptSnapshotPool()
        let snapshot = base.controller.configScriptSnapshot(
            reads: [.windows, .windowDetails], target: base.controller.configScriptTarget(), pool: &pool
        )
        let expected = projected.enumerated().map { "'\(fixture.id($0.element))'" }.joined(separator: ", ")
        let source = """
        omniwm.on('workspace.active', function(ctx)
            local rows = {}
            for _, row in ctx.windows do rows[row.id] = row end
            local excluded = rows['\(fixture.id(excluded))']
            assert(excluded.columnPosition == nil and excluded.columnSize == nil and excluded.columnSpan == nil)
            local projected = { \(expected) }
            for position, id in projected do
                local row = rows[id]
                assert(row.columnPosition == position and row.columnSize == #projected and row.columnSpan > 0)
            end
        end, { reads = { 'windows', 'details' } })
        """
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let generation = try XCTUnwrap(result.generation)
        let listener = try XCTUnwrap(result.events.first)
        _ = try await generation.invoke(
            function: listener.function, event: ConfigScriptEventPayload(name: "observed"), snapshot: snapshot
        )
    }

    func testRecentSafariRecipeDispatchesTheMostRecentlyFocusedSafariWindow() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: displays)
        let base = fixture.base
        let manager = base.manager
        let safari = "com.apple.Safari"
        let targets = [
            (window: 1, workspace: "1", bundle: safari),
            (window: 2, workspace: "2", bundle: safari),
            (window: 3, workspace: "1", bundle: "test.not-safari")
        ]
        for target in targets {
            let workspace = base.workspace(target.workspace)
            base.add([target.window], to: workspace)
            let token = base.token(target.window)
            let metadata = ManagedReplacementMetadata(
                bundleId: target.bundle, workspaceId: workspace, mode: .tiling
            )
            manager.setManagedReplacementMetadata(metadata, for: token)
            try await fixture.focus(target.window, on: target.workspace)
        }
        let recipe = try ConfigScriptWindowFixture.recipe("Focus the most recently used Safari window.")
        let evaluation = try await ConfigScriptLoader().evaluate(Data(recipe.utf8), hyperMask: 0)
        let command = try XCTUnwrap(evaluation.namedCommands.first)
        let generation = try XCTUnwrap(evaluation.generation)
        let target = base.controller.configScriptTarget()
        var pool = ConfigScriptSnapshotPool()
        let snapshot = base.controller.configScriptSnapshot(reads: command.reads, target: target, pool: &pool)
        let result = try await generation.invoke(function: command.function, target: target, snapshot: snapshot)
        let latestSafari = try XCTUnwrap(targets.last { $0.bundle == safari })
        XCTAssertEqual(result.commands.count, 1)
        if case let .window(window) = try XCTUnwrap(result.commands.first).operation {
            XCTAssertEqual(window.token, base.token(latestSafari.window))
            XCTAssertEqual(window.action, .focus)
        } else {
            XCTFail("Expected a window focus dispatch")
        }
    }

    private func mixedListeners(
        expected: String, appBytes: Int, titleBytes: Int, baseCut: Bool, detailCut: Bool
    ) -> String {
        """
        local expected = { \(expected) }
        local function check(rows, count, details, frames, columns, cut)
            assert(#rows == count)
            for index, row in rows do
                local want = expected[index]
                assert(row.id == want.id and table.isfrozen(row), 'base row ' .. index)
                assert(#row.title == (if index == #expected then \(titleBytes) else 0), 'title ' .. index)
                if details and not (cut and index == #expected) then
                    assert(row.pid == want.pid and row.windowNumber == want.number and #row.app == \(appBytes))
                else
                    assert(row.pid == nil and row.windowNumber == nil and row.app == nil, 'details ' .. index)
                end
                if frames then
                    local frame = assert(row.frame)
                    assert(frame.x == want.x and frame.y == want.y and frame.width == want.w and frame.height == want.h)
                else
                    assert(row.frame == nil, 'frame ' .. index)
                end
                assert(row.column == (if columns then 1 else nil), 'column ' .. index)
            end
        end
        local function checkWindows(e, details, frames, columns)
            assert(e.truncated.windows == \(baseCut) and e.workspaceWindows == nil)
            if details then
                assert(table.isfrozen(e.truncated.details))
                assert(e.truncated.details.windows == \(detailCut) and e.truncated.details.workspaceWindows == nil)
            else
                assert(e.truncated.details == nil)
            end
            check(e.windows, #expected - (if \(baseCut) then 1 else 0), details, frames, columns, \(detailCut))
        end
        omniwm.on('workspace.active', function(e) checkWindows(e, false, false, false) end,
            { reads = { 'windows' } })
        omniwm.on('workspace.active', function(e) checkWindows(e, true, false, false) end,
            { reads = { 'windows', 'details' } })
        omniwm.on('workspace.active', function(e) checkWindows(e, false, true, false) end,
            { reads = { 'windows', 'frames' } })
        omniwm.on('workspace.active', function(e) checkWindows(e, false, false, true) end,
            { reads = { 'windows', 'columns' } })
        omniwm.on('workspace.active', function(e)
            assert(e.truncated.workspaceWindows == false and e.truncated.details.workspaceWindows == false)
            assert(e.truncated.windows == \(baseCut) and e.truncated.details.windows == \(detailCut))
            check(e.workspaceWindows, 1, true, true, true, false)
            check(e.windows, #expected - (if \(baseCut) then 1 else 0), true, true, true, \(detailCut))
        end, { reads = { 'workspaceWindows', 'windows', 'details', 'frames', 'columns' } })
        """
    }

    func testDetailsUseCachedInformationModelVisibilityAndFocusOrder() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: displays, layouts: [.niri, .dwindle])
        let base = fixture.base
        let manager = base.manager
        let controller = base.controller
        let here = base.workspace("1")
        let there = base.workspace("2")
        let tiled = [1, 2]
        let dwindle = 3
        let floating = 4
        let hosted = WindowToken(pid: getpid(), windowId: base.token(5).windowId)
        base.add(tiled, to: here)
        base.stack(tiled[1], onto: tiled[0], in: here)
        base.add([dwindle, floating], to: there)
        let frame = displays[1].visibleFrame
        let hostedTitle = "Hosted app"
        let hostedBundle = "details.hosted"
        let hostedMetadata = HostedWindowMetadata(appId: hostedBundle, title: hostedTitle, minimumSize: frame.size)
        XCTAssertEqual(manager.addHostedWindow(
            token: hosted, metadata: hostedMetadata, to: there, initialFrame: frame
        ), hosted)
        let hostedID = ConfigScriptWindowID.string(hosted, session: controller.scriptSession.identity)
        for id in tiled { try await fixture.focus(id, on: "1") }
        let mru = try XCTUnwrap(tiled.last)
        let older = try XCTUnwrap(tiled.first)
        let recentTitle = "Recently used app"
        controller.appInfoCache.evict(pid: base.token(mru).pid)
        _ = controller.appInfoCache.info(for: base.token(mru).pid) { _ in
            .init(name: recentTitle, bundleId: "details.recent", icon: nil, activationPolicy: .regular)
        }
        controller.appInfoCache.evict(pid: base.token(older).pid)
        XCTAssertTrue(manager.setWindowMode(.floating, for: base.token(floating)))
        manager.setManualLayoutOverride(.forceFloat, for: base.token(floating))
        manager.setAppHidden(true, pid: base.token(dwindle).pid, source: .ax)
        XCTAssertTrue(manager.markNativeFullscreenSuspended(base.token(dwindle), ownsNativeFocus: false))
        let slot = try XCTUnwrap(ScratchpadIndex(ScratchpadIndex.range.lowerBound))
        XCTAssertTrue(manager.setScratchpadMembership(base.token(floating), to: slot))
        manager.setHiddenState(.init(
            proportionalPosition: .zero, referenceMonitorId: displays[1].id, reason: .scratchpad
        ), for: base.token(floating))
        let column = try XCTUnwrap(base.node(older, in: here).flatMap(base.engine.column(of:)))
        let display = displays[0]
        let area = controller.niriInteractionGeometry(for: display, scale: display.backingScale).workingFrame
        let targetSpan = area.width / CGFloat(tiled.count)
        manager.withEngineMutationScope(in: here) { column.targetWidth = targetSpan }
        var pool = ConfigScriptSnapshotPool()
        let reads: ConfigScriptReads = [.windows, .windowDetails]
        let snapshot = controller.configScriptSnapshot(
            reads: reads,
            target: controller.configScriptTarget(),
            pool: &pool
        )
        XCTAssertFalse(controller.appInfoCache.hasCachedInfo(for: base.token(older).pid))
        let rank = tiled.reversed().enumerated().map { "\($0.offset)" }
        let source = [
            "omniwm.on('workspace.active', function(ctx)",
            "local rows = {}",
            "for _, row in ctx.windows do rows[row.id] = row end",
            "local recent, older = rows['\(fixture.id(mru))'], rows['\(fixture.id(older))']",
            "assert(recent.app == '\(recentTitle)' and older.app == nil)",
            "assert(recent.focusRank == \(rank[0]) and older.focusRank == \(rank[1]))",
            "assert(recent.visible == true and older.visible == true)",
            "assert(recent.appHidden == false and recent.scratchpad == false)",
            "assert(recent.scratchpadSlot == nil and recent.hiddenReason == nil and recent.manualOverride == nil)",
            "assert(recent.mode == '\(IPCWindowMode.tiling.rawValue)')",
            "assert(recent.layoutReason == '\(IPCLayoutReason.standard.rawValue)')",
            "assert(older.columnPosition == 1 and recent.columnPosition == \(tiled.count))",
            "assert(older.columnSize == \(tiled.count) and recent.columnSize == older.columnSize)",
            "assert(recent.columnSpan == \(targetSpan / area.width) and older.columnSpan == recent.columnSpan)",
            "local native = rows['\(fixture.id(dwindle))']",
            "assert(native.layoutReason == '\(IPCLayoutReason.nativeFullscreen.rawValue)')",
            "assert(native.appHidden == true and native.visible == false and native.focusRank == nil)",
            "local floating = rows['\(fixture.id(floating))']",
            "assert(floating.mode == '\(IPCWindowMode.floating.rawValue)' and floating.visible == false)",
            "assert(floating.manualOverride == '\(IPCManualWindowOverride.forceFloat.rawValue)')",
            "assert(floating.scratchpad == true and floating.scratchpadSlot == \(slot.rawValue))",
            "assert(floating.hiddenReason == '\(IPCHiddenReason.scratchpad.rawValue)')",
            "local hosted = rows['\(hostedID)']",
            "assert(hosted.app == '\(hostedTitle)' and hosted.bundleId == '\(hostedBundle)')",
            "for _, row in {native, floating, hosted} do",
            "    assert(row.columnSpan == nil and row.columnPosition == nil and row.columnSize == nil)",
            "end",
            "assert(ctx.truncated.details.windows == false)",
            "end, { reads = { 'windows', 'details' } })"
        ].joined(separator: "\n")
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let generation = try XCTUnwrap(result.generation)
        let listener = try XCTUnwrap(result.events.first)
        XCTAssertEqual(listener.reads, reads)
        _ = try await generation.invoke(
            function: listener.function, event: ConfigScriptEventPayload(name: "observed"), snapshot: snapshot
        )
    }
}
