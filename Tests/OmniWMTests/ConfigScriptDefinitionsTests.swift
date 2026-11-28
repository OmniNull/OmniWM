// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMAutomation
import OmniWMIPC
import XCTest

final class ConfigScriptDefinitionsTests: XCTestCase {
    private let resourceName = "omniwm-config.d.luau"
    private let regenerationCommand =
        "OMNIWM_REGENERATE_CONFIG_DEFS=1 ~/.swiftly/bin/swift test --build-system swiftbuild --arch arm64 " +
        "--filter ConfigScriptDefinitionsTests/testGeneratedDefinitions"

    private func union(_ words: [String]) -> String {
        words.map(\.debugDescription).joined(separator: " | ")
    }

    private struct DuplicateCommandMember: LocalizedError {
        let member: String

        var errorDescription: String? {
            "Duplicate command member '\(member)'."
        }
    }

    private func commandDefinitions(_ inventory: [ConfigScriptCommandParser.Group]) throws -> String {
        var members = Set<String>()
        return try inventory.map { group in
            guard members.insert(group.member).inserted else {
                throw DuplicateCommandMember(member: group.member)
            }
            let signatures = group.forms.map { command in
                var parameters = command.commandWords.dropFirst().enumerated().map { index, word in
                    "word\(index + 2): \(word.debugDescription)"
                }
                parameters += command.arguments.map { argument in
                    let name = argument.rawValue.replacingOccurrences(of: "-", with: "_")
                    let type = argument.literalValues.map(union) ?? "string"
                    return "\(name): \(argument.acceptsConfigInteger ? "\(type) | number" : type)"
                }
                return "(\(parameters.joined(separator: ", "))) -> ConfigAction"
            }
            let type = if signatures.count == 1 {
                signatures[0]
            } else {
                signatures.map { "(\($0))" }.joined(separator: "\n        & ")
            }
            return "    read \(group.member): \(type),"
        }.joined(separator: "\n")
    }

    private func renderedCommandGroups(_ inventory: [ConfigScriptCommandParser.Group]) -> String {
        let entries = inventory.map { group in
            "    CommandGroup{\(group.member.debugDescription), \(group.word.utf8.count)},"
        }
        return """
        // SPDX-License-Identifier: GPL-2.0-only
        // Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

        #pragma once

        constexpr std::array commandGroups{
        \(entries.joined(separator: "\n"))
        };

        """
    }

    private func dispatchDefinitions() -> String {
        var overloads = ["{ read dispatch: (action: ConfigAction) -> () }"]
        for action in IPCWindowActionForm.all {
            var parameters = ["kind: \"window\"", "action: \(action.name.rawValue.debugDescription)"]
            let hasSelector = ConfigScriptWindowActionName.shared(action.name).integerSelector != nil
            for argument in action.arguments {
                let parameter = switch argument {
                case .windowID: "id: string"
                case .direction: "direction: \(union(IPCDirection.allCases.map(\.rawValue)))"
                case .cycleDirection: "direction: \(union(IPCCycleDirection.allCases.map(\.rawValue)))"
                case .workspace,
                     .number,
                     .sizeChange:
                    "\(argument.rawValue.replacingOccurrences(of: "-", with: "_")): \(hasSelector ? "string | number" : "string")"
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
        overloads.append(
            "{ read dispatch: (kind: \"window\", action: \(placement), id: string, slot: string | number) -> () }"
        )
        let frame = ConfigScriptWindowActionName.setFloatingFrame.rawValue.debugDescription
        overloads.append(
            "{ read dispatch: (kind: \"window\", action: \(frame), id: string, frame: ConfigFloatingFrame) -> () }"
        )
        let gather = ConfigScriptGatherRequest.action.debugDescription
        let reach = union(ConfigScriptGatherRequest.reaches.map(\.word))
        overloads
            .append("{ read dispatch: (kind: \"window\", action: \(gather), ids: {string}, from: (\(reach))?) -> () }")
        overloads.append("{ read dispatch: (kind: \"dwindle\", action: \"replace\", tree: ConfigDwindleTree) -> () }")
        let marks = union(WindowMarkAction.Kind.allCases.map(\.rawValue))
        overloads.append("{ read dispatch: (kind: \"mark\", action: \(marks), name: string) -> () }")
        let workspace = { (name: ConfigScriptWorkspaceRequest.Name, rest: String) in
            "{ read dispatch: (kind: \"workspace\", action: \(name.rawValue.debugDescription), "
                + "target: ConfigWorkspaceSelector\(rest)) -> () }"
        }
        let directions = union(IPCDirection.allCases.map(\.rawValue))
        overloads.append(workspace(.focusName, ""))
        overloads.append(workspace(.moveToMonitor, ", direction: \(directions), options: { read force: boolean? }?"))
        overloads.append(workspace(.rename, ", displayName: string"))
        overloads.append(workspace(.scroll, ", offset: number, options: { read animate: boolean? }?"))
        overloads.append(
            "{ read dispatch: (kind: \"rule\", action: \"apply\", target: ConfigRuleApplyTarget?) -> () }"
        )
        overloads.append(
            "{ read dispatch: (kind: \"shell\", action: \"set\", key: string, value: string) -> () }"
        )
        overloads.append(
            "{ read dispatch: (kind: \"shell\", action: \"unset\", key: string) -> () }"
        )
        overloads.append(
            "{ read dispatch: (kind: \"shell\", action: \"toggle\", widgetOrDrawer: string) -> () }"
        )
        overloads.append(
            "{ read dispatch: (kind: \"shell\", action: \"trigger\", widget: string, name: string, value: string?) -> () }"
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
        export type ConfigWorkspaceSelector = string | number | { read id: string }
        export type ConfigRuleApplyTarget = { read windowId: string } | { read pid: number }
        export type ConfigFloatingFrame = { read x: number?, read y: number?, read width: number?, read height: number? }
        """
    }

    private let hostDefinitions = """
    export type ConfigActionBuilders = {
        read openApp: (bundleId: string) -> ConfigAction,
        read launch: (argv: { string }) -> ConfigAction,
        read notify: (text: string) -> ConfigAction,
    }

    export type ConfigStoreValue = boolean | number | string | { string }
    export type ConfigStore = {
        read get: (key: string) -> ConfigStoreValue?,
        read set: (key: string, value: ConfigStoreValue?) -> (),
    } & { read clear: (key: string) -> () } & { read clear: () -> () }

    declare omniwm: ConfigDispatch & ConfigEvents & ConfigTimers & {
        read cmd: ConfigCommands,
        read command: (name: string, callback: ConfigFunction, options: ConfigReadOptions?) -> (),
        read act: ConfigActionBuilders,
        read openApp: (bundleId: string) -> (),
        read launch: (argv: { string }) -> (),
        read notify: (text: string) -> (),
        read keymap: ConfigKeymap,
        read log: (...any) -> (),
        read rule: (rule: ConfigRule) -> (),
        read store: ConfigStore,
    }
    """

    private func renderedDefinitions(
        _ inventory: [ConfigScriptCommandParser.Group] = ConfigScriptCommandParser.inventory()
    ) throws -> String {
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

        export type ConfigCommands = {
        \(commandDefinitions(inventory))
        }

        export type ConfigDispatch =
            \(dispatchDefinitions())
        export type ConfigKeymap =
            { read set: (chord: string, action: ConfigAction, options: { read modeKey: string?, read mode: string?, read repeatWhileHeld: boolean?, read reads: nil }?) -> () }
            & { read set: (chord: string, callback: ConfigFunction, options: { read modeKey: string?, read mode: string?, read repeatWhileHeld: boolean?, read reads: { read [number]: ConfigRead }? }?) -> () }
            & { read mode: (name: string) -> ConfigAction }
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
            let (name, fields): (String, String?) = switch kind {
            case .workspaceActive: ("ConfigWorkspaceEvent", named)
            case .windowActive: ("ConfigWindowEvent", "{ read id: string?, read bundleId: string? }")
            case .monitorFocused: ("ConfigMonitorEvent", named)
            case .keybindsSubmap: ("ConfigSubmapEvent", "{ read name: string }")
            case .configReloaded: ("ConfigReloadEvent", "{}")
            case .layoutChanged: ("ConfigLookups", nil)
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
            if let fields {
                let declaration = "export type \(name) = ConfigLookups & \(fields)"
                if payloads.last != declaration { payloads.append(declaration) }
            }
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
        let inventory = ConfigScriptCommandParser.inventory()
        let expected = try Data(renderedDefinitions(inventory).utf8)
        let memberTable = Data(renderedCommandGroups(inventory).utf8)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/OmniWM/Resources").appendingPathComponent(resourceName)
        let membersURL = root.appendingPathComponent("Sources/OmniWMScriptHost/ConfigCommandGroups.h")
        let idsURL = root.appendingPathComponent("Sources/OmniWM/Core/Config/SettingsFieldID.swift")
        let ids = try Data(SettingsSchemaRecorder.inventory().fieldIDSource.utf8)
        if ProcessInfo.processInfo.environment["OMNIWM_REGENERATE_CONFIG_DEFS"] == "1" {
            try ids.write(to: idsURL, options: .atomic)
            try expected.write(to: source, options: .atomic)
            try memberTable.write(to: membersURL, options: .atomic)
            return
        }
        XCTAssertEqual(try Data(contentsOf: idsURL), ids, regenerationCommand)
        XCTAssertEqual(try Data(contentsOf: source), expected, regenerationCommand)
        XCTAssertEqual(try Data(contentsOf: membersURL), memberTable, regenerationCommand)
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(url: products.appendingPathComponent("OmniWM_OmniWM.bundle")))
        let resource = try XCTUnwrap(bundle.url(forResource: resourceName, withExtension: nil))
        XCTAssertEqual(try Data(contentsOf: resource), expected, regenerationCommand)
    }

    func testCommandGenerationRejectsDuplicateMemberKeys() throws {
        let group = try XCTUnwrap(ConfigScriptCommandParser.inventory().first)
        XCTAssertThrowsError(try renderedDefinitions([group, group])) { error in
            XCTAssertEqual((error as? DuplicateCommandMember)?.member, group.member)
        }
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
        for signature in ["openApp: (bundleId: string)", "launch: (argv: { string })", "notify: (text: string)"] {
            XCTAssertTrue(builders.contains("read \(signature) -> ConfigAction"))
            XCTAssertTrue(effects.contains("read \(signature) -> ()"))
        }
    }

    func testSupportedOverloadsAndNativeRuleFields() throws {
        let inventory = ConfigScriptCommandParser.inventory()
        let definitions = try renderedDefinitions(inventory)
        let members = try commandDefinitions(inventory).components(separatedBy: "\n    read ")
        func member(_ name: String) throws -> String {
            try XCTUnwrap(members.first { $0.hasPrefix("\(name): ") }, name)
        }
        XCTAssertTrue(definitions.contains("read cmd: ConfigCommands"))
        let focus = try member("focus")
        XCTAssertTrue(focus.contains(#"(word2: "previous") -> ConfigAction"#))
        let directions = union(IPCDirection.allCases.map(\.rawValue))
        XCTAssertTrue(focus.contains("(direction: \(directions)) -> ConfigAction"))
        let palette = try member("openCommandPalette")
        XCTAssertTrue(palette.contains("(() -> ConfigAction)"))
        XCTAssertTrue(palette.contains("& ((palette_mode: "))
        XCTAssertEqual(try member("rescueOffscreenWindows"), "rescueOffscreenWindows: () -> ConfigAction,")
        let keyOptions = "read modeKey: string?, read mode: string?, read repeatWhileHeld: boolean?"
        XCTAssertTrue(definitions.contains("action: ConfigAction, options: { \(keyOptions), read reads: nil }?"))
        XCTAssertTrue(definitions.contains(
            "callback: ConfigFunction, options: { \(keyOptions), read reads: { read [number]: ConfigRead }? }?"
        ))
        XCTAssertTrue(definitions.contains("{ read mode: (name: string) -> ConfigAction }"))
        XCTAssertTrue(definitions
            .contains("command: (name: string, callback: ConfigFunction, options: ConfigReadOptions?) -> ()"))
        XCTAssertTrue(definitions.contains("read dispatch: (action: ConfigAction) -> ()"))
        XCTAssertTrue(definitions.contains(#"read dispatch: (kind: "window", action: "focus", id: string) -> ()"#))
        XCTAssertTrue(definitions.contains("optionsForCallback: ConfigReadOptions) -> ConfigTimer"))
        XCTAssertTrue(definitions.contains("read log: (...any) -> ()"))
        let switcherDirections = union(IPCWindowSwitcherDirection.allCases.map(\.rawValue))
        let scopes = union(IPCWindowSwitcherScope.allCases.map(\.rawValue))
        let direction = "switcher_direction: \(switcherDirections)"
        let switcher = try member("windowSwitcher")
        XCTAssertTrue(switcher.contains("((\(direction)) -> ConfigAction)"))
        XCTAssertTrue(switcher.contains("& ((\(direction), switcher_scope: \(scopes)) -> ConfigAction)"))
        XCTAssertEqual(
            try member("setContainerPrimarySpan"),
            "setContainerPrimarySpan: (size_change: string) -> ConfigAction,"
        )
        let nativeFields = Mirror(reflecting: AppRule(bundleId: "")).children.compactMap(\.label)
        XCTAssertEqual(Set(ConfigScriptRuleField.allCases.map(\.rawValue)), Set(nativeFields))
    }
}

private let lookupDefinitions = """
export type ConfigRead = "workspaceWindows" | "windows" | "workspaces" | "monitors" | "placement" | "focusTarget" | "dwindle" | "marks" | "apps" | "rules" | "workspaceBar" | "shell" | "frames" | "columns" | "details"
export type ConfigReadOptions = { reads: { ConfigRead } }
export type ConfigRect = { read x: number, read y: number, read width: number, read height: number }
export type ConfigWindowRow = {
    read id: string, read bundleId: string?, read title: string?, read workspace: string,
    read monitor: string?, read floating: boolean, read fullscreen: ("native" | "omniwm")?, read minimized: boolean,
    read frame: ConfigRect?, read column: number?,
    read pid: number?, read windowNumber: number?, read app: string?, read mode: ("tiling" | "floating")?,
    read layoutReason: ("standard" | "native-fullscreen")?, read manualOverride: ("force-tile" | "force-float")?,
    read visible: boolean?, read appHidden: boolean?, read scratchpad: boolean?, read scratchpadSlot: number?,
    read hiddenReason: ("workspace-inactive" | "tab-inactive" | "layout-transient" | "scratchpad")?, read focusRank: number?,
    read columnSpan: number?, read columnPosition: number?, read columnSize: number?,
}
export type ConfigEdges = { read left: number, read right: number, read top: number, read bottom: number }
export type ConfigWorkspaceColumn = {
    read mode: "normal" | "tabbed", read viewport: "before" | "intersecting" | "after",
}
export type ConfigWorkspaceRow = {
    read id: string, read name: string, read monitor: string?,
    read displayName: string?, read number: number?, read layout: ("niri" | "dwindle")?,
    read focused: boolean?, read visible: boolean?, read current: boolean?,
    read windowCounts: { read total: number, read tiled: number, read floating: number, read scratchpad: number }?,
    read focusedWindow: string?, read scrollOffset: number?, read columns: { read [number]: ConfigWorkspaceColumn }?,
}
export type ConfigMonitorRow = {
    read id: string, read name: string, read frame: ConfigRect?, read visibleFrame: ConfigRect?,
    read main: boolean?, read current: boolean?, read uuid: string?,
    read hasNotch: boolean?, read notch: { read left: number, read right: number }?,
    read orientation: ("horizontal" | "vertical")?, read innerGap: number?, read outerGaps: ConfigEdges?,
    read fullscreenUsesOuterGaps: boolean?, read menuBarHeight: number?,
    read barFrames: { read [number]: ConfigRect }?, read reservedInsets: ConfigEdges?,
}
export type ConfigPlacement = { read workspace: string, read display: string?, read column: nil }
    | {
        read workspace: string, read display: string?, read column: number, read columns: number,
        read members: { read [number]: string }, read vertical: boolean,
    }
export type ConfigFocusTarget = { read id: string, read nativeFullscreen: boolean }
export type ConfigDwindleNode = { read kind: "split", read orientation: "horizontal" | "vertical", read ratio: number }
    | { read kind: "leaf", read members: { read [number]: string }, read active: number }
export type ConfigDwindleTree = {
    read workspaceId: string, read revision: string, read preselect: ("left" | "right" | "up" | "down")?,
    read nodes: { read [number]: ConfigDwindleNode },
}
export type ConfigMarkRow = {
    read name: string, read id: string, read workspaceId: string, read workspace: string,
    read appName: string?, read bundleId: string?, read title: string?,
}
export type ConfigAppRow = {
    read bundleId: string, read name: string?, read windowWidth: number?, read windowHeight: number?,
}
export type ConfigRuleRow = {
    read id: string, read position: number, read bundleId: string,
    read appNameSubstring: string?, read titleSubstring: string?, read titleRegex: string?,
    read axRole: string?, read axSubrole: string?, read layout: "auto" | "tile" | "float",
    read assignToWorkspace: string?, read assignToWorkspaceForAllWindows: boolean?,
    read initialContainerPrimarySpan: number?, read minWidth: number?, read minHeight: number?, read scratchpad: number?,
    read specificity: number, read isValid: boolean, read invalidRegexMessage: string?,
    read validationMessages: { read [number]: string },
}
export type ConfigBarWindow = { read id: string, read title: string?, read focused: boolean }
export type ConfigBarApp = {
    read id: string, read bundleId: string?, read name: string?, read focused: boolean, read windowCount: number,
    read windows: { read [number]: ConfigBarWindow },
}
export type ConfigBarWorkspace = {
    read id: string, read rawName: string, read displayName: string, read number: number?, read focused: boolean,
    read windows: { read [number]: ConfigBarApp },
}
export type ConfigBarScratchpad = {
    read index: number, read label: string?, read visible: boolean, read windows: { read [number]: ConfigBarApp },
}
export type ConfigBarDisplay = {
    read id: string, read name: string, read enabled: boolean, read visible: boolean, read showLabels: boolean,
    read backgroundOpacity: number, read barHeight: number,
    read scratchpads: { read [number]: ConfigBarScratchpad }, read workspaces: { read [number]: ConfigBarWorkspace },
}
export type ConfigWorkspaceBar = { read interactionDisplay: string?, read displays: { read [number]: ConfigBarDisplay } }
export type ConfigShellWidget = {
    read name: string, read state: "loading" | "loaded" | "failed" | "fallback",
    read placements: { read [number]: string }, read source: string, read error: string?,
}
export type ConfigShellReport = {
    read profile: string, read widgets: { read [number]: ConfigShellWidget }, read problems: { read [number]: string },
}
export type ConfigLookups = {
    read workspaceWindows: { read [number]: ConfigWindowRow }?,
    read windows: { read [number]: ConfigWindowRow }?,
    read workspaces: { read [number]: ConfigWorkspaceRow }?,
    read monitors: { read [number]: ConfigMonitorRow }?,
    read placement: ConfigPlacement?,
    read focusTarget: ConfigFocusTarget?,
    read dwindle: ConfigDwindleTree?,
    read marks: { read [number]: ConfigMarkRow }?,
    read apps: { read [number]: ConfigAppRow }?,
    read rules: { read [number]: ConfigRuleRow }?,
    read workspaceBar: ConfigWorkspaceBar?,
    read shell: ConfigShellReport?,
    read truncated: {
        read workspaceWindows: boolean?, read windows: boolean?, read workspaces: boolean?, read monitors: boolean?,
        read placement: boolean?, read focusTarget: boolean?, read dwindle: boolean?, read marks: boolean?,
        read apps: boolean?, read rules: boolean?, read workspaceBar: boolean?, read shell: boolean?,
        read details: {
            read workspaceWindows: boolean?, read windows: boolean?, read workspaces: boolean?, read monitors: boolean?,
        }?,
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
