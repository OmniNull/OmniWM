// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum CLICompletionCatalog {
    private static let subscribeFlags = ["--all", "--no-send-initial", "--reconnect"]
    private static let watchFlags = ["--all", "--no-send-initial", "--reconnect", "--exec"]

    static var subscribeTokens: [String] {
        sortedUnique(subscriptionNames + subscribeFlags)
    }

    static var watchTokens: [String] {
        sortedUnique(subscriptionNames + watchFlags)
    }

    static var topLevelCommands: [String] {
        [
            "ping",
            "version",
            "help",
            "completion",
            "command",
            "query",
            "rule",
            "capture",
            "workspace",
            "window",
            "subscribe",
            "watch"
        ]
    }

    static var queryNames: [String] {
        sortedUnique(IPCAutomationManifest.queryDescriptors.map(\.name.rawValue))
    }

    private static var subscriptionNames: [String] {
        IPCSubscriptionChannel.allCases.map(\.rawValue)
    }

    static var ruleActionNames: [String] {
        IPCAutomationManifest.ruleActionDescriptors.map(\.name.rawValue)
    }

    static var ruleApplyFlags: [String] {
        IPCAutomationManifest.ruleActionDescriptor(for: .apply)?.options.map(\.flag) ?? []
    }

    static var ruleDefinitionFlags: [String] {
        IPCAutomationManifest.ruleDefinitionOptionDescriptors.map(\.flag)
    }

    static var captureActionNames: [String] {
        IPCAutomationManifest.captureActionDescriptors.map(\.name.rawValue)
    }

    static var captureProfiles: [String] {
        [IPCCaptureProfile.trace.rawValue, IPCCaptureProfile.performance.rawValue]
    }

    static var workspaceActionNames: [String] {
        IPCAutomationManifest.workspaceActionDescriptors.map(\.name.rawValue)
    }

    static var workspaceMoveActionName: String {
        IPCWorkspaceActionName.moveToMonitor.rawValue
    }

    static var workspaceMoveDirections: [String] {
        literalValues(for: .direction) ?? []
    }

    static var workspaceMoveOptionalFlags: [String] {
        IPCAutomationManifest.workspaceActionDescriptors
            .first { $0.name == .moveToMonitor }?
            .optionalFlags ?? []
    }

    static var windowActionNames: [String] {
        sortedUnique(IPCAutomationManifest.windowActionDescriptors.map(\.name.rawValue) + ["mark"])
    }

    static var windowMarkActionNames: [String] {
        IPCAutomationManifest.windowMarkActionDescriptors.map(\.name.rawValue)
    }

    static var windowMarkListFlags: [String] {
        ["--json"]
    }

    static var commandFirstWords: [String] {
        sortedUnique(IPCAutomationManifest.commandDescriptors.compactMap { $0.commandWords.first })
    }

    static var commandSlotThreeSuggestionsByFirst: [String: [String]] {
        var map: [String: Set<String>] = [:]

        for descriptor in IPCAutomationManifest.commandDescriptors {
            guard let first = descriptor.commandWords.first else { continue }
            if descriptor.commandWords.count > 1 {
                map[first, default: []].insert(descriptor.commandWords[1])
            } else if let literals = literalValues(for: descriptor.arguments.first?.kind) {
                map[first, default: []].formUnion(literals)
            }
        }

        return map.mapValues { Array($0).sorted() }
    }

    static var commandSlotFourSuggestionsByPath: [String: [String]] {
        commandArgumentSuggestionsByPath(argumentIndex: 0, commandWordCount: 2)
    }

    static var commandSlotFourFallbackByFirst: [String: [String]] {
        var map: [String: Set<String>] = [:]
        for descriptor in IPCAutomationManifest.commandDescriptors where descriptor.commandWords.count == 1 {
            guard descriptor.arguments.count > 1,
                  let literals = literalValues(for: descriptor.arguments[1].kind),
                  let first = descriptor.commandWords.first
            else {
                continue
            }
            map[first, default: []].formUnion(literals)
        }
        return map.mapValues { Array($0).sorted() }
    }

    static var commandSlotFiveSuggestionsByPath: [String: [String]] {
        commandArgumentSuggestionsByPath(argumentIndex: 1, commandWordCount: 2)
    }

    private static func commandArgumentSuggestionsByPath(
        argumentIndex: Int,
        commandWordCount: Int
    ) -> [String: [String]] {
        var map: [String: Set<String>] = [:]
        for descriptor in IPCAutomationManifest.commandDescriptors
            where descriptor.commandWords.count == commandWordCount
        {
            guard descriptor.arguments.count > argumentIndex,
                  let literals = literalValues(for: descriptor.arguments[argumentIndex].kind)
            else {
                continue
            }
            map[pathKey(descriptor.commandWords), default: []].formUnion(literals)
        }
        return map.mapValues { Array($0).sorted() }
    }

    static var queryFlagsByName: [String: [String]] {
        var map: [String: [String]] = [:]
        for descriptor in IPCAutomationManifest.queryDescriptors {
            let flags = sortedUnique(selectorFlags(for: descriptor) + (descriptor.fields.isEmpty ? [] : ["--fields"]))
            map[descriptor.name.rawValue] = flags
        }
        return map
    }

    static var queryFieldsByName: [String: [String]] {
        Dictionary(
            uniqueKeysWithValues: IPCAutomationManifest.queryDescriptors.map { descriptor in
                (descriptor.name.rawValue, descriptor.fields)
            }
        )
    }

    static var valueFlags: [String] {
        let selectors = IPCQuerySelectorName.allCases.filter(\.expectsValue).map(\.flag)
        let ruleOptions = IPCAutomationManifest.ruleActionDescriptors.flatMap(\.options)
            .filter { $0.valuePlaceholder != nil }.map(\.flag)
        return sortedUnique(["--format", "--fields"] + selectors + ruleOptions)
    }

    static var flagValuesByName: [String: [String]] {
        var values = ["--format": CLIOutputFormat.allCases.map(\.rawValue)]
        for option in IPCAutomationManifest.ruleDefinitionOptionDescriptors {
            guard let placeholder = option.valuePlaceholder, placeholder.contains("|") else { continue }
            values[option.flag] = placeholder.dropFirst().dropLast().split(separator: "|").map(String.init)
        }
        return values
    }

    private static func selectorFlags(for descriptor: IPCQueryDescriptor) -> [String] {
        descriptor.selectors.map(\.name.flag)
    }

    private static func literalValues(for kind: IPCCommandArgumentKind?) -> [String]? {
        guard let kind else { return nil }
        switch kind {
        case .direction:
            return ["left", "right", "up", "down"]
        case .layout:
            return ["default", "niri", "dwindle"]
        case .resizeAxis:
            return ["horizontal", "vertical"]
        case .resizeOperation:
            return ["grow", "shrink"]
        case .scratchpadIndex:
            return IPCScratchpadSlots.range.map(String.init)
        case .workspaceNumber,
             .columnIndex,
             .windowIndex,
             .sizeChange:
            return nil
        }
    }

    private static func pathKey(_ words: [String]) -> String {
        words.joined(separator: " ")
    }

    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}
