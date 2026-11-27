// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptMarkReadTests: XCTestCase {
    private struct MarkText {
        let name: String
        let appName: String?
        let bundleId: String?
        let title: String?
    }

    private let workspaces = ["1", "2"]

    func testMarksShareTheCLIOrderAndWorkspaceIdentity() async throws {
        let base = try scene()
        let controller = base.controller
        let registry = controller.windowMarkRegistry
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let namesByWorkspace = [[composed], [decomposed, "archive"]]
        let tokens = workspaces.indices.map { base.token($0 + 1) }
        for (index, token) in tokens.enumerated() {
            _ = WindowAdmissionTestSupport.track(token, in: base.workspace(workspaces[index]), controller: controller)
            let name = "Cached app \(index)"
            let title = "Cached window \(index)"
            _ = controller.appInfoCache.info(for: token.pid) { _ in
                .init(name: name, bundleId: "marks.fixture.\(index)", icon: nil, activationPolicy: .regular)
            }
            AXWindowService.storeTitleCacheEntry(windowId: UInt32(token.windowId), title: title)
            for mark in namesByWorkspace[index] {
                XCTAssertEqual(registry.set(mark, for: token), .inserted)
            }
        }
        defer {
            for token in tokens { AXWindowService.invalidateCachedTitle(windowId: UInt32(token.windowId)) }
        }
        XCTAssertTrue(base.manager.setWindowMinimized(true, token: tokens[1]))
        XCTAssertEqual(registry.set("00 stale", for: base.token(tokens.count + 1)), .inserted)

        let reads: ConfigScriptReads = [.marks, .workspaces, .workspaceWindows]
        let snapshot = capture(reads, from: controller)
        let plain = capture(.workspaces, from: controller)
        assertOnlyWorkspaces(in: plain)
        let entries = cliMarks(for: controller)
        let names = namesByWorkspace.joined().map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
        XCTAssertEqual(entries.map { Array($0.name.utf8) }, names)
        let expected = try entries.map { mark in
            let workspace = try XCTUnwrap(workspaces.firstIndex(of: mark.workspace.rawName))
            let id = windowID(tokens[workspace], in: controller)
            return """
            { name = '\(mark.name)', id = '\(id)', workspaceId = '\(mark.workspace.id)',
              workspace = '\(mark.workspace.rawName)', appName = '\(mark.app.name)',
              bundleId = \(lua(mark.app.bundleId)), title = \(lua(mark.title)) }
            """
        }.joined(separator: ",\n")
        try await assertMarkReadParity(expected, reads: reads, snapshot: snapshot)
    }

    private func assertMarkReadParity(
        _ expected: String, reads: ConfigScriptReads, snapshot: ConfigScriptSnapshot
    ) async throws {
        try await invoke("""
        local expected = { \(expected) }
        omniwm.on('workspace.active', function(ctx)
            assert(#ctx.marks == #expected and table.isfrozen(ctx.marks) and table.isfrozen(ctx.truncated))
            assert(ctx.truncated.marks == false and ctx.truncated.workspaces == nil and ctx.workspaces == nil)
            for index, row in ctx.marks do
                local want = expected[index]
                assert(table.isfrozen(row))
                for key, value in want do assert(row[key] == value, key) end
            end
        end, { reads = { 'marks' } })
        omniwm.on('workspace.active', function(ctx)
            assert(ctx.marks == nil and ctx.truncated.marks == nil)
            assert(ctx.truncated.workspaces == false and #ctx.workspaces > 0)
            assert(ctx.truncated.workspaceWindows == false and ctx.workspaceWindows ~= nil)
        end, { reads = { 'workspaces', 'workspaceWindows' } })
        omniwm.on('workspace.active', function(ctx)
            local namesByID = {}
            for _, row in ctx.workspaces do namesByID[row.id] = row.name end
            for _, mark in ctx.marks do assert(namesByID[mark.workspaceId] == mark.workspace) end
        end, { reads = { 'marks', 'workspaces' } })
        """, expecting: reads, snapshot: snapshot)
    }

    func testMarksUseOnlyCapturedMetadata() async throws {
        let base = try scene()
        let controller = base.controller
        let manager = base.manager
        let workspace = base.workspace(workspaces[0])
        let cachedName = "cached"
        let replacementName = "replacement"
        let hostedName = "hosted"
        let native = base.token(1)
        let replacement = base.token(2)
        let hosted = WindowToken(pid: getpid(), windowId: base.token(3).windowId)
        let fallbackTitle = "Replacement title"
        let fallbackBundle = "marks.replacement"
        let hostedTitle = "Hosted title"
        let hostedBundle = "marks.hosted"
        _ = WindowAdmissionTestSupport.track(native, in: workspace, controller: controller)
        XCTAssertEqual(manager.addWindow(
            WindowAdmissionTestSupport.axRef(for: replacement), pid: replacement.pid, windowId: replacement.windowId,
            to: workspace,
            managedReplacementMetadata: .init(
                bundleId: fallbackBundle, workspaceId: workspace, mode: .tiling, title: fallbackTitle
            )
        ), replacement)
        let size = try XCTUnwrap(manager.monitor(for: workspace)).visibleFrame.size
        XCTAssertEqual(manager.addHostedWindow(
            token: hosted, metadata: .init(appId: hostedBundle, title: hostedTitle, minimumSize: size), to: workspace,
            initialFrame: CGRect(origin: .zero, size: size)
        ), hosted)
        for (name, token) in zip([cachedName, replacementName, hostedName], [native, replacement, hosted]) {
            controller.appInfoCache.evict(pid: token.pid)
            AXWindowService.invalidateCachedTitle(windowId: UInt32(token.windowId))
            XCTAssertEqual(controller.windowMarkRegistry.set(name, for: token), .inserted)
        }
        defer { AXWindowService.invalidateCachedTitle(windowId: UInt32(native.windowId)) }
        let cold = capture(.marks, from: controller)

        let appName = "Cached app"
        let bundle = "marks.cached"
        let title = "Cached title"
        _ = controller.appInfoCache.info(for: native.pid) { _ in
            .init(name: appName, bundleId: bundle, icon: nil, activationPolicy: .regular)
        }
        AXWindowService.storeTitleCacheEntry(windowId: UInt32(native.windowId), title: title)
        let warm = capture(.marks, from: controller)

        let unchanged = [
            MarkText(name: replacementName, appName: nil, bundleId: fallbackBundle, title: fallbackTitle),
            MarkText(name: hostedName, appName: hostedTitle, bundleId: hostedBundle, title: hostedTitle)
        ]
        let uncached = MarkText(name: cachedName, appName: nil, bundleId: nil, title: nil)
        let cached = MarkText(name: cachedName, appName: appName, bundleId: bundle, title: title)
        try await assertMetadata([uncached] + unchanged, snapshot: cold)
        try await assertMetadata([cached] + unchanged, snapshot: warm)
    }

    private func assertMetadata(_ expected: [MarkText], snapshot: ConfigScriptSnapshot) async throws {
        let assertions = expected.map { mark in
            """
            row = assert(marks['\(mark.name)'])
            assert(row.appName == \(lua(mark.appName)) and row.bundleId == \(lua(mark.bundleId)), row.name)
            assert(row.title == \(lua(mark.title)), row.name)
            """
        }.joined(separator: "\n")
        try await invoke("""
        omniwm.on('workspace.active', function(ctx)
            local marks = {}
            for _, mark in ctx.marks do marks[mark.name] = mark end
            local row
            \(assertions)
        end, { reads = { 'marks' } })
        """, expecting: .marks, snapshot: snapshot)
    }

    func testMarkRowsKeepTheSortedPrefixAtTheRowLimit() async throws {
        let base = try scene()
        let controller = base.controller
        let token = base.token(1)
        _ = WindowAdmissionTestSupport.track(token, in: base.workspace(workspaces[0]), controller: controller)
        let limit = ConfigScriptSnapshot.rowLimit
        let names = (0 ... limit).map { "mark-\($0)" }.sorted()

        let reads: ConfigScriptReads = [.marks, .workspaces]
        let empty = capture(reads, from: controller)
        for name in names.reversed() {
            XCTAssertEqual(controller.windowMarkRegistry.set(name, for: token), .inserted)
        }
        let full = capture(reads, from: controller)
        let expected = names.prefix(limit).map { "'\($0)'" }.joined(separator: ", ")
        for (snapshot, truncated) in [(empty, false), (full, true)] {
            try await invoke("""
            local expected = { \(truncated ? expected : "") }
            omniwm.on('workspace.active', function(ctx)
                assert(#ctx.marks == #expected and ctx.truncated.marks == \(truncated))
                for index, row in ctx.marks do assert(row.name == expected[index]) end
                assert(#ctx.workspaces > 0 and ctx.truncated.workspaces == false)
            end, { reads = { 'marks', 'workspaces' } })
            """, expecting: reads, snapshot: snapshot)
        }
    }

    func testOversizedMarkRollsBackOnlyItsOwnRow() async throws {
        let base = try scene()
        let controller = base.controller
        let workspaceName = workspaces[0]
        let workspace = base.workspace(workspaceName)
        let names = ["a kept", "b too large", "c after"]
        let firstTitle = "First title"
        let oversizedTitle = String(repeating: "x", count: ConfigScriptSnapshot.byteLimit)
        let titles = [firstTitle, oversizedTitle, "Later title"]
        for (index, name) in names.enumerated() {
            let token = base.token(index + 1)
            XCTAssertEqual(base.manager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token), pid: token.pid, windowId: token.windowId, to: workspace,
                managedReplacementMetadata: .init(workspaceId: workspace, mode: .tiling, title: titles[index])
            ), token)
            XCTAssertEqual(controller.windowMarkRegistry.set(name, for: token), .inserted)
        }
        let reads: ConfigScriptReads = [.marks, .workspaces]
        let snapshot = capture(reads, from: controller)
        try await invoke("""
        omniwm.on('workspace.active', function(ctx)
            assert(#ctx.marks == 1 and ctx.truncated.marks == true)
            local row = ctx.marks[1]
            assert(row.name == '\(names[0])' and row.title == '\(firstTitle)')
            assert(row.workspace == '\(workspaceName)' and row.workspaceId == '\(workspace.uuidString)')
            assert(#ctx.workspaces > 0 and ctx.truncated.workspaces == false)
        end, { reads = { 'marks', 'workspaces' } })
        """, expecting: reads, snapshot: snapshot)
    }

    private func scene() throws -> NiriGatherFixture {
        let display = NiriGatherFixture.monitor(displayId: UInt32(getpid()))
        return try NiriGatherFixture(
            prefix: "config-mark-reads", monitors: [display],
            workspaces: workspaces.map { .init(name: $0, monitor: display) }
        )
    }

    private func capture(_ reads: ConfigScriptReads, from controller: WMController) -> ConfigScriptSnapshot {
        var pool = ConfigScriptSnapshotPool()
        return controller.configScriptSnapshot(reads: reads, target: controller.configScriptTarget(), pool: &pool)
    }

    private func cliMarks(for controller: WMController) -> [IPCWindowMarkEntry] {
        let response = IPCWindowMarkRequestExecutor(controller: controller).response(for: .list, id: "mark-read")
        XCTAssertTrue(response.ok)
        guard case let .windowMarks(list)? = response.result?.payload else {
            XCTFail("Expected a CLI window mark list")
            return []
        }
        return list.marks
    }

    private func assertOnlyWorkspaces(in snapshot: ConfigScriptSnapshot) {
        let isSingleWorkspaceSection = snapshot.withUnsafeBytes { bytes in
            let headerSize = MemoryLayout<UInt64>.size
            guard bytes.count >= headerSize else { return false }
            let header = bytes.loadUnaligned(as: UInt64.self).littleEndian
            return UInt8(truncatingIfNeeded: header) == UInt8(ConfigScriptReads.workspaces.rawValue)
                && bytes.count == headerSize + Int(header >> UInt32.bitWidth)
        }
        XCTAssertTrue(isSingleWorkspaceSection)
    }

    private func windowID(_ token: WindowToken, in controller: WMController) -> String {
        ConfigScriptWindowID.string(token, session: controller.scriptSession.identity)
    }

    private func lua(_ value: String?) -> String {
        value.map { "'\($0)'" } ?? "nil"
    }

    private func invoke(
        _ source: String, expecting reads: ConfigScriptReads, snapshot: ConfigScriptSnapshot
    ) async throws {
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let generation = try XCTUnwrap(result.generation)
        XCTAssertEqual(result.events.reduce(into: ConfigScriptReads()) { $0.formUnion($1.reads) }, reads)
        for listener in result.events {
            _ = try await generation.invoke(
                function: listener.function, event: ConfigScriptEventPayload(name: "observed"), snapshot: snapshot
            )
        }
    }
}
