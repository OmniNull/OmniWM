// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC
import XCTest

final class IPCCommandBoundaryTests: XCTestCase {
    func testCommandDeclarationAndDescriptorOrderRemainStable() throws {
        XCTAssertEqual(IPCCommandName.allCases.map(\.rawValue), try baselineOrder("declaration-order"))
        XCTAssertEqual(
            IPCAutomationManifest.commandDescriptors.map(\.name.rawValue),
            try baselineOrder("descriptor-order")
        )
    }

    func testArgumentFreeCommandsRejectCLIArgumentsButIgnoreJSONArgumentContent() throws {
        for descriptor in IPCAutomationManifest.commandDescriptors where descriptor.arguments.isEmpty {
            XCTAssertThrowsError(try IPCCommandRequest(name: descriptor.name, argumentValues: [.integer(1)])) { error in
                XCTAssertEqual(error as? IPCCommandRequestConstructionError, .invalidArgumentCount)
            }
            let expected = try IPCCommandRequest(name: descriptor.name)
            for arguments in ["null", "{}", "[]", "1", #""unexpected""#, #"{"unexpected":true}"#] {
                let json = #"{"name":"\#(descriptor.name.rawValue)","arguments":\#(arguments)}"#
                XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: Data(json.utf8)), expected)
            }
        }
    }

    func testPayloadCommandsKeepCLIArgumentCountAndTypeErrors() {
        for descriptor in IPCAutomationManifest.commandDescriptors where !descriptor.arguments.isEmpty {
            let arguments = descriptor.arguments.map { argument($0.kind) }
            for invalid in [[], arguments + [.integer(1)]] {
                XCTAssertThrowsError(try IPCCommandRequest(name: descriptor.name, argumentValues: invalid)) { error in
                    XCTAssertEqual(error as? IPCCommandRequestConstructionError, .invalidArgumentType)
                }
            }
            for index in arguments.indices {
                var invalid = arguments
                if case .direction = arguments[index] {
                    invalid[index] = .integer(1)
                } else {
                    invalid[index] = .direction(.left)
                }
                XCTAssertThrowsError(try IPCCommandRequest(name: descriptor.name, argumentValues: invalid)) { error in
                    XCTAssertEqual(error as? IPCCommandRequestConstructionError, .invalidArgumentType)
                }
            }
        }
    }

    func testPayloadCommandsKeepMissingNullAndIncorrectArgumentPaths() throws {
        let payloads: [(name: String, firstField: String)] = [
            ("focus", "direction"), ("switch-workspace", "workspaceNumber"),
            ("switch-workspace-slot", "slotNumber"), ("focus-column", "columnIndex"),
            ("scratchpad-assign", "scratchpadIndex"), ("focus-window-in-column", "windowIndex"),
            ("move-to-workspace-on-monitor", "workspaceNumber"), ("set-workspace-layout", "layout"),
            ("open-command-palette-mode", "mode"),
            ("resize", "axis"), ("resize-focused", "operation"), ("set-container-primary-span", "change")
        ]
        for payload in payloads {
            try assertFailure(#"{"name":"\#(payload.name)"}"#, kind: "keyNotFound", subject: "arguments", path: [])
            try assertFailure(
                #"{"name":"\#(payload.name)","arguments":{}}"#,
                kind: "keyNotFound", subject: payload.firstField, path: ["arguments"]
            )
            try assertFailure(
                #"{"name":"\#(payload.name)","arguments":null}"#,
                kind: "valueNotFound", path: ["arguments"]
            )
            try assertFailure(
                #"{"name":"\#(payload.name)","arguments":false}"#,
                kind: "typeMismatch", path: ["arguments"]
            )
        }
    }

    func testNameAndNestedValuesKeepDecodingFailureTypesAndPaths() throws {
        try assertFailure(#"{}"#, kind: "keyNotFound", subject: "name", path: [])
        try assertFailure(#"{"name":null}"#, kind: "valueNotFound", subject: "String", path: ["name"])
        try assertFailure(#"{"name":3}"#, kind: "typeMismatch", subject: "String", path: ["name"])
        try assertFailure(#"{"name":"unknown-command"}"#, kind: "dataCorrupted", path: ["name"])
        try assertFailure(
            #"{"name":"focus","arguments":{"direction":3}}"#,
            kind: "typeMismatch", subject: "String", path: ["arguments", "direction"]
        )
        try assertFailure(
            #"{"name":"focus","arguments":{"direction":"unknown"}}"#,
            kind: "dataCorrupted", path: ["arguments", "direction"]
        )
        try assertFailure(
            #"{"name":"focus-column","arguments":{"columnIndex":"1"}}"#,
            kind: "typeMismatch", subject: "Int", path: ["arguments", "columnIndex"]
        )
        try assertFailure(
            #"{"name":"resize","arguments":{"axis":"horizontal"}}"#,
            kind: "keyNotFound", subject: "operation", path: ["arguments"]
        )
        try assertFailure(
            #"{"name":"move-to-workspace-on-monitor","arguments":{"workspaceNumber":1}}"#,
            kind: "keyNotFound", subject: "direction", path: ["arguments"]
        )
        try assertFailure(
            #"{"name":"set-container-primary-span","arguments":{"change":{"kind":"set-fixed"}}}"#,
            kind: "keyNotFound", subject: "value", path: ["arguments", "change"]
        )
    }

    private func baselineOrder(_ name: String) throws -> [String] {
        let resources = try XCTUnwrap(Bundle.module.resourceURL)
        let url = resources.appendingPathComponent("Fixtures/IPCCommands/\(name).txt")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func assertFailure(_ json: String, kind: String, subject: String? = nil, path: [String]) throws {
        do {
            _ = try JSONDecoder().decode(IPCCommandRequest.self, from: Data(json.utf8))
            XCTFail("Expected a decoding failure for \(json)")
        } catch let error as DecodingError {
            let actualKind: String
            let actualSubject: String?
            let context: DecodingError.Context
            switch error {
            case let .keyNotFound(key, errorContext):
                actualKind = "keyNotFound"
                actualSubject = key.stringValue
                context = errorContext
            case let .typeMismatch(type, errorContext):
                actualKind = "typeMismatch"
                actualSubject = String(describing: type)
                context = errorContext
            case let .valueNotFound(type, errorContext):
                actualKind = "valueNotFound"
                actualSubject = String(describing: type)
                context = errorContext
            case let .dataCorrupted(errorContext):
                actualKind = "dataCorrupted"
                actualSubject = nil
                context = errorContext
            @unknown default:
                throw error
            }
            XCTAssertEqual(actualKind, kind, json)
            XCTAssertEqual(context.codingPath.map(\.stringValue), path, json)
            if let subject {
                XCTAssertEqual(actualSubject, subject, json)
            }
        }
    }

    private func argument(_ kind: IPCCommandArgumentKind) -> IPCCommandArgumentValue {
        switch kind {
        case .direction:
            .direction(.left)
        case .workspaceNumber,
             .columnIndex,
             .windowIndex,
             .scratchpadIndex:
            .integer(1)
        case .layout:
            .layout(.niri)
        case .paletteMode:
            .paletteMode(.clipboard)
        case .resizeAxis:
            .resizeAxis(.horizontal)
        case .resizeOperation:
            .resizeOperation(.grow)
        case .sizeChange:
            .sizeChange(.setFixed(100))
        }
    }
}
