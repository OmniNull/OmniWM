// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC
import XCTest

final class IPCWireEncodingParityTests: XCTestCase {
    private struct Fixture: Decodable {
        let name: String
        let kind: String
        let data: Data
    }

    private struct RandomBits {
        var state: UInt64 = 13013

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
    }

    private func fixtures() throws -> [Fixture] {
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        let url = resources.appendingPathComponent("Fixtures/IPCWireParity/models.json")
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }

    private func reference(_ value: some Encodable, prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    func testAllRequestModelsMatchReference() throws {
        let requests = try fixtures().filter { $0.kind == "request" }
        XCTAssertEqual(requests.count, 365)
        for fixture in requests {
            let request = try IPCWire.decodeRequest(from: fixture.data)
            XCTAssertEqual(try IPCWire.encodeRequestLine(request), try reference(request), fixture.name)
        }
    }

    func testAllResponseAndEventModelsMatchReference() throws {
        let messages = try fixtures().filter { $0.kind != "request" }
        XCTAssertEqual(messages.count, 277)
        for fixture in messages {
            for pretty in [false, true] {
                if fixture.kind == "event" {
                    let event = try IPCWire.decodeEvent(from: fixture.data)
                    XCTAssertEqual(
                        try IPCWire.encodeEventLine(event, prettyPrinted: pretty),
                        try reference(event, prettyPrinted: pretty),
                        fixture.name
                    )
                } else {
                    let response = try IPCWire.decodeResponse(from: fixture.data)
                    XCTAssertEqual(
                        try IPCWire.encodeResponseLine(response, prettyPrinted: pretty),
                        try reference(response, prettyPrinted: pretty),
                        fixture.name
                    )
                }
            }
        }
    }

    func testWindowGatherRequestsMatchReference() throws {
        let payloads: [IPCWindowGatherRequest] = [
            .init(windowIds: ["ow_first", "ow_second"], workspaceTarget: .rawID("3")),
            .init(windowIds: [], workspaceTarget: .displayName("Work / 表")),
            .init(markNames: ["editor / \"表\"", "chat"], workspaceTarget: .rawID("3")),
            .init(markNames: [], workspaceTarget: .displayName("Work / 表"))
        ]
        for payload in payloads {
            for token in ["secret", nil] {
                let request = IPCRequest(id: "gather-parity", windowGather: payload, authorizationToken: token)
                let data = try IPCWire.encodeRequestLine(request)
                XCTAssertEqual(data, try reference(request))
                XCTAssertEqual(try IPCWire.decodeRequest(from: data), request)
            }
        }
    }

    func testWindowGatherResponsesMatchReference() throws {
        let workspace = IPCWorkspaceRef(id: "workspace", rawName: "3", displayName: "Work / 表", number: 3)
        let windows: [IPCWindowGatherWindowResult] = [
            .init(windowId: "ow_first", status: .moved),
            .init(windowId: "ow_second", markName: "editor / \"表\"", status: .unchanged),
            .init(windowId: "ow_third", markName: "alias", status: .refused, reason: .duplicateWindow),
            .init(windowId: nil, markName: "missing", status: .unresolved, reason: .unknownMark),
            .init(windowId: "ow_fourth", status: .blocked, reason: .windowRefused)
        ]
        for outcome in [IPCWindowGatherOutcome.gathered, .unchanged, .refused] {
            for destination in [workspace, nil] {
                let payload = IPCWindowGatherResult(
                    outcome: outcome,
                    workspace: destination,
                    reason: outcome == .refused ? .unknownMark : nil,
                    windows: windows,
                    moved: outcome == .gathered ? ["ow_first", "ow_second"] : [],
                    relayoutWorkspaces: destination.map { [$0] } ?? []
                )
                let response = IPCResponse.success(
                    id: "gather-parity", kind: .windowGather, result: IPCResult(windowGather: payload)
                )
                for pretty in [false, true] {
                    let data = try IPCWire.encodeResponseLine(response, prettyPrinted: pretty)
                    XCTAssertEqual(data, try reference(response, prettyPrinted: pretty))
                    XCTAssertEqual(try IPCWire.decodeResponse(from: data), response)
                }
            }
        }
    }

    func testCapabilitiesKeepGatherAndShellActionsInCustomWriter() throws {
        let payload = IPCCapabilitiesQueryResult(
            appVersion: "test",
            authorizationRequired: true,
            windowIdScope: "session",
            queries: [],
            commands: [],
            captureActions: [],
            ruleActions: [],
            workspaceActions: [],
            windowActions: [],
            windowMarkActions: [],
            windowGatherActions: IPCAutomationManifest.windowGatherActionDescriptors,
            shellActions: IPCAutomationManifest.shellActionDescriptors,
            subscriptions: []
        )
        let response = IPCResponse.success(
            id: "capabilities-parity", kind: .query, result: IPCResult(capabilities: payload)
        )
        for pretty in [false, true] {
            let data = try IPCWire.encodeResponseLine(response, prettyPrinted: pretty)
            XCTAssertEqual(data, try reference(response, prettyPrinted: pretty))
            XCTAssertEqual(try IPCWire.decodeResponse(from: data), response)
        }
    }

    private func numericResponse(_ value: Double) -> IPCResponse {
        .success(
            id: "numeric-parity",
            kind: .query,
            result: IPCResult(displays: IPCDisplaysQueryResult(displays: [IPCDisplayQuerySnapshot(
                id: "display",
                innerGap: value
            )]))
        )
    }

    func testFiniteBinary64ValuesMatchReference() throws {
        var values = [
            0.0, -0.0, 1e-7, 1e-6, 1e-5, 1e15, 1e16, 1e17, 1e20, 1e21,
            0.30000000000000004, Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude
        ]
        var random = RandomBits()
        for _ in 0 ..< 1000 {
            let value = Double(bitPattern: random.next())
            if value.isFinite { values.append(value) }
        }
        for value in values {
            let response = numericResponse(value)
            for pretty in [false, true] {
                XCTAssertEqual(
                    try IPCWire.encodeResponseLine(response, prettyPrinted: pretty),
                    try reference(response, prettyPrinted: pretty),
                    String(value.bitPattern)
                )
            }
        }
    }

    private func failureDescription(_ operation: () throws -> Data) -> String? {
        do {
            _ = try operation()
            XCTFail("Expected encoding failure")
            return nil
        } catch {
            return String(reflecting: error)
        }
    }

    func testNonfiniteFailuresPreserveReferenceDiagnostics() {
        for value in [Double.nan, .infinity, -.infinity] {
            let response = numericResponse(value)
            for pretty in [false, true] {
                XCTAssertEqual(
                    failureDescription { try reference(response, prettyPrinted: pretty) },
                    failureDescription { try IPCWire.encodeResponseLine(response, prettyPrinted: pretty) }
                )
            }
        }
    }

    func testStringsMatchReference() throws {
        let controls = String(String.UnicodeScalarView((0 ..< 32).compactMap(UnicodeScalar.init)))
        let values = [controls, "\"\\/\u{2028}\u{2029} é é 👩🏽‍💻 表 𐀀", "", String(repeating: "a", count: 100_000)]
        for value in values {
            let response = IPCResponse.success(
                id: value,
                kind: .ping,
                result: IPCResult(pong: IPCPingResult(message: value))
            )
            for pretty in [false, true] {
                XCTAssertEqual(
                    try IPCWire.encodeResponseLine(response, prettyPrinted: pretty),
                    try reference(response, prettyPrinted: pretty)
                )
            }
        }
    }
}
