// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class ConfigScriptDefinitionsTests: XCTestCase {
    private let resourceName = "omniwm-config.d.luau"
    private let regenerationCommand =
        "OMNIWM_REGENERATE_CONFIG_DEFS=1 ~/.swiftly/bin/swift test --arch arm64 --scratch-path .build " +
        "--filter ConfigScriptDefinitionsTests/testGeneratedDefinitions"

    private func union(_ words: [String]) -> String {
        words.map(\.debugDescription).joined(separator: " | ")
    }

    private func commandDefinitions() throws -> String {
        var overloads: [String] = []
        for command in IPCAutomationManifest.commandDescriptors {
            let firstPositiveIndex = "1"
            let sample = command.commandWords + command.arguments
                .map { $0.kind.literalValues?.first ?? firstPositiveIndex }
            let request = try XCTUnwrap(IPCCommandRequest(commandWords: sample), command.path)
            XCTAssertEqual(request.name, command.name, command.path)
            _ = try XCTUnwrap(HotkeyCommand(direct: request), command.path)
            var parameters = command.commandWords.enumerated().map { index, word in
                let name = index == 0 ? "command" : "word\(index + 1)"
                return "\(name): \(word.debugDescription)"
            }
            parameters += command.arguments.map { argument in
                let name = argument.kind.rawValue.replacingOccurrences(of: "-", with: "_")
                let type = argument.kind.literalValues.map(union) ?? "string"
                return "\(name): \(type)"
            }
            overloads.append("{ read cmd: (\(parameters.joined(separator: ", "))) -> ConfigAction }")
        }
        return overloads.joined(separator: "\n    & ")
    }

    private func renderedDefinitions() throws -> String {
        let fields = ConfigScriptRuleField.allCases.map { field in
            let type = switch field.kind {
            case .string,
                 .uuid: "string"
            case .layout: "(\(union(IPCRuleLayout.allCases.map(\.rawValue))))"
            case .boolean: "boolean"
            case .number,
                 .integer: "number"
            }
            return "    \(field.rawValue): \(type)?,"
        }
        return try """
        -- SPDX-License-Identifier: GPL-2.0-only
        -- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

        declare extern type ConfigAction with
        end

        export type ConfigRule = {
        \(fields.joined(separator: "\n"))
        }

        export type ConfigCommands =
            \(commandDefinitions())

        declare omniwm: ConfigCommands & {
            read keymap: { read set: (chord: string, action: ConfigAction, options: { modeKey: string? }?) -> () },
            read rule: (rule: ConfigRule) -> (),
        }

        """
    }

    func testGeneratedDefinitions() throws {
        let expected = try Data(renderedDefinitions().utf8)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/OmniWM/Resources").appendingPathComponent(resourceName)
        if ProcessInfo.processInfo.environment["OMNIWM_REGENERATE_CONFIG_DEFS"] == "1" {
            try expected.write(to: source, options: .atomic)
            return
        }
        XCTAssertEqual(try Data(contentsOf: source), expected, regenerationCommand)
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("OmniWM_OmniWM.bundle")))
        let resource = try XCTUnwrap(bundle.url(forResource: resourceName, withExtension: nil))
        XCTAssertEqual(try Data(contentsOf: resource), expected, regenerationCommand)
    }

    func testSupportedOverloadsAndNativeRuleFields() throws {
        let definitions = try renderedDefinitions()
        XCTAssertTrue(definitions.contains(#"{ read cmd: (command: "focus", word2: "previous") -> ConfigAction }"#))
        let directions = union(IPCDirection.allCases.map(\.rawValue))
        XCTAssertTrue(definitions
            .contains("{ read cmd: (command: \"focus\", direction: \(directions)) -> ConfigAction }"))
        XCTAssertTrue(definitions.contains(#"{ read cmd: (command: "open-command-palette") -> ConfigAction }"#))
        XCTAssertTrue(definitions.contains(#"command: "open-command-palette", palette_mode: "#))
        XCTAssertTrue(definitions.contains(#"{ read cmd: (command: "rescue-offscreen-windows") -> ConfigAction }"#))
        XCTAssertTrue(definitions.contains("options: { modeKey: string? }?"))
        let switcherDirections = union(IPCWindowSwitcherDirection.allCases.map(\.rawValue))
        let scopes = union(IPCWindowSwitcherScope.allCases.map(\.rawValue))
        let switcher = "{ read cmd: (command: \"window-switcher\", switcher_direction: \(switcherDirections)"
        XCTAssertTrue(definitions.contains("\(switcher)) -> ConfigAction }"))
        XCTAssertTrue(definitions.contains("\(switcher), switcher_scope: \(scopes)) -> ConfigAction }"))
        XCTAssertTrue(definitions
            .contains(#"{ read cmd: (command: "set-container-primary-span", size_change: string) -> ConfigAction }"#))
        let nativeFields = Mirror(reflecting: AppRule(bundleId: "")).children.compactMap(\.label)
        XCTAssertEqual(Set(ConfigScriptRuleField.allCases.map(\.rawValue)), Set(nativeFields))
    }
}
