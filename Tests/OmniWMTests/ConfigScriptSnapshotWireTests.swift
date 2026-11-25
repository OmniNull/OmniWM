// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptSnapshotWireTests: XCTestCase {
    private struct Wire {
        var data = Data()

        mutating func integer(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func text(_ value: String?) {
            guard let value else {
                integer(UInt32.max)
                return
            }
            integer(UInt32(value.utf8.count))
            data.append(contentsOf: value.utf8)
        }

        mutating func list(
            _ kind: ConfigScriptReads, rows: [Wire], truncated: Bool = false, framed: Bool = false,
            columned: Bool = false
        ) {
            section(UInt8(kind.rawValue), rows: rows, flags: UInt8(
                (truncated ? OMNI_CONFIG_SECTION_TRUNCATED : 0) | (framed ? OMNI_CONFIG_SECTION_FRAMES : 0) |
                    (columned ? OMNI_CONFIG_SECTION_COLUMNS : 0)
            ))
        }

        mutating func section(_ tag: UInt8, rows: [Wire], flags: UInt8 = 0) {
            integer(tag)
            integer(flags)
            integer(UInt16(rows.count))
            integer(UInt32(rows.reduce(0) { $0 + $1.data.count }))
            for row in rows { data += row.data }
        }

        mutating func rect(_ frame: CGRect) {
            for value in [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height] {
                integer(Double(value).bitPattern)
            }
        }
    }

    func testCompleteSnapshotMatchesAllWireBytesInNativeOrder() throws {
        let fixture = try ConfigScriptCallbackQueueTests.Fixture(test: self)
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let here = try XCTUnwrap(manager.workspaceId(named: fixture.origin))
        let there = try XCTUnwrap(manager.workspaceId(named: fixture.destination))
        let monitor = try XCTUnwrap(manager.monitor(for: here))
        let display = monitor.id.scriptIdentifier
        let utf16Units: [UInt16] = [0x754C, 0xD800, 0x7532]
        let foreign = utf16Units.withUnsafeBufferPointer {
            NSString(characters: $0.baseAddress!, length: $0.count) as String
        }
        let titles: [String?] = [foreign, "", nil]
        var windows: [Wire] = []
        for (index, title) in titles.enumerated() {
            let token = WindowToken(pid: getpid(), windowId: Int(getpid()) + index)
            let local = index != titles.count - 1
            let workspace = local ? here : there
            let mode: TrackedWindowMode = local ? .floating : .tiling
            let minimized = local
            let bundle = local ? "test.snapshot.\(index)" : nil
            let admitted = manager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token), pid: token.pid, windowId: token.windowId, to: workspace,
                mode: mode, isMinimized: minimized,
                managedReplacementMetadata: .init(bundleId: bundle, workspaceId: workspace, mode: mode, title: title)
            )
            XCTAssertEqual(admitted, token)
            var row = Wire()
            row.text(ConfigScriptWindowID.string(token, session: controller.scriptSession.identity))
            row.text(bundle)
            row.text(title)
            row.text(local ? fixture.origin : fixture.destination)
            row.text(display)
            let flags = (mode == .floating ? OMNI_CONFIG_WINDOW_FLOATING : 0) |
                (minimized ? OMNI_CONFIG_WINDOW_MINIMIZED : 0)
            row.integer(UInt8(flags))
            windows.append(row)
        }
        var expected = Wire()
        expected.list(.workspaceWindows, rows: Array(windows.dropLast()))
        expected.list(.windows, rows: windows)
        expected.list(.workspaces, rows: manager.sortedWorkspaces().map { workspace in
            var row = Wire()
            row.text(workspace.id.uuidString)
            row.text(workspace.name)
            row.text(manager.resolvedWorkspaceMonitorId(for: workspace.id)?.scriptIdentifier)
            return row
        })
        expected.list(.monitors, rows: manager.sortedMonitors().map { monitor in
            var row = Wire()
            row.text(monitor.id.scriptIdentifier)
            row.text(monitor.name)
            return row
        })
        var pool = ConfigScriptSnapshotPool()
        let reads: ConfigScriptReads = [.workspaceWindows, .windows, .workspaces, .monitors]
        let actual = controller.configScriptSnapshot(reads: reads, target: controller.configScriptTarget(), pool: &pool)
        XCTAssertEqual(actual.withUnsafeBytes { Data($0) }, expected.data)
    }

    func testTheDwindleSectionFollowsTheListsWithItsTreeInPreorder() async throws {
        let fixture = try ConfigScriptWindowFixture(
            monitors: [NiriGatherFixture.monitor(displayId: 1)], layouts: [.dwindle]
        )
        let base = fixture.base
        let manager = base.manager
        let workspace = base.workspace("1")
        base.add([1, 2, 3], to: workspace)
        try await fixture.focus(1, on: "1")
        let engine = try XCTUnwrap(base.controller.dwindleEngine)
        var snapshot: DwindleLayoutSnapshot?
        manager.withEngineMutationScope(in: workspace) {
            XCTAssertTrue(engine.groupWindow(base.token(3), into: base.token(2), in: workspace))
            XCTAssertTrue(engine.setPreselection(.down, in: workspace))
            snapshot = engine.layoutSnapshot(in: workspace)
        }
        let tree = try XCTUnwrap(snapshot)
        XCTAssertTrue(tree.nodes.contains { $0.orientation != nil })
        XCTAssertTrue(tree.nodes.contains { $0.members.count > 1 })
        let session = base.controller.scriptSession.identity
        var row = Wire()
        row.text(workspace.uuidString)
        row.integer(UInt16(tree.nodes.count))
        for node in tree.nodes {
            if let orientation = node.orientation {
                row.integer(UInt8(OMNI_CONFIG_DWINDLE_SPLIT))
                row.integer(UInt8(
                    orientation == .vertical ? OMNI_CONFIG_DWINDLE_VERTICAL : OMNI_CONFIG_DWINDLE_HORIZONTAL
                ))
                row.integer(Double(node.ratio).bitPattern)
                continue
            }
            let members = tree.members[node.members]
            let active = try XCTUnwrap(members.firstIndex { $0.token == node.active }) - members.startIndex
            row.integer(UInt8(OMNI_CONFIG_DWINDLE_LEAF))
            row.integer(UInt16(active + 1))
            row.integer(UInt16(members.count))
            for member in members { row.text(ConfigScriptWindowID.string(member.token, session: session)) }
        }
        row.integer(UInt8(OMNI_CONFIG_DWINDLE_DOWN))
        let digits = UInt64.bitWidth / 4
        row.text(String(repeating: "0", count: digits))
        var expected = Wire()
        expected.list(.monitors, rows: manager.sortedMonitors().map { monitor in
            var row = Wire()
            row.text(monitor.id.scriptIdentifier)
            row.text(monitor.name)
            return row
        })
        expected.section(UInt8(OMNI_CONFIG_SECTION_DWINDLE), rows: [row])
        var pool = ConfigScriptSnapshotPool()
        let actual = base.controller.configScriptSnapshot(
            reads: [.monitors, .dwindle], target: base.controller.configScriptTarget(), pool: &pool
        ).withUnsafeBytes { Data($0) }
        XCTAssertEqual(actual.count, expected.data.count)
        XCTAssertEqual(actual.dropLast(digits), expected.data.dropLast(digits))
        let hex = Set("0123456789ABCDEF".utf8)
        XCTAssertTrue(actual.suffix(digits).allSatisfy(hex.contains))
    }

    func testExactlyFullRowAndOneByteOverflowAcrossListBoundary() throws {
        let fixture = try ConfigScriptCallbackQueueTests.Fixture(test: self)
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let here = try XCTUnwrap(manager.workspaceId(named: fixture.origin))
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let display = try XCTUnwrap(manager.monitor(for: here)).id
        let id = ConfigScriptWindowID.string(token, session: controller.scriptSession.identity)
        let bundle = "wire.limit"
        func row(_ title: String) -> Wire {
            var row = Wire()
            for field in [id, bundle, title, fixture.origin, display.scriptIdentifier] { row.text(field) }
            row.integer(UInt8(OMNI_CONFIG_WINDOW_FLOATING))
            return row
        }
        var empty = Wire()
        empty.list(.windows, rows: [row("")])
        let fitting = String(repeating: "x", count: ConfigScriptSnapshot.byteLimit - empty.data.count)
        _ = manager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token), pid: token.pid, windowId: token.windowId, to: here,
            mode: .floating,
            managedReplacementMetadata: .init(bundleId: bundle, workspaceId: here, mode: .floating, title: fitting)
        )
        var pool = ConfigScriptSnapshotPool()
        for title in [fitting, fitting + "x"] {
            _ = manager.updateManagedReplacementTitle(title, for: token)
            let rows = title == fitting ? [row(title)] : []
            var expected = Wire()
            expected.list(.workspaceWindows, rows: rows, truncated: rows.isEmpty)
            expected.list(.windows, rows: rows, truncated: rows.isEmpty)
            let actual = controller.configScriptSnapshot(
                reads: [.workspaceWindows, .windows], target: controller.configScriptTarget(), pool: &pool
            )
            XCTAssertEqual(actual.withUnsafeBytes { Data($0) }, expected.data)
        }
    }

    func testColumnNumbersSitBetweenFlagsAndFramesAndNeverShortenAList() throws {
        let display = NiriGatherFixture.monitor(displayId: 1)
        let fixture = try ConfigScriptWindowFixture(monitors: [display])
        let base = fixture.base
        let manager = base.manager
        let controller = base.controller
        let strip = base.workspace("1")
        let bundle = "wire.columns"
        let frame = CGRect(x: 100, y: 200, width: 500, height: 300)
        let ids = [1, 2, 3]
        let floating = 3
        for id in ids {
            let token = base.token(id)
            let mode: TrackedWindowMode = id == floating ? .floating : .tiling
            _ = manager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token), pid: token.pid, windowId: token.windowId, to: strip,
                mode: mode,
                managedReplacementMetadata: .init(bundleId: bundle, workspaceId: strip, mode: mode, title: "")
            )
        }
        manager.withEngineMutationScope {
            for id in ids where id != floating {
                _ = base.engine.addWindow(token: base.token(id), to: strip, afterSelection: nil)
            }
        }
        manager.updateFloatingGeometry(frame: frame, for: base.token(floating), referenceMonitor: display)
        let numbers = try XCTUnwrap(base.handler.columnSummary(for: strip)?.columnIndexByToken)
        XCTAssertEqual(numbers.count, ids.count - 1)
        func row(_ id: Int, _ title: String, columned: Bool, framed: Bool) -> Wire {
            var row = Wire()
            row.text(fixture.id(id))
            for field in [bundle, title, "1", display.id.scriptIdentifier] { row.text(field) }
            row.integer(UInt8(id == floating ? OMNI_CONFIG_WINDOW_FLOATING : 0))
            if columned { row.integer(UInt16(numbers[base.token(id)] ?? 0)) }
            guard framed else { return row }
            guard id == floating else {
                row.integer(UInt8.zero)
                return row
            }
            row.integer(UInt8(OMNI_CONFIG_FRAME_PRESENT))
            row.rect(frame)
            return row
        }
        var empty = Wire()
        empty.list(.windows, rows: ids.map { row($0, "", columned: false, framed: false) })
        let fitting = String(repeating: "x", count: ConfigScriptSnapshot.byteLimit - empty.data.count)
        var pool = ConfigScriptSnapshotPool()
        for title in [fitting, fitting + "x"] {
            _ = manager.updateManagedReplacementTitle(title, for: base.token(floating))
            for (columned, framed) in [(false, false), (true, false), (true, true)] {
                var rows = ids.filter { $0 != floating }.map { row($0, "", columned: columned, framed: framed) }
                if title == fitting { rows.append(row(floating, title, columned: columned, framed: framed)) }
                var expected = Wire()
                expected.list(
                    .windows, rows: rows, truncated: rows.count < ids.count, framed: framed, columned: columned
                )
                var reads: ConfigScriptReads = [.windows]
                if columned { reads.insert(.windowColumns) }
                if framed { reads.insert(.windowFrames) }
                let actual = controller.configScriptSnapshot(
                    reads: reads, target: controller.configScriptTarget(), pool: &pool
                )
                XCTAssertEqual(
                    actual.withUnsafeBytes { Data($0) },
                    expected.data,
                    "columns \(columned), frames \(framed)"
                )
            }
        }
    }

    func testFramesFollowTheirRowsAndNeverShortenAList() async throws {
        let fixture = try ConfigScriptCallbackQueueTests.Fixture(test: self)
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let here = try XCTUnwrap(manager.workspaceId(named: fixture.origin))
        let monitor = try XCTUnwrap(manager.monitor(for: here))
        let tokens = [0, 1].map { WindowToken(pid: getpid(), windowId: Int(getpid()) + $0) }
        let bundle = "wire.frames"
        let frame = CGRect(x: 100, y: 200, width: 500, height: 300)
        func row(_ token: WindowToken, _ title: String, framed: Bool) -> Wire {
            var row = Wire()
            row.text(ConfigScriptWindowID.string(token, session: controller.scriptSession.identity))
            for field in [bundle, title, fixture.origin, monitor.id.scriptIdentifier] { row.text(field) }
            row.integer(UInt8(OMNI_CONFIG_WINDOW_FLOATING))
            guard framed else { return row }
            row.integer(UInt8(OMNI_CONFIG_FRAME_PRESENT))
            row.rect(frame)
            return row
        }
        var empty = Wire()
        empty.list(.windows, rows: tokens.map { row($0, "", framed: false) })
        let fitting = String(repeating: "x", count: ConfigScriptSnapshot.byteLimit - empty.data.count)
        for token in tokens {
            _ = manager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token), pid: token.pid, windowId: token.windowId, to: here,
                mode: .floating,
                managedReplacementMetadata: .init(bundleId: bundle, workspaceId: here, mode: .floating, title: "")
            )
            manager.updateFloatingGeometry(frame: frame, for: token, referenceMonitor: monitor)
        }
        var display = Wire()
        display.text(monitor.id.scriptIdentifier)
        display.text(monitor.name)
        display.rect(monitor.frame)
        display.rect(monitor.visibleFrame)
        var pool = ConfigScriptSnapshotPool()
        let reads: ConfigScriptReads = [.windows, .monitors, .windowFrames, .monitorFrames]
        for title in [fitting, fitting + "x"] {
            _ = manager.updateManagedReplacementTitle(title, for: tokens[1])
            var rows = [row(tokens[0], "", framed: true)]
            if title == fitting { rows.append(row(tokens[1], title, framed: true)) }
            let truncated = rows.count < tokens.count
            var expected = Wire()
            expected.list(.windows, rows: rows, truncated: truncated, framed: true)
            expected.list(.monitors, rows: [display], framed: true)
            let actual = controller.configScriptSnapshot(
                reads: reads, target: controller.configScriptTarget(), pool: &pool
            )
            XCTAssertEqual(actual.withUnsafeBytes { Data($0) }, expected.data)
            let source = """
            local function check(e, framed)
                assert(#e.windows == \(rows.count) and e.truncated.windows == \(truncated))
                for _, w in e.windows do assert((w.frame ~= nil) == framed) end
            end
            omniwm.on('workspace.active', function(e) check(e, true) end, { reads = { 'windows', 'frames' } })
            omniwm.on('workspace.active', function(e) check(e, false) end, { reads = { 'windows' } })
            """
            let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
            let generation = try XCTUnwrap(result.generation)
            for listener in result.events {
                _ = try await generation.invoke(
                    function: listener.function, event: ConfigScriptEventPayload(name: "observed"), snapshot: actual
                )
            }
        }
    }
}
