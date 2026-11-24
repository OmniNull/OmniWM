// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptWindowStateDeliveryTests: XCTestCase {
    private typealias Fixture = ConfigScriptCallbackQueueTests.Fixture

    func testRepeatedWindowIDsFollowTheCurrentTokenAndIPCSession() {
        let first = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let second = WindowToken(pid: first.pid, windowId: first.windowId + 1)
        let sessions = [UUID().uuidString, UUID().uuidString]
        for session in sessions {
            for token in [first, first, second, second, first] {
                let state = ConfigScriptNativeEvent(id: .window(token, ConfigScriptSessionToken(session).identity, 0))
                let actual = state.payload().id!
                XCTAssertEqual(actual, IPCWindowOpaqueID.encode(token: token, sessionToken: session))
                XCTAssertEqual(
                    IPCWindowOpaqueID.validate(actual, expectingSessionToken: session),
                    .valid(pid: token.pid, windowId: token.windowId)
                )
            }
        }
    }

    func testLatestValuesKeepTheirOwnPositionPerWindowAndKind() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let updates: [(ConfigScriptEventKind, String, ConfigScriptEventPayload.Edge)] = [
            (.windowTitle, "first", .title("original")),
            (.windowTitle, "second", .title("other")),
            (.windowMinimize, "first", .minimized(true)),
            (.windowFullscreen, "first", .fullscreen(true)),
            (.windowUpdateState, "first", .floating(true)),
            (.windowTitle, "first", .title("newest")),
            (.windowMinimize, "first", .minimized(false)),
            (.windowFullscreen, "first", .fullscreen(false)),
            (.windowUpdateState, "first", .floating(false))
        ]
        let session = fixture.controller.automationSession
        let first = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let second = WindowToken(pid: first.pid, windowId: first.windowId + 1)
        let expected = [
            IPCWindowOpaqueID.encode(token: first, sessionToken: session.text) + ":newest",
            IPCWindowOpaqueID.encode(token: second, sessionToken: session.text) + ":other",
            "minimized:false",
            "fullscreen:false",
            "floating:false"
        ]
        let script = [
            "local result = {}",
            "local function record(e, value)",
            "    assert(table.isfrozen(e) and e.missed == 0 and e.bundleId == 'fixture')",
            "    table.insert(result, value)",
            "end",
            "omniwm.on('window.title', function(e) record(e, e.id .. ':' .. e.title) end)",
            "omniwm.on('window.minimize', function(e) record(e, 'minimized:' .. tostring(e.minimized)) end)",
            "omniwm.on('window.fullscreen', function(e) record(e, 'fullscreen:' .. tostring(e.fullscreen)) end)",
            "omniwm.on('window.update_state', function(e) record(e, 'floating:' .. tostring(e.floating)) end)",
            "omniwm.command('Check', function() assert(table.concat(result, ',') == '\(expected.joined(separator: ","))') end)"
        ]
        fixture.apply(try await fixture.load(script))
        let observer = try XCTUnwrap(fixture.script.eventObservers)
        let before = omni_config_vm_entry_count()
        for (kind, id, value) in updates {
            let token = id == "first" ? first : second
            let edge: ConfigScriptNativeEvent.Edge
            switch value {
            case let .title(title):
                observer.publishTitle(.init(
                    token: token,
                    session: session.identity,
                    epoch: session.epoch,
                    title: title,
                    bundle: "fixture"
                ), controller: fixture.controller)
                continue
            case let .minimized(flag): edge = .minimized(flag)
            case let .fullscreen(flag): edge = .fullscreen(flag)
            case let .floating(flag): edge = .floating(flag)
            default: return XCTFail("Expected a window-state edge")
            }
            observer.publishNative(kind, .init(
                id: .window(token, session.identity, session.epoch),
                bundleId: "fixture",
                edge: edge
            ))
        }
        let check = try XCTUnwrap(fixture.script.acceptedCommands.first)
        XCTAssertEqual(fixture.press(.configFunction(check.function)), .executed)
        await fixture.script.callbackQueue?.waitUntilParked()
        assertConfigVMEntries(UInt64(expected.count + 1), since: before)
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testTitleTriggeredByAListenerExcludesItsWholeAncestry() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        _ = WindowAdmissionTestSupport.track(token, in: workspace.id, controller: controller)
        let initial = "first title"
        fixture.apply(try await fixture.load([
            "local wm, titles = omniwm, {}",
            "wm.on('window.title', function(e)",
            "    assert(e.title == '\(initial)', 'first listener received an echo')",
            "    wm.dispatch(wm.cmd('switch-workspace', '\(fixture.destination)'))",
            "end)",
            "for i = 1, \(UInt64.bitWidth) do wm.on('monitor.added', function() end) end",
            "wm.on('window.title', function(e)",
            "    assert(e.title ~= '\(fixture.origin)', 'second listener received an echo')",
            "    if e.title == '\(fixture.destination)' then wm.dispatch(wm.cmd('switch-workspace', '\(fixture.origin)')) end",
            "end)",
            "wm.on('window.title', function(e) table.insert(titles, e.title) end)",
            "wm.command('Check', function() assert(table.concat(titles, '|') == '\(initial)|\(fixture.destination)|\(fixture.origin)') end)"
        ]))
        let observer = try XCTUnwrap(fixture.script.eventObservers)
        let previous = manager.onSessionStateChanged
        var last = fixture.origin
        manager.onSessionStateChanged = { scope in
            previous?(scope)
            guard let current = controller.activeWorkspace()?.name, current != last else { return }
            last = current
            observer.titleChanged(current, for: token, metadataChanged: true, controller: controller)
        }
        defer { manager.onSessionStateChanged = previous }
        observer.titleChanged(initial, for: token, metadataChanged: true, controller: controller)
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        await queue.waitUntilParked()
        let check = try XCTUnwrap(fixture.script.acceptedCommands.first)
        XCTAssertEqual(fixture.press(.configFunction(check.function)), .executed)
        await queue.waitUntilParked()
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testOverflowReportsLossOnTheTailAndStillAcceptsReplacementForAQueuedWindow() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let capacity = ConfigScriptCallbackQueue.windowStateCapacity
        let dropped = ["outside", "another"]
        let names = (1 ... capacity).map(String.init)
        let titles = names + dropped + ["next"]
        let session = fixture.controller.automationSession
        let tokens = titles.indices.map { WindowToken(pid: getpid(), windowId: $0) }
        let ids = tokens.map { IPCWindowOpaqueID.encode(token: $0, sessionToken: session.text) }
        let orderedIDs = ids.prefix(capacity).map { "'\($0)'" }.joined(separator: ",")
        fixture.apply(try await fixture.load([
            "local seen = 0",
            "local ids = {\(orderedIDs)}",
            "omniwm.on('window.title', function(e)",
            "    if e.id == '\(try XCTUnwrap(ids.last))' then assert(e.missed == \(dropped.count)) return end",
            "    seen += 1",
            "    assert(e.id == ids[seen])",
            "    assert(e.title == (if seen == \(capacity) then 'replacement' else tostring(seen)))",
            "    assert(e.missed == (if seen == \(capacity) then \(dropped.count) else 0))",
            "end)",
            "omniwm.command('Count', function() assert(seen == \(capacity)) end)"
        ]))
        let queue = try XCTUnwrap(fixture.script.callbackQueue)
        func enqueue(_ title: String, at index: Int) {
            queue.enqueueTitle(
                ConfigScriptWindowTitle(
                    token: tokens[index], session: session.identity, epoch: session.epoch, title: title, bundle: nil
                ), controller: fixture.controller
            )
        }
        let before = omni_config_vm_entry_count()
        for (index, title) in titles.dropLast().enumerated() { enqueue(title, at: index) }
        enqueue("replacement", at: names.index(before: names.endIndex))
        await queue.waitUntilParked()
        assertConfigVMEntries(UInt64(capacity), since: before)
        enqueue("next", at: titles.index(before: titles.endIndex))
        let check = try XCTUnwrap(fixture.script.acceptedCommands.first)
        XCTAssertEqual(fixture.press(.configFunction(check.function)), .executed)
        await fixture.script.callbackQueue?.waitUntilParked()
        assertConfigVMEntries(UInt64(capacity + 2), since: before)
        XCTAssertNil(fixture.script.diagnostic)
    }
}
