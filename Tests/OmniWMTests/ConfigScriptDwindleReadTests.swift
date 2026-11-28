// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptDwindleReadTests: XCTestCase {
    private let display = NiriGatherFixture.monitor(displayId: 1)

    private func dwindle(_ fixture: ConfigScriptWindowFixture) throws -> DwindleLayoutEngine {
        try XCTUnwrap(fixture.base.controller.dwindleEngine)
    }

    private func mutate(_ fixture: ConfigScriptWindowFixture, _ body: (DwindleLayoutEngine) -> Void) throws {
        let engine = try dwindle(fixture)
        fixture.base.manager.withEngineMutationScope(in: fixture.base.workspace("1")) { body(engine) }
    }

    private func admission(_ fixture: ConfigScriptWindowFixture, _ token: WindowToken) -> UInt64? {
        fixture.base.manager.windowQueries.tiledAdmission(of: token, in: fixture.base.workspace("1"))
    }

    private func revision(
        _ fixture: ConfigScriptWindowFixture, admission: ((WindowToken) -> UInt64?)? = nil
    ) throws -> UInt64? {
        var hasher = Hasher()
        hasher.combine(fixture.base.controller.scriptSession.identity.id)
        let read = try dwindle(fixture).readTree(
            in: fixture.base.workspace("1"), hasher: hasher,
            admission: admission ?? { self.admission(fixture, $0) },
            split: { _, _ in true }, leaf: { _, _ in true }
        )
        guard case let .read(_, revision) = read else { return nil }
        return revision
    }

    private func expectedNodes(_ fixture: ConfigScriptWindowFixture) throws -> String {
        var snapshot: DwindleLayoutSnapshot?
        try mutate(fixture) { snapshot = $0.layoutSnapshot(in: fixture.base.workspace("1")) }
        let captured = try XCTUnwrap(snapshot)
        let session = fixture.base.controller.scriptSession.identity
        return captured.nodes.map { node in
            if let orientation = node.orientation {
                return "{ kind = 'split', orientation = '\(orientation == .vertical ? "vertical" : "horizontal")', " +
                    "ratio = \(node.ratio) }"
            }
            let members = captured.members[node.members]
            let ids = members.map { "'\(ConfigScriptWindowID.string($0.token, session: session))'" }
            let active = (members.firstIndex { $0.token == node.active } ?? members.startIndex) - members.startIndex
            return "{ kind = 'leaf', members = { \(ids.joined(separator: ", ")) }, active = \(active + 1) }"
        }.joined(separator: ", ")
    }

    private static let compare = """
    local function same(a, b)
        if type(a) ~= 'table' or type(b) ~= 'table' then return a == b end
        for key, value in a do if not same(value, b[key]) then return false end end
        for key in b do if a[key] == nil then return false end end
        return true
    end
    """

    func testTheTreeReadsInPreorderWithTabsRatiosAndThePreselect() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [display], layouts: [.dwindle])
        let base = fixture.base
        let workspace = base.workspace("1")
        base.add([1, 2, 3, 4], to: workspace)
        try mutate(fixture) { engine in
            XCTAssertTrue(engine.groupWindow(base.token(4), into: base.token(3), in: workspace))
            let tile = engine.existingState(for: workspace)?.leafByToken[base.token(3)]?.tile
            let last = tile?.members.last?.token
            XCTAssertNotEqual(last, tile?.members.first?.token)
            _ = last.map { engine.activateWindow($0, in: workspace) }
            XCTAssertTrue(engine.toggleOrientation(in: workspace))
            XCTAssertTrue(engine.setPreselection(.right, in: workspace))
        }
        XCTAssertTrue(base.manager.setWindowMinimized(true, token: base.token(2)))
        try await fixture.focus(1, on: "1")
        let expected = try expectedNodes(fixture)
        let state = try XCTUnwrap(try dwindle(fixture).existingState(for: workspace))
        XCTAssertTrue(state.leafByToken[base.token(2)] != nil)
        let revision = try XCTUnwrap(try revision(fixture))
        try await fixture.load("""
        \(Self.compare)
        omniwm.command('Tree', function(ctx)
            local tree = assert(ctx.dwindle)
            assert(table.isfrozen(tree) and table.isfrozen(tree.nodes) and ctx.truncated.dwindle == false)
            assert(tree.workspaceId == '\(workspace.uuidString)' and tree.preselect == 'right')
            assert(tree.revision == '\(String(format: "%016llX", revision))')
            assert(same(tree.nodes, { \(expected) }))
            for _, node in tree.nodes do assert(table.isfrozen(node)) end
        end, { reads = { 'dwindle' } })
        omniwm.command('Without', function(ctx)
            assert(ctx.dwindle == nil and ctx.truncated == nil)
        end)
        """)
        for name in ["Tree", "Without"] {
            try await fixture.run(named: name)
        }
    }

    func testTheRevisionFollowsTheTreeAndOnlyTheTree() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [display], layouts: [.dwindle])
        let base = fixture.base
        let workspace = base.workspace("1")
        base.add([1, 2, 3], to: workspace)
        try mutate(fixture) { XCTAssertTrue($0.groupWindow(base.token(3), into: base.token(2), in: workspace)) }
        try await fixture.focus(1, on: "1")
        let original = try XCTUnwrap(try revision(fixture))
        XCTAssertEqual(try revision(fixture), original)
        _ = base.manager.updateManagedReplacementTitle("Renamed", for: base.token(1))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(base.controller)
        XCTAssertEqual(try revision(fixture), original)

        let tile = try XCTUnwrap(try dwindle(fixture).existingState(for: workspace)?.leafByToken[base.token(2)]?.tile)
        let shown = tile.activeToken
        let other = try XCTUnwrap(tile.members.first { $0.token != shown }?.token)
        let changes: [(String, (DwindleLayoutEngine) -> Bool, (DwindleLayoutEngine) -> Bool)] = [
            ("orientation", { $0.toggleOrientation(in: workspace) }, { $0.toggleOrientation(in: workspace) }),
            ("preselect", { $0.setPreselection(.down, in: workspace) }, { $0.setPreselection(nil, in: workspace) }),
            ("tab", { $0.activateWindow(other, in: workspace) }, { $0.activateWindow(shown, in: workspace) })
        ]
        for (label, change, revert) in changes {
            try mutate(fixture) { XCTAssertTrue(change($0), label) }
            let changed = try XCTUnwrap(try revision(fixture))
            XCTAssertNotEqual(changed, original, label)
            try mutate(fixture) { XCTAssertTrue(revert($0), label) }
            XCTAssertEqual(try revision(fixture), original, label)
        }

        let state = try XCTUnwrap(try dwindle(fixture).existingState(for: workspace))
        let split = try XCTUnwrap(state.leafByToken[base.token(1)]?.parent)
        guard case let .split(orientation, ratio) = split.kind else { return XCTFail("window 1 sits in a split") }
        try mutate(fixture) { _ in split.kind = .split(orientation: orientation, ratio: ratio / 2) }
        XCTAssertNotEqual(try revision(fixture), original)
        try mutate(fixture) { _ in split.kind = .split(orientation: orientation, ratio: ratio) }
        XCTAssertEqual(try revision(fixture), original)

        let token = base.token(1)
        let first = admission(fixture, token)
        XCTAssertNotNil(base.manager.removeWindow(pid: token.pid, windowId: token.windowId))
        try mutate(fixture) { $0.removeWindow(token: token, from: workspace) }
        XCTAssertNotEqual(try revision(fixture), original)
        base.add([1], to: workspace)
        let second = admission(fixture, token)
        XCTAssertNotEqual(second, first)
        let readmitted = try XCTUnwrap(try revision(fixture))
        let asFirst = try XCTUnwrap(try revision(fixture) { $0 == token ? first : self.admission(fixture, $0) })
        XCTAssertNotEqual(readmitted, asFirst)
    }

    func testOtherLayoutsEmptyWorkspacesAndUnsyncedWindows() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [display], layouts: [.dwindle])
        let base = fixture.base
        let workspace = base.workspace("1")
        let reads = "{ reads = { 'dwindle' } }"
        try await fixture.load("""
        omniwm.command('Empty', function(ctx)
            local tree = assert(ctx.dwindle)
            assert(#tree.nodes == 0 and tree.preselect == nil and tree.workspaceId == '\(workspace.uuidString)')
            assert(#tree.revision == 16 and ctx.truncated.dwindle == false)
        end, \(reads))
        omniwm.command('Absent', function(ctx)
            assert(ctx.dwindle == nil and ctx.truncated.dwindle == false)
        end, \(reads))
        omniwm.command('Present', function(ctx)
            assert(#assert(ctx.dwindle).nodes > 0 and ctx.truncated.dwindle == false)
        end, \(reads))
        """)
        let engine = try dwindle(fixture)
        let before = engine.existingState(for: workspace)
        try await fixture.run(named: "Empty")
        XCTAssertTrue(engine.existingState(for: workspace) === before)
        try mutate(fixture) { $0.removeLayout(for: workspace) }
        XCTAssertNil(engine.existingState(for: workspace))
        try await fixture.run(named: "Empty")
        XCTAssertNil(engine.existingState(for: workspace))
        _ = WindowAdmissionTestSupport.track(base.token(1), in: workspace, controller: base.controller)
        XCTAssertEqual(engine.existingState(for: workspace)?.tileCount ?? 0, 0)
        try await fixture.run(named: "Absent")
        try mutate(fixture) { _ = $0.syncWindows([base.token(1)], in: workspace, focusedToken: nil) }
        try await fixture.focus(1, on: "1")
        try await fixture.run(named: "Present")

        let niri = try ConfigScriptWindowFixture(monitors: [display])
        niri.base.add([1], to: niri.base.workspace("1"))
        try await niri.focus(1, on: "1")
        try await niri.load("""
        omniwm.command('Absent', function(ctx)
            assert(ctx.dwindle == nil and ctx.truncated.dwindle == false)
        end, \(reads))
        """)
        try await niri.run(named: "Absent")
    }

    func testATreeOutOfStepWithItsWindowsIsAbsentUntilDwindleResyncs() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [display], layouts: [.dwindle])
        let base = fixture.base
        let manager = base.manager
        let workspace = base.workspace("1")
        base.add([1, 2, 3], to: workspace)
        try await fixture.focus(1, on: "1")
        guard case .ready = manager.dwindleTreeAccess(for: workspace) else { return XCTFail("A synced tree reads") }
        let closed = base.token(2)
        XCTAssertNotNil(manager.removeWindow(pid: closed.pid, windowId: closed.windowId))
        guard case .unavailable = manager.dwindleTreeAccess(for: workspace) else {
            return XCTFail("A closed window still in the tree is out of step")
        }
        _ = WindowAdmissionTestSupport.track(base.token(4), in: workspace, controller: base.controller)
        let engine = try dwindle(fixture)
        XCTAssertEqual(
            engine.windowCount(in: workspace),
            manager.windowQueries.tokens(in: workspace, mode: .tiling).count
        )
        try await fixture.load("""
        omniwm.command('Absent', function(ctx)
            assert(ctx.dwindle == nil and ctx.truncated.dwindle == false)
        end, { reads = { 'dwindle' } })
        omniwm.command('Present', function(ctx)
            assert(#assert(ctx.dwindle).nodes == 5 and ctx.truncated.dwindle == false)
        end, { reads = { 'dwindle' } })
        """)
        try await fixture.run(named: "Absent")
        let router = IPCQueryRouter(controller: base.controller, appVersion: nil, sessionToken: "out-of-step")
        func query() -> IPCDwindleTreeQueryResult? {
            guard case let .dwindleTree(payload) = IPCResult(
                query: IPCQueryRequest(name: .dwindleTree), queryRouter: router
            ).payload else { return nil }
            return payload
        }
        let stale = try XCTUnwrap(query())
        XCTAssertNil(stale.tree)
        XCTAssertFalse(stale.tooLarge)
        let tiled = manager.windowQueries.tokens(in: workspace, mode: .tiling)
        try mutate(fixture) { _ = $0.syncWindows(tiled, in: workspace, focusedToken: nil) }
        XCTAssertNil(engine.existingState(for: workspace)?.leafByToken[closed])
        try await fixture.run(named: "Present")
        XCTAssertNotNil(try XCTUnwrap(query()).tree)
    }

    func testAWindowCloseCallbackNeverReadsTheClosedWindow() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [display], layouts: [.dwindle])
        let base = fixture.base
        let workspace = base.workspace("1")
        base.add([1, 2, 3], to: workspace)
        try await fixture.focus(1, on: "1")
        try await fixture.load("""
        local seen = 0
        omniwm.on('window.close', function(e)
            assert(e.id == '\(fixture.id(2))')
            if e.dwindle then
                for _, node in e.dwindle.nodes do
                    if node.kind == 'leaf' then
                        for _, id in node.members do assert(id ~= e.id) end
                    end
                end
            else
                assert(e.truncated.dwindle == false)
            end
            seen += 1
        end, { reads = { 'dwindle' } })
        omniwm.command('Seen', function() assert(seen == 1) end)
        """)
        let closed = base.token(2)
        XCTAssertNotNil(base.manager.removeWindow(pid: closed.pid, windowId: closed.windowId))
        await fixture.script.callbackQueue?.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
        try await fixture.run(named: "Seen")
    }

    func testATreeOverTheRowLimitIsNilAndMarkedTruncated() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [display], layouts: [.dwindle])
        let base = fixture.base
        let limit = DwindleLayoutEngine.treeMemberLimit
        base.add(Array(1 ... limit), to: base.workspace("1"))
        try await fixture.focus(1, on: "1")
        try await fixture.load("""
        omniwm.command('Full', function(ctx)
            local members = 0
            for _, node in assert(ctx.dwindle).nodes do
                if node.kind == 'leaf' then members += #node.members end
            end
            assert(members == \(limit) and ctx.truncated.dwindle == false)
        end, { reads = { 'dwindle' } })
        omniwm.command('Over', function(ctx)
            assert(ctx.dwindle == nil and ctx.truncated.dwindle == true)
        end, { reads = { 'dwindle' } })
        """)
        try await fixture.run(named: "Full")
        base.add([limit + 1], to: base.workspace("1"))
        try await fixture.run(named: "Over")
    }

    func testListenersSharingACaptureWithFramesAndTheTreeDecodeTheirOwnReads() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [display], layouts: [.dwindle])
        let base = fixture.base
        base.add([1, 2, 3], to: base.workspace("1"))
        try await fixture.focus(1, on: "1")
        let source = """
        omniwm.on('workspace.active', function(e)
            assert(e.dwindle == nil and #e.workspaceWindows == 3 and e.truncated.dwindle == nil)
        end, { reads = { 'workspaceWindows', 'frames' } })
        omniwm.on('workspace.active', function(e)
            assert(e.workspaceWindows == nil and #assert(e.dwindle).nodes == 5)
        end, { reads = { 'dwindle' } })
        omniwm.on('workspace.active', function(e)
            assert(#e.workspaceWindows == 3 and #assert(e.dwindle).nodes == 5 and e.truncated.dwindle == false)
        end, { reads = { 'dwindle', 'workspaceWindows', 'columns' } })
        omniwm.on('workspace.active', function(e)
            assert(e.dwindle == nil and e.truncated == nil)
        end)
        """
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let generation = try XCTUnwrap(result.generation)
        let union = result.events.reduce(into: ConfigScriptReads()) { $0.formUnion($1.reads) }
        XCTAssertTrue(union.contains(.dwindle))
        let controller = base.controller
        let target = controller.configScriptTarget()
        var pool = ConfigScriptSnapshotPool()
        let shared = controller.configScriptSnapshot(reads: union, target: target, pool: &pool)
        for listener in result.events {
            let own = controller.configScriptSnapshot(reads: listener.reads, target: target, pool: &pool)
            for snapshot in [own, shared] {
                _ = try await generation.invoke(
                    function: listener.function, event: ConfigScriptEventPayload(name: "observed"), snapshot: snapshot
                )
            }
        }
    }
}
