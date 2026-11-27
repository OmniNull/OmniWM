// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMAutomation
@testable import OmniWMIPC
import XCTest

final class IPCFocusCommandContractTests: XCTestCase {
    func testEveryFocusCommandMatchesTheExistingNameConstructionAndWireContract() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(Self.fixtures.map(\.command.name), IPCFocusCommandName.allCases)

        for fixture in Self.fixtures {
            let command = try IPCFocusCommand(name: fixture.command.name, arguments: .init(values: fixture.arguments))
            XCTAssertEqual(command, fixture.command)
            XCTAssertEqual(command.name.rawValue, fixture.request.name.rawValue)
            let expectedData = try encoder.encode(fixture.request)
            XCTAssertEqual(try encoder.encode(FocusEnvelope(command: command)), expectedData)
            XCTAssertEqual(try JSONDecoder().decode(FocusEnvelope.self, from: expectedData).command, command)
        }
    }

    func testFocusPayloadValuesPreserveDirectionsAndUnconstrainedIntegerRange() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for direction: IPCDirection in [.left, .right, .up, .down] {
            let command = try IPCFocusCommand(name: .spatial, arguments: .init(values: [.direction(direction)]))
            let data = try encoder.encode(IPCCommandRequest(.focus(.spatial(direction: direction))))
            XCTAssertEqual(try encoder.encode(FocusEnvelope(command: command)), data)
            XCTAssertEqual(try JSONDecoder().decode(FocusEnvelope.self, from: data).command, command)
        }
        for value in [Int.min, -1, 0, 1, Int.max] {
            for fixture in [
                Fixture(
                    command: .column(columnIndex: value),
                    request: .init(.focus(.column(columnIndex: value))),
                    arguments: [.integer(value)]
                ),
                Fixture(
                    command: .windowInColumn(windowIndex: value),
                    request: .init(.focus(.windowInColumn(windowIndex: value))),
                    arguments: [.integer(value)]
                )
            ] {
                let command = try IPCFocusCommand(
                    name: fixture.command.name,
                    arguments: .init(values: fixture.arguments)
                )
                let data = try encoder.encode(fixture.request)
                XCTAssertEqual(try encoder.encode(FocusEnvelope(command: command)), data)
                XCTAssertEqual(try JSONDecoder().decode(FocusEnvelope.self, from: data).command, command)
            }
        }
    }

    func testArgumentFreeFocusCommandsIgnoreJSONArgumentsAndRejectCLIArguments() throws {
        for fixture in Self.fixtures where fixture.arguments.isEmpty {
            for arguments in [nil, "null", "{}", "[]", "1", #""unexpected""#, #"{"unexpected":true}"#] {
                let suffix = arguments.map { #", "arguments":\#($0)"# } ?? ""
                let data = Data(#"{"name":"\#(fixture.command.name.rawValue)"\#(suffix)}"#.utf8)
                XCTAssertEqual(try JSONDecoder().decode(FocusEnvelope.self, from: data).command, fixture.command)
                XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), fixture.request)
            }
            for arguments: [IPCCommandArgumentValue] in [[.integer(1)], [.direction(.left), .integer(2)]] {
                XCTAssertThrowsError(try IPCFocusCommand(
                    name: fixture.command.name,
                    arguments: .init(values: arguments)
                )) {
                    XCTAssertEqual($0 as? IPCCommandRequestConstructionError, .invalidArgumentCount)
                }
            }
        }
    }

    func testPayloadFocusCommandsPreserveCLIArgumentCountAndTypeFailures() {
        for fixture in Self.fixtures where !fixture.arguments.isEmpty {
            let wrongType: IPCCommandArgumentValue = fixture.command.name == .spatial ? .integer(1) : .direction(.left)
            for arguments in [[], fixture.arguments + fixture.arguments, [wrongType]] {
                XCTAssertThrowsError(try IPCFocusCommand(
                    name: fixture.command.name,
                    arguments: .init(values: arguments)
                )) {
                    XCTAssertEqual($0 as? IPCCommandRequestConstructionError, .invalidArgumentType)
                }
                XCTAssertThrowsError(try IPCCommandRequest(name: fixture.request.name, argumentValues: arguments)) {
                    XCTAssertEqual($0 as? IPCCommandRequestConstructionError, .invalidArgumentType)
                }
            }
        }
    }

    func testPayloadFocusCommandsPreserveDecodingErrorKindsSubjectsAndPaths() throws {
        let payloadFields: [(IPCFocusCommandName, String, String)] = [
            (.spatial, "direction", "String"),
            (.windowInColumn, "windowIndex", "Int"),
            (.column, "columnIndex", "Int")
        ]
        for (name, field, valueType) in payloadFields {
            let cases: [(String?, String, String?, [String])] = [
                (nil, "keyNotFound", "arguments", []),
                ("null", "valueNotFound", "Dictionary<String, Any>", ["arguments"]),
                ("{}", "keyNotFound", field, ["arguments"]),
                ("false", "typeMismatch", "Dictionary<String, Any>", ["arguments"]),
                ("[]", "typeMismatch", "Dictionary<String, Any>", ["arguments"]),
                (#"{"\#(field)":null}"#, "valueNotFound", valueType, ["arguments", field]),
                (#"{"\#(field)":false}"#, "typeMismatch", valueType, ["arguments", field]),
                (
                    #"{"\#(field)":"unknown"}"#,
                    name == .spatial ? "dataCorrupted" : "typeMismatch",
                    name == .spatial ? nil : "Int",
                    ["arguments", field]
                )
            ]
            for (arguments, kind, subject, path) in cases {
                let suffix = arguments.map { #", "arguments":\#($0)"# } ?? ""
                let data = Data(#"{"name":"\#(name.rawValue)"\#(suffix)}"#.utf8)
                let failure = try decodingFailure(IPCCommandRequest.self, data: data)
                let label = String(decoding: data, as: UTF8.self)
                XCTAssertEqual(failure.kind, kind, label)
                XCTAssertEqual(failure.subject, subject, label)
                XCTAssertEqual(failure.path, path, label)
            }
        }
    }

    private func decodingFailure<Value: Decodable>(_ type: Value.Type, data: Data) throws -> DecodingFailure {
        do {
            _ = try JSONDecoder().decode(type, from: data)
            XCTFail("Expected decoding to fail for \(String(decoding: data, as: UTF8.self))")
            throw NSError(domain: "IPCFocusCommandContractTests", code: 1)
        } catch let error as DecodingError {
            switch error {
            case let .keyNotFound(key, context):
                return DecodingFailure(kind: "keyNotFound", subject: key.stringValue, context: context)
            case let .typeMismatch(type, context):
                return DecodingFailure(kind: "typeMismatch", subject: String(describing: type), context: context)
            case let .valueNotFound(type, context):
                return DecodingFailure(kind: "valueNotFound", subject: String(describing: type), context: context)
            case let .dataCorrupted(context):
                return DecodingFailure(kind: "dataCorrupted", subject: nil, context: context)
            @unknown default:
                throw error
            }
        }
    }

    private struct DecodingFailure: Equatable {
        let kind: String
        let subject: String?
        let path: [String]
        let description: String

        init(kind: String, subject: String?, context: DecodingError.Context) {
            self.kind = kind
            self.subject = subject
            path = context.codingPath.map(\.stringValue)
            description = context.debugDescription
        }
    }

    private struct FocusEnvelope: Codable {
        let command: IPCFocusCommand

        init(command: IPCFocusCommand) {
            self.command = command
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: IPCCommandCodingKeys.self)
            let rawName = try container.decode(String.self, forKey: .name)
            let name = try XCTUnwrap(IPCFocusCommandName(rawValue: rawName))
            let arguments = try container.commandArguments(for: .focus(name))
            command = try IPCFocusCommand(name: name, arguments: .init(values: arguments))
        }

        func encode(to encoder: Encoder) throws {
            var writer = try IPCCommandArgumentWriter(encoder: encoder, name: command.name.rawValue)
            try command.encodeArguments(to: &writer)
        }
    }

    private struct Fixture {
        let command: IPCFocusCommand
        let request: IPCCommandRequest
        var arguments: [IPCCommandArgumentValue] = []
    }

    private static let fixtures = [
        Fixture(
            command: .spatial(direction: .left),
            request: .init(.focus(.spatial(direction: .left))),
            arguments: [.direction(.left)]
        ),
        Fixture(command: .previous, request: .init(.focus(.previous))),
        Fixture(command: .downOrLeft, request: .init(.focus(.downOrLeft))),
        Fixture(command: .upOrRight, request: .init(.focus(.upOrRight))),
        Fixture(
            command: .windowInColumn(windowIndex: 2),
            request: .init(.focus(.windowInColumn(windowIndex: 2))),
            arguments: [.integer(2)]
        ),
        Fixture(command: .windowTop, request: .init(.focus(.windowTop))),
        Fixture(command: .windowBottom, request: .init(.focus(.windowBottom))),
        Fixture(command: .windowDownOrTop, request: .init(.focus(.windowDownOrTop))),
        Fixture(command: .windowUpOrBottom, request: .init(.focus(.windowUpOrBottom))),
        Fixture(command: .windowOrWorkspaceDown, request: .init(.focus(.windowOrWorkspaceDown))),
        Fixture(command: .windowOrWorkspaceUp, request: .init(.focus(.windowOrWorkspaceUp))),
        Fixture(
            command: .column(columnIndex: 2),
            request: .init(.focus(.column(columnIndex: 2))),
            arguments: [.integer(2)]
        ),
        Fixture(command: .columnFirst, request: .init(.focus(.columnFirst))),
        Fixture(command: .columnLast, request: .init(.focus(.columnLast))),
        Fixture(command: .centerColumn, request: .init(.focus(.centerColumn))),
        Fixture(command: .centerVisibleColumns, request: .init(.focus(.centerVisibleColumns)))
    ]
}
