// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum CLIRuleParser {
    private static var ruleDefinitionOptionFlags: Set<String> {
        Set(IPCAutomationManifest.ruleDefinitionOptionDescriptors.map(\.flag))
    }

    static func parseRuleRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard let actionToken = arguments.first,
              let action = IPCRuleActionName(rawValue: actionToken)
        else {
            throw CLIParseError.usage(CLIParser.usageText)
        }

        switch action {
        case .add:
            let rule = try parseRuleDefinition(arguments: Array(arguments.dropFirst()))
            return IPCRequest(id: id, rule: .add(rule: rule))
        case .replace:
            guard arguments.count >= 2, UUID(uuidString: arguments[1]) != nil else {
                throw CLIParseError.usage(CLIParser.usageText)
            }
            let rule = try parseRuleDefinition(arguments: Array(arguments.dropFirst(2)))
            return IPCRequest(id: id, rule: .replace(id: arguments[1], rule: rule))
        case .remove:
            guard arguments.count == 2, UUID(uuidString: arguments[1]) != nil else {
                throw CLIParseError.usage(CLIParser.usageText)
            }
            return IPCRequest(id: id, rule: .remove(id: arguments[1]))
        case .move:
            guard arguments.count == 3,
                  UUID(uuidString: arguments[1]) != nil
            else {
                throw CLIParseError.usage(CLIParser.usageText)
            }
            return IPCRequest(
                id: id,
                rule: .move(id: arguments[1], position: try CLIArgumentParser.parsePositiveInteger(arguments[2]))
            )
        case .apply:
            let target = try parseRuleApplyTarget(arguments: Array(arguments.dropFirst()))
            return IPCRequest(id: id, rule: .apply(target: target))
        }
    }

    private static func parseRuleDefinition(arguments: [String]) throws -> IPCRuleDefinition {
        var parsed = CLIRuleDefinitionArguments()
        var seenFlags: Set<String> = []
        var index = 0

        while index < arguments.count {
            let flag = arguments[index]
            guard ruleDefinitionOptionFlags.contains(flag),
                  seenFlags.insert(flag).inserted,
                  index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--")
            else {
                throw CLIParseError.usage(CLIParser.usageText)
            }

            let value = arguments[index + 1]
            try parsed.set(flag: flag, value: value)

            index += 2
        }

        return try parsed.build()
    }

    private static func parseRuleApplyTarget(arguments: [String]) throws -> IPCRuleApplyTarget {
        switch arguments.first {
        case nil:
            return .focused
        case "--focused":
            guard arguments.count == 1 else {
                throw CLIParseError.usage(CLIParser.usageText)
            }
            return .focused
        case "--window":
            guard arguments.count == 2, !arguments[1].hasPrefix("--") else {
                throw CLIParseError.usage(CLIParser.usageText)
            }
            return .window(windowId: arguments[1])
        case "--pid":
            guard arguments.count == 2, !arguments[1].hasPrefix("--") else {
                throw CLIParseError.usage(CLIParser.usageText)
            }
            return .pid(try CLIArgumentParser.parsePID(arguments[1]))
        default:
            throw CLIParseError.usage(CLIParser.usageText)
        }
    }
}

private struct CLIRuleDefinitionArguments {
    private var bundleId: String?
    private var appNameSubstring: String?
    private var titleSubstring: String?
    private var titleRegex: String?
    private var axRole: String?
    private var axSubrole: String?
    private var layout: IPCRuleLayout = .auto
    private var assignToWorkspace: String?
    private var initialContainerPrimarySpan: Double?
    private var minWidth: Double?
    private var minHeight: Double?
    private var scratchpad: Int?

    mutating func set(flag: String, value: String) throws {
        switch flag {
        case "--bundle-id":
            bundleId = value
        case "--app-name-substring":
            appNameSubstring = value
        case "--title-substring":
            titleSubstring = value
        case "--title-regex":
            titleRegex = value
        case "--ax-role":
            axRole = value
        case "--ax-subrole":
            axSubrole = value
        case "--layout":
            guard let parsedLayout = IPCRuleLayout(rawValue: value) else {
                throw CLIParseError.usage(CLIParser.usageText)
            }
            layout = parsedLayout
        case "--assign-to-workspace":
            assignToWorkspace = value
        case "--initial-container-primary-span":
            initialContainerPrimarySpan = try CLIArgumentParser.parseInitialContainerPrimarySpan(value)
        case "--min-width":
            minWidth = try CLIArgumentParser.parsePositiveDouble(value)
        case "--min-height":
            minHeight = try CLIArgumentParser.parsePositiveDouble(value)
        case "--scratchpad":
            scratchpad = try CLIArgumentParser.parseScratchpadIndex(value)
        default:
            throw CLIParseError.usage(CLIParser.usageText)
        }
    }

    func build() throws -> IPCRuleDefinition {
        let definition = IPCRuleDefinition(
            bundleId: bundleId ?? "",
            appNameSubstring: appNameSubstring,
            titleSubstring: titleSubstring,
            titleRegex: titleRegex,
            axRole: axRole,
            axSubrole: axSubrole,
            layout: layout,
            assignToWorkspace: assignToWorkspace,
            initialContainerPrimarySpan: initialContainerPrimarySpan,
            minWidth: minWidth,
            minHeight: minHeight,
            scratchpad: scratchpad
        )

        guard IPCRuleValidator.validate(definition).isValid else {
            throw CLIParseError.usage(CLIParser.usageText)
        }

        return definition
    }
}
