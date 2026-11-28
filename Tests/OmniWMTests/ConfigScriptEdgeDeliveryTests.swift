// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptEdgeDeliveryTests: XCTestCase {
    private typealias Fixture = ConfigScriptCallbackQueueTests.Fixture

    func testBoundedFIFOKeepsEdgesAcrossKindsAndReportsTailLossWithoutAnotherEdge() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let kinds: [ConfigScriptEventKind] = [.windowOpen, .windowClose]
        let limit = ConfigScriptCallbackQueue.edgeCapacity
        let excess = kinds.count
        let marker = "Inspect burst"
        let workspace = UUID()
        let session = fixture.controller.scriptSession
        let tokens = (0 ... (limit + excess)).map { WindowToken(pid: getpid(), windowId: $0) }
        let ids = tokens.map { ConfigScriptWindowID.string($0, session: session.identity) }
        let body = [
            "local received = {}",
            "local ids = {\(ids.map { "'\($0)'" }.joined(separator: ","))}",
            "local function record(kind, e)",
            "    assert(table.isfrozen(e) and e.workspaceId == '\(workspace.uuidString)')",
            "    if e.id == ids[#ids] then assert(e.missed == (if #received > 0 then \(excess) else 0)) return end",
            "    table.insert(received, {kind, e.id, e.missed})",
            "end"
        ] + kinds.map {
            "omniwm.on('\($0.rawValue)', function(e) record('\($0.rawValue)', e) end)"
        } + [
            "omniwm.command('\(marker)', function()",
            "    assert(#received == \(limit))",
            "    for i, item in received do",
            "        assert(item[1] == (if i % 2 == 1 then '\(kinds[0].rawValue)' else '\(kinds[1].rawValue)'))",
            "        assert(item[2] == ids[i])",
            "        assert(item[3] == (if i == #received then \(excess) else 0))",
            "    end",
            "end)"
        ]
        fixture.apply(try await fixture.load(body))
        let observer = try XCTUnwrap(fixture.script.eventObservers)
        let check = try XCTUnwrap(fixture.script.acceptedCommands.first)
        let before = omni_config_vm_entry_count()
        for offset in 0 ..< (limit + excess) {
            observer.publishNative(kinds[offset % kinds.count], .init(
                id: .window(tokens[offset], session.identity, session.epoch), edge: .workspace(id: workspace, name: nil)
            ))
        }
        XCTAssertEqual(fixture.press(.configFunction(check.function)), .executed)
        XCTAssertEqual(omni_config_vm_entry_count(), before)
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        XCTAssertTrue(queue.hasPendingWork)
        await queue.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
        assertConfigVMEntries(UInt64(limit + 1), since: before)
        let subsequent = ConfigScriptNativeEvent(
            id: .window(tokens.last!, session.identity, session.epoch),
            edge: .workspace(id: workspace, name: nil)
        )
        observer.publishNative(.windowClose, subsequent)
        await fixture.script.callbackQueue?.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
        fixture.apply(try await fixture.load(body))
        let replacement = try XCTUnwrap(fixture.script.eventObservers)
        replacement.publishNative(.windowOpen, subsequent)
        await fixture.script.callbackQueue?.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testMoveListenerSkipsItsOwnCommittedMoveWhileOtherListenerReceivesBoth() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let origin = try XCTUnwrap(manager.workspaceId(named: fixture.origin))
        let destination = try XCTUnwrap(manager.workspaceId(named: fixture.destination))
        let monitor = try XCTUnwrap(manager.monitors.first)
        let first = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let second = WindowToken(pid: first.pid, windowId: first.windowId + 1)
        let appId = "test.edge.echo"
        for token in [first, second] {
            let metadata = HostedWindowMetadata(
                appId: appId,
                title: "Edge",
                minimumSize: monitor.visibleFrame.size,
                admitsFloating: true
            )
            XCTAssertEqual(manager.addHostedWindow(
                token: token, metadata: metadata, to: origin, initialFrame: monitor.visibleFrame
            ), token)
        }
        _ = manager.setManagedFocus(second, in: origin, onMonitor: monitor.id)
        let firstId = ConfigScriptWindowID.string(first, session: controller.scriptSession.identity)
        let secondId = ConfigScriptWindowID.string(second, session: controller.scriptSession.identity)
        fixture.apply(try await fixture.load([
            "local wm = omniwm",
            "local visited = {}",
            "wm.on('window.move_to_workspace', function(e)",
            "    assert(e.id == '\(firstId)' and e.bundleId == '\(appId)', 'unexpected echo')",
            "    assert(e.workspaceName == '\(fixture.destination)' and e.previousWorkspaceName == '\(fixture.origin)')",
            "    wm.dispatch(wm.cmd.moveToWorkspace('\(fixture.destination)'))",
            "end)",
            "wm.on('window.move_to_workspace', function(e) table.insert(visited, e.id) end)",
            "wm.command('Check moves', function() assert(table.concat(visited, ',') == '\(firstId),\(secondId)') end)"
        ]))
        let before = omni_config_vm_entry_count()
        manager.setWorkspace(for: first, to: destination)
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        XCTAssertTrue(queue.hasPendingWork)
        await queue.waitUntilParked()
        XCTAssertEqual(manager.workspace(for: second), destination)
        assertConfigVMEntries(3, since: before)
        XCTAssertNil(fixture.script.diagnostic)
        let check = try XCTUnwrap(fixture.script.acceptedCommands.first)
        XCTAssertEqual(fixture.press(.configFunction(check.function)), .executed)
        await fixture.script.callbackQueue?.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testGeometryPayloadAndItsFourRectanglesAreImmutable() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let monitor = try XCTUnwrap(fixture.controller.workspaceManager.monitors.first)
        let previous = monitor.frame
        let current = previous.offsetBy(dx: previous.width, dy: previous.height)
        let previousVisible = monitor.visibleFrame
        let currentVisible = previousVisible.offsetBy(dx: previous.width, dy: previous.height)
        let frames = [
            ("frame", current), ("previousFrame", previous),
            ("visibleFrame", currentVisible), ("previousVisibleFrame", previousVisible)
        ]
        let assertions = frames.flatMap { name, rect in
            [
                "    assert(table.isfrozen(e.\(name)))",
                "    assert(e.\(name).x == \(rect.origin.x) and e.\(name).y == \(rect.origin.y))",
                "    assert(e.\(name).width == \(rect.width) and e.\(name).height == \(rect.height))"
            ]
        }
        fixture.apply(try await fixture.load(
            ["omniwm.on('monitor.layout_changed', function(e)", "    assert(table.isfrozen(e) and e.missed == 0)"]
                + assertions + ["end)"]
        ))
        let observer = try XCTUnwrap(fixture.script.eventObservers)
        observer.publishNative(.monitorLayoutChanged, .init(
            id: .monitor(monitor.id), name: monitor.name,
            edge: .geometry(
                frame: current,
                previousFrame: previous,
                visibleFrame: currentVisible,
                previousVisibleFrame: previousVisible
            )
        ))
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        XCTAssertTrue(queue.hasPendingWork)
        await queue.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
    }
}
