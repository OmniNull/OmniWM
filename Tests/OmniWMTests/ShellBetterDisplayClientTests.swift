// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellBetterDisplayClientTests: XCTestCase {
    private struct Call: Equatable, Sendable {
        let command: String
        let parameters: [String: String?]
    }

    private actor Recorder {
        var calls: [Call] = []

        func record(_ call: Call) {
            calls.append(call)
        }
    }

    func testIdentifierFormatsExcludeGroupsVirtualScreensAndAmbiguousUUIDs() {
        let physical = UUID()
        let ambiguous = UUID()
        let entries = [
            #"{"deviceType":"Display","UUID":"\#(physical)"}"#,
            #"{"deviceType":"VirtualScreen","UUID":"\#(UUID())"}"#,
            #"{"deviceType":"DisplayGroup","UUID":"\#(UUID())"}"#,
            #"{"deviceType":"Display","UUID":"bad"}"#,
            #"{"deviceType":"Display","UUID":"\#(ambiguous)"}"#,
            #"{"deviceType":"Display","UUID":"\#(ambiguous.uuidString.lowercased())"}"#
        ].joined(separator: ",")
        XCTAssertEqual(ShellBetterDisplayClient.displayIDs(entries), [physical])
        XCTAssertEqual(ShellBetterDisplayClient.displayIDs("[\(entries)]"), [physical])
        XCTAssertEqual(ShellBetterDisplayClient.displayIDs("unavailable"), [])
    }

    func testBrightnessOnlyReadsConnectedAttachedDisplaysWithValidLevels() async {
        let connected = UUID()
        let disconnected = UUID()
        let invalid = UUID()
        let elsewhere = UUID()
        let ids = [connected, disconnected, invalid, elsewhere]
        let client = ShellBetterDisplayClient.client(runningPID: { 42 }, request: { _, command, params in
            XCTAssertEqual(command, "get")
            if params.keys.contains("identifiers") {
                return ids.map { #"{"deviceType":"Display","UUID":"\#($0)"}"# }.joined(separator: ",")
            }
            let id = params["UUID"] ?? nil
            XCTAssertNotEqual(id, elsewhere.uuidString)
            if params.keys.contains("connected") { return id == disconnected.uuidString ? "off" : "on" }
            XCTAssertNotEqual(id, disconnected.uuidString)
            return id == invalid.uuidString ? "nan" : "0.75"
        })
        let values = await client.brightness([connected, disconnected, invalid, UUID()])
        XCTAssertEqual(values, [connected: .init(value: 0.75), invalid: .init(value: nil)])
    }

    func testWritesValidateTargetsAndKeepActionsPreciselyScoped() async {
        let display = UUID()
        let recorder = Recorder()
        let client = ShellBetterDisplayClient.client(runningPID: { 42 }, request: { pid, command, params in
            XCTAssertEqual(pid, 42)
            if command == "set" {
                await recorder.record(Call(command: command, parameters: params))
                return ""
            }
            if params.keys.contains("identifiers") { return #"{"deviceType":"Display","UUID":"\#(display)"}"# }
            if params.keys.contains("connected") { return "on" }
            if params.keys.contains("brightness") { return "0.3" }
            if params.keys.contains("nightShift") { return "off" }
            return nil
        })

        let stalePID = await client.setBrightness(41, display, 0.7)
        let missingDisplay = await client.setBrightness(42, UUID(), 0.3)
        let invalidValue = await client.setBrightness(42, display, .nan)
        let brightnessSet = await client.setBrightness(42, display, 0.6)
        let nightSet = await client.setNightShift(42, true)
        let menuOpened = await client.openMenu(42)

        XCTAssertFalse(stalePID)
        XCTAssertFalse(missingDisplay)
        XCTAssertFalse(invalidValue)
        XCTAssertTrue(brightnessSet)
        XCTAssertTrue(nightSet)
        XCTAssertTrue(menuOpened)
        let writes = await recorder.calls
        XCTAssertEqual(writes, [
            Call(command: "set", parameters: ["UUID": display.uuidString, "brightness": "0.6"]),
            Call(command: "set", parameters: ["nightShift": "on"]),
            Call(command: "set", parameters: ["appMenu": "on"])
        ])
    }

    func testUnavailableAppAndFailedRequestsLeaveControlsUnavailable() async {
        let absent = ShellBetterDisplayClient.client(runningPID: { nil }, request: { _, _, _ in
            XCTFail("Sent a request while BetterDisplay was absent")
            return nil
        })
        let failing = ShellBetterDisplayClient.client(runningPID: { 42 }, request: { _, command, _ in
            XCTAssertEqual(command, "get")
            return nil
        })
        for client in [absent, failing] {
            let levels = await client.brightness([UUID()])
            let night = await client.nightShift()
            let brightnessSet = await client.setBrightness(42, UUID(), 0.1)
            let nightSet = await client.setNightShift(42, false)
            XCTAssertTrue(levels.isEmpty)
            XCTAssertNil(night)
            XCTAssertFalse(brightnessSet)
            XCTAssertFalse(nightSet)
        }
        let menuOpened = await absent.openMenu(42)
        XCTAssertFalse(menuOpened)
    }
}
