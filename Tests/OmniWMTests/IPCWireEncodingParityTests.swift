// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation
import OmniWMIPC
import XCTest

final class IPCWireEncodingParityTests: XCTestCase {
    private struct Fixture: Decodable {
        let name: String
        let kind: String
        let data: Data
    }

    private struct CommandWireRecord: Decodable {
        let words: [String]
        let wire: Data
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
        XCTAssertEqual(requests.count, 376)
        for fixture in requests {
            let request = try IPCWire.decodeRequest(from: fixture.data)
            XCTAssertEqual(try IPCWire.encodeRequestLine(request), try reference(request), fixture.name)
        }
    }

    func testAllCommandRequestsMatchTheRecordedBytes() throws {
        for fixture in try fixtures() where fixture.kind == "request" {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.data) as? [String: Any])
            guard object["kind"] as? String == IPCRequestKind.command.rawValue else { continue }
            let request = try IPCWire.decodeRequest(from: fixture.data)
            var expected = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            expected.append(0x0A)
            XCTAssertEqual(try IPCWire.encodeRequestLine(request), expected, fixture.name)
        }
    }

    func testAllParentCommandFormsMatchTheRecordedWireBytes() throws {
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        let fixture = resources.appendingPathComponent("Fixtures/IPCCommands/command-wire.ndjson")
        let records = try String(contentsOf: fixture, encoding: .utf8)
        let decoder = JSONDecoder()
        var covered = Set<IPCCommandName>()
        var paths: [String] = []
        for line in records.split(separator: "\n") {
            let record = try decoder.decode(CommandWireRecord.self, from: Data(line.utf8))
            let decoded = try IPCWire.decodeRequest(from: record.wire)
            let command = try XCTUnwrap(IPCCommandRequest(commandWords: record.words))
            let request = IPCRequest(id: decoded.id, command: command, authorizationToken: decoded.authorizationToken)
            XCTAssertEqual(try IPCWire.encodeRequestLine(request), record.wire, decoded.id)
            XCTAssertEqual(request, decoded, decoded.id)
            covered.insert(command.name)
            paths.append(decoded.id)
        }
        XCTAssertEqual(covered, Set(IPCCommandName.allCases))
        XCTAssertEqual(paths, IPCAutomationManifest.commandDescriptors.map(\.path))
    }

    func testAllCapabilityCommandDescriptorsMatchTheRecordedBytes() throws {
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        let fixture = resources.appendingPathComponent("Fixtures/IPCCommands/capability-command-descriptors.ndjson")
        let records = try String(contentsOf: fixture, encoding: .utf8)
        let expected = "[" + records.split(separator: "\n").joined(separator: ",") + "]"
        let descriptors = IPCAutomationManifest.commandDescriptors
        XCTAssertEqual(try reference(descriptors), Data((expected + "\n").utf8))

        let capabilities = IPCCapabilitiesQueryResult(
            appVersion: nil, authorizationRequired: true, windowIdScope: "session", queries: [],
            commands: descriptors, captureActions: [], ruleActions: [], workspaceActions: [], windowActions: [],
            windowMarkActions: [], windowGatherActions: [], dwindleActions: [], shellActions: [], subscriptions: []
        )
        let response = IPCResponse.success(
            id: fixture.lastPathComponent, kind: .query, result: IPCResult(capabilities: capabilities)
        )
        XCTAssertNotNil(try IPCWire.encodeResponseLine(response).range(of: Data(("\"commands\":" + expected).utf8)))
    }

    func testHostedAppRequestsEncodeAppIDAndRoundTrip() throws {
        let fixtures: [(name: String, command: IPCCommandRequest)] = [
            ("app-open", .init(.shellAppOpen(appID: "example"))),
            ("app-new-window", .init(.shellAppNewWindow(appID: "example")))
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
            (.init(.windowSwitcher(direction: .next, scope: nil)), ["direction": "next"]),
            (
                .init(.windowSwitcher(direction: .previous, scope: .visibleWorkspaces)),
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
        XCTAssertEqual(messages.count, 265)
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
