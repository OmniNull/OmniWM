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

    private func dispatchDefinitions() -> String {
        var overloads = ["{ read dispatch: (action: ConfigAction) -> () }"]
        for action in IPCAutomationManifest.windowActionDescriptors {
            var parameters = ["kind: \"window\"", "action: \(action.name.rawValue.debugDescription)"]
            for argument in action.arguments {
                let parameter = switch argument {
                case "opaque-id": "id: string"
                case "direction": "direction: \(union(IPCDirection.allCases.map(\.rawValue)))"
                case "cycle-direction": "direction: \(union(IPCCycleDirection.allCases.map(\.rawValue)))"
                default: "\(argument.replacingOccurrences(of: "-", with: "_")): string"
                }
                parameters.append(parameter)
            }
            overloads.append("{ read dispatch: (\(parameters.joined(separator: ", "))) -> () }")
            if action.name == .moveToWorkspace {
                overloads.append(
                    "{ read dispatch: (kind: \"window\", action: \"move-to-workspace\", id: string, " +
                        "destination: ConfigWindowDestination) -> () }"
                )
            }
            if action.name == .focus {
                overloads.append(
                    "{ read dispatch: (kind: \"window\", action: \"focus\", id: string, check: ConfigFocusCheck) -> () }"
                )
            }
        }
        let placement = ConfigScriptWindowActionName.placeInOwnColumn.rawValue.debugDescription
        overloads.append("{ read dispatch: (kind: \"window\", action: \(placement), id: string, slot: string) -> () }")
        let frame = ConfigScriptWindowActionName.setFloatingFrame.rawValue.debugDescription
        overloads.append(
            "{ read dispatch: (kind: \"window\", action: \(frame), id: string, frame: ConfigFloatingFrame) -> () }"
        )
        return overloads.joined(separator: "\n    & ")
    }

    private var destinationDefinitions: String {
        let direction = union(IPCDirection.allCases.map(\.rawValue))
        return """
        export type ConfigWindowDestination =
            { read display: string, read column: number? }
            | { read neighbor: \(direction), read of: string?, read column: number? }
            | { read neighbor: \(direction), read of: string, read fromEdge: boolean, read column: number? }
        export type ConfigFocusCheck = { read targetOf: string?, read nativeFullscreen: boolean? }
        export type ConfigFloatingFrame = { read x: number?, read y: number?, read width: number?, read height: number? }
        """
    }

    private let hostDefinitions = """
    export type ConfigActionBuilders = {
        read open: (bundleId: string) -> ConfigAction,
        read run: (argv: { string }) -> ConfigAction,
        read notify: (text: string) -> ConfigAction,
    }

    declare omniwm: ConfigCommands & ConfigDispatch & ConfigEvents & ConfigTimers & {
        read command: (name: string, callback: ConfigFunction, options: ConfigReadOptions?) -> (),
        read act: ConfigActionBuilders,
        read open: (bundleId: string) -> (),
        read run: (argv: { string }) -> (),
        read notify: (text: string) -> (),
        read keymap: ConfigKeymap,
        read log: (...any) -> (),
        read rule: (rule: ConfigRule) -> (),
    }
    """

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

        \(SettingsSchemaRecorder.inventory().definition)

        declare extern type ConfigAction with
        end

        export type ConfigRule = {
        \(fields.joined(separator: "\n"))
        }

        \(lookupDefinitions)

        \(destinationDefinitions)

        \(eventDefinitions())

        export type ConfigCommands =
            \(commandDefinitions())

        export type ConfigDispatch =
            \(dispatchDefinitions())
        export type ConfigKeymap =
            { read set: (chord: string, action: ConfigAction, options: { read modeKey: string?, read reads: nil }?) -> () }
            & { read set: (chord: string, callback: ConfigFunction, options: { read modeKey: string?, read reads: { read [number]: ConfigRead }? }?) -> () }
        export type ConfigTimers = { read timer: (options: ConfigTimerOptions, callback: () -> ()) -> ConfigTimer }
            & { read timer: (options: ConfigTimerOptions, callback: ConfigFunction, optionsForCallback: ConfigReadOptions) -> ConfigTimer }

        \(hostDefinitions)

        """
    }

    private func eventDefinitions() -> String {
        var payloads: [String] = []
        let windowEdge = "{ read id: string, read bundleId: string?, read workspaceId: string?, " +
            "read workspaceName: string?, read previousWorkspaceId: string?, read previousWorkspaceName: string?, read missed: number }"
        let workspaceEdge = "{ read id: string, read name: string, read monitorId: string?, " +
            "read monitorName: string?, read previousMonitorId: string?, read previousMonitorName: string?, read missed: number }"
        let monitorEdge = "{ read id: string, read name: string, read frame: ConfigRect, " +
            "read previousFrame: ConfigRect?, read visibleFrame: ConfigRect, read previousVisibleFrame: ConfigRect?, read missed: number }"
        var overloads: [String] = []
        let named = "{ read id: string?, read name: string? }"
        for kind in ConfigScriptEventKind.allCases {
            let (name, fields) = switch kind {
            case .workspaceActive: ("ConfigWorkspaceEvent", named)
            case .windowActive: ("ConfigWindowEvent", "{ read id: string?, read bundleId: string? }")
            case .monitorFocused: ("ConfigMonitorEvent", named)
            case .keybindsSubmap: ("ConfigSubmapEvent", "{ read name: string }")
            case .configReloaded: ("ConfigReloadEvent", "{}")
            case .windowOpen,
                 .windowClose,
                 .windowMoveToWorkspace: ("ConfigWindowEdge", windowEdge)
            case .workspaceCreated,
                 .workspaceRemoved,
                 .workspaceMoveToMonitor: ("ConfigWorkspaceEdge", workspaceEdge)
            case .monitorAdded,
                 .monitorRemoved,
                 .monitorLayoutChanged: ("ConfigMonitorEdge", monitorEdge)
            case .windowTitle: ("ConfigWindowTitle", windowStateFields("title: string"))
            case .windowMinimize: ("ConfigWindowMinimize", windowStateFields("minimized: boolean"))
            case .windowFullscreen: ("ConfigWindowFullscreen", windowStateFields("fullscreen: boolean"))
            case .windowUpdateState: ("ConfigWindowState", windowStateFields("floating: boolean"))
            }
            let declaration = "export type \(name) = ConfigLookups & \(fields)"
            if payloads.last != declaration { payloads.append(declaration) }
            overloads
                .append(
                    "{ read on: (name: \(kind.rawValue.debugDescription), callback: (event: \(name)) -> (), options: ConfigReadOptions?) -> () }"
                )
        }
        return payloads.joined(separator: "\n") + "\n\nexport type ConfigEvents =\n    " +
            overloads.joined(separator: "\n    & ")
    }

    private func windowStateFields(_ field: String) -> String {
        "{ read id: string, read bundleId: string?, read \(field), read missed: number }"
    }

    func testGeneratedDefinitions() throws {
        let expected = try Data(renderedDefinitions().utf8)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/OmniWM/Resources").appendingPathComponent(resourceName)
        let idsURL = root.appendingPathComponent("Sources/OmniWM/Core/Config/SettingsFieldID.swift")
        let ids = try Data(SettingsSchemaRecorder.inventory().fieldIDSource.utf8)
        if ProcessInfo.processInfo.environment["OMNIWM_REGENERATE_CONFIG_DEFS"] == "1" {
            try ids.write(to: idsURL, options: .atomic)
            try expected.write(to: source, options: .atomic)
            return
        }
        XCTAssertEqual(try Data(contentsOf: idsURL), ids, regenerationCommand)
        XCTAssertEqual(try Data(contentsOf: source), expected, regenerationCommand)
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("OmniWM_OmniWM.bundle")))
        let resource = try XCTUnwrap(bundle.url(forResource: resourceName, withExtension: nil))
        XCTAssertEqual(try Data(contentsOf: resource), expected, regenerationCommand)
    }

    func testSettingsInventoryRecordsDefaultedFieldsAndCustomWireForms() throws {
        let shape = try SettingsSchemaRecorder.inventory()
        guard case let .record(root) = shape,
              case let .record(gaps) = root["gaps"]?.shape,
              case let .list(.record(hotkey)) = root["hotkeys"]?.shape,
              case let .alternatives(binding) = hotkey["binding"]?.shape,
              case let .record(palette) = root["commandPalette"]?.shape,
              case let .record(niri) = root["niri"]?.shape,
              case let .alternatives(span) = niri["defaultContainerPrimarySpan"]?.shape
        else {
            return XCTFail("Expected the native settings and shortcut wire shapes")
        }
        XCTAssertNil(root["schemaVersion"])
        XCTAssertEqual(gaps["size"]?.shape, .scalar("number"))
        XCTAssertEqual(gaps["size"]?.hasDefault, true)
        XCTAssertEqual(hotkey["id"]?.optional, false)
        XCTAssertEqual(hotkey["modeKey"]?.optional, true)
        XCTAssertTrue(binding.contains(.scalar("string")))
        XCTAssertTrue(binding.contains { form in
            guard case let .record(fields) = form else { return false }
            return fields["keyCode"]?.shape == .scalar("number")
        })
        XCTAssertEqual(palette["searchedModes"]?.shape, .list(.names(CommandPaletteMode.allCases.map(\.rawValue))))
        XCTAssertTrue(span.contains(.scalar("number")))
        XCTAssertTrue(span.contains(.names(["auto"])))
        XCTAssertTrue(span.contains(.names(["app"])))
    }

    func testOnlyActionBuildersReturnDispatchableValues() throws {
        let definitions = try renderedDefinitions()
        let start = try XCTUnwrap(definitions.range(of: "export type ConfigActionBuilders = {"))
        let host = try XCTUnwrap(definitions.range(of: "declare omniwm:"))
        let builders = definitions[start.upperBound ..< host.lowerBound]
        let effects = definitions[host.upperBound...]
        XCTAssertTrue(effects.contains("read act: ConfigActionBuilders"))
        for signature in ["open: (bundleId: string)", "run: (argv: { string })", "notify: (text: string)"] {
            XCTAssertTrue(builders.contains("read \(signature) -> ConfigAction"))
            XCTAssertTrue(effects.contains("read \(signature) -> ()"))
        }
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
        XCTAssertTrue(definitions
            .contains("action: ConfigAction, options: { read modeKey: string?, read reads: nil }?"))
        XCTAssertTrue(definitions.contains(
            "callback: ConfigFunction, options: { read modeKey: string?, read reads: { read [number]: ConfigRead }? }?"
        ))
        XCTAssertTrue(definitions
            .contains("command: (name: string, callback: ConfigFunction, options: ConfigReadOptions?) -> ()"))
        XCTAssertTrue(definitions.contains("read dispatch: (action: ConfigAction) -> ()"))
        XCTAssertTrue(definitions.contains(#"read dispatch: (kind: "window", action: "focus", id: string) -> ()"#))
        XCTAssertTrue(definitions.contains("optionsForCallback: ConfigReadOptions) -> ConfigTimer"))
        XCTAssertTrue(definitions.contains("read log: (...any) -> ()"))
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

private let lookupDefinitions = """
export type ConfigRead = "workspaceWindows" | "windows" | "workspaces" | "monitors" | "placement" | "focusTarget" | "frames" | "columns"
export type ConfigReadOptions = { reads: { ConfigRead } }
export type ConfigRect = { read x: number, read y: number, read width: number, read height: number }
export type ConfigWindowRow = {
    read id: string, read bundleId: string?, read title: string?, read workspace: string,
    read monitor: string?, read floating: boolean, read fullscreen: ("native" | "omniwm")?, read minimized: boolean,
    read frame: ConfigRect?, read column: number?,
}
export type ConfigWorkspaceRow = { read id: string, read name: string, read monitor: string? }
export type ConfigMonitorRow = { read id: string, read name: string, read frame: ConfigRect?, read visibleFrame: ConfigRect? }
export type ConfigPlacement = { read workspace: string, read display: string?, read column: nil }
    | {
        read workspace: string, read display: string?, read column: number, read columns: number,
        read members: { read [number]: string }, read vertical: boolean,
    }
export type ConfigFocusTarget = { read id: string, read nativeFullscreen: boolean }
export type ConfigLookups = {
    read workspaceWindows: { read [number]: ConfigWindowRow }?,
    read windows: { read [number]: ConfigWindowRow }?,
    read workspaces: { read [number]: ConfigWorkspaceRow }?,
    read monitors: { read [number]: ConfigMonitorRow }?,
    read placement: ConfigPlacement?,
    read focusTarget: ConfigFocusTarget?,
    read truncated: {
        read workspaceWindows: boolean?, read windows: boolean?, read workspaces: boolean?, read monitors: boolean?,
        read placement: boolean?, read focusTarget: boolean?,
    }?,
}
export type ConfigContext = ConfigLookups & {
    read windowId: string?,
    read bundleId: string?,
    read workspace: string?,
    read layout: string?,
}

export type ConfigFunction = (context: ConfigContext) -> ()
export type ConfigTimerOptions = { read afterSeconds: number, read everySeconds: nil } | { read afterSeconds: nil, read everySeconds: number }
export type ConfigTimer = { read cancel: () -> () }
"""
