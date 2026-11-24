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

        mutating func list(_ kind: ConfigScriptReads, rows: [Wire], truncated: Bool = false) {
            integer(kind.rawValue)
            integer(UInt8(truncated ? 1 : 0))
            integer(UInt16(rows.count))
            integer(UInt32(rows.reduce(0) { $0 + $1.data.count }))
            for row in rows { data += row.data }
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
}
