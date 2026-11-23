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
        var states = ConfigScriptObservedWindowStates()
        for session in sessions {
            for token in [first, first, second, second, first] {
                let actual = states.opaqueID(for: token, session: session)
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
        let expected = ["first:newest", "second:other", "minimized:false", "fullscreen:false", "floating:false"]
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
            observer.emit(kind, .init(id: id, bundleId: "fixture", edge: value))
        }
        let check = try XCTUnwrap(fixture.script.acceptedCommands.first)
        XCTAssertEqual(fixture.press(.configFunction(check.function)), .executed)
        await fixture.script.callbackQueue?.worker?.value
        XCTAssertEqual(omni_config_vm_entry_count() - before, UInt64(expected.count + 1))
        XCTAssertNil(fixture.script.diagnostic)
    }

    func testOverflowReportsLossOnTheTailAndStillAcceptsReplacementForAQueuedWindow() async throws {
        let fixture = try Fixture(test: self)
        defer { fixture.controller.stopConfigScript() }
        let capacity = ConfigScriptCallbackQueue.windowStateCapacity
        let dropped = ["outside", "another"]
        fixture.apply(try await fixture.load([
            "local seen = 0",
            "omniwm.on('window.title', function(e)",
            "    if e.id == 'next' then assert(e.missed == \(dropped.count)) return end",
            "    seen += 1",
            "    assert(e.id == tostring(seen))",
            "    assert(e.title == (if seen == \(capacity) then 'replacement' else e.id))",
            "    assert(e.missed == (if seen == \(capacity) then \(dropped.count) else 0))",
            "end)",
            "omniwm.command('Count', function() assert(seen == \(capacity)) end)"
        ]))
        let observer = try XCTUnwrap(fixture.script.eventObservers)
        let before = omni_config_vm_entry_count()
        for id in (1 ... capacity).map(String.init) + dropped {
            observer.emit(.windowTitle, .init(id: id, edge: .title(id)))
        }
        observer.emit(.windowTitle, .init(id: String(capacity), edge: .title("replacement")))
        await fixture.script.callbackQueue?.worker?.value
        XCTAssertEqual(omni_config_vm_entry_count() - before, UInt64(capacity))
        observer.emit(.windowTitle, .init(id: "next", edge: .title("resumed")))
        let check = try XCTUnwrap(fixture.script.acceptedCommands.first)
        XCTAssertEqual(fixture.press(.configFunction(check.function)), .executed)
        await fixture.script.callbackQueue?.worker?.value
        XCTAssertEqual(omni_config_vm_entry_count() - before, UInt64(capacity + 2))
        XCTAssertNil(fixture.script.diagnostic)
    }
}
