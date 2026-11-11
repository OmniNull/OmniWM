// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
        XCTAssertEqual(requests.count, 372)
        for fixture in requests {
            let request = try IPCWire.decodeRequest(from: fixture.data)
            XCTAssertEqual(try IPCWire.encodeRequestLine(request), try reference(request), fixture.name)
        }
    }

    func testHostedAppRequestsEncodeAppIDAndRoundTrip() throws {
        let fixtures: [(name: String, command: IPCCommandRequest)] = [
            ("app-open", .shellAppOpen(appID: "example")),
            ("app-new-window", .shellAppNewWindow(appID: "example"))
        ]
        for fixture in fixtures {
            let request = IPCRequest(id: fixture.name, command: fixture.command)
            let line = try IPCWire.encodeRequestLine(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
            let payload = try XCTUnwrap(object["payload"] as? [String: Any])
            let arguments = try XCTUnwrap(payload["arguments"] as? [String: String])

            XCTAssertEqual(payload["name"] as? String, fixture.name)
            XCTAssertEqual(arguments, ["appId": "example"])
            XCTAssertEqual(line, try reference(request))
            XCTAssertEqual(try IPCWire.decodeRequest(from: line), request)
        }
    }

    func testWindowSwitcherRequestsEncodeDirectionAndOptionalScope() throws {
        let fixtures: [(command: IPCCommandRequest, arguments: [String: String])] = [
            (.windowSwitcher(direction: .next, scope: nil), ["direction": "next"]),
            (
                .windowSwitcher(direction: .previous, scope: .visibleWorkspaces),
                ["direction": "previous", "scope": "visible-workspaces"]
            )
        ]
        for fixture in fixtures {
            let request = IPCRequest(id: "switcher", command: fixture.command)
            let line = try IPCWire.encodeRequestLine(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
            let payload = try XCTUnwrap(object["payload"] as? [String: Any])

            XCTAssertEqual(payload["name"] as? String, "window-switcher")
            XCTAssertEqual(payload["arguments"] as? [String: String], fixture.arguments)
            XCTAssertEqual(line, try reference(request))
            XCTAssertEqual(try IPCWire.decodeRequest(from: line), request)
        }
    }

    func testAllResponseAndEventModelsMatchReference() throws {
        let messages = try fixtures().filter { $0.kind != "request" }
        XCTAssertEqual(messages.count, 257)
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
