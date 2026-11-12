// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

enum CLICompletionSelector {
    private typealias Catalog = CLICompletionCatalog

    static func suggestions(words: [String], filterPrefix: Bool = true) -> [String] {
        guard words.count > 1, let prefix = words.last else { return [] }
        let valueFlags = Catalog.valueFlags
        var positionals: [String] = []
        var flags: Set<String> = []
        var valueFlag: String?
        for token in words.dropFirst().dropLast() {
            if valueFlag != nil {
                valueFlag = nil
            } else if token == "--exec" {
                return []
            } else if valueFlags.contains(token) {
                flags.insert(token)
                valueFlag = token
            } else if token.hasPrefix("--") {
                flags.insert(token)
            } else {
                positionals.append(token)
            }
        }
        let family = positionals.first ?? ""
        let action = positionals.dropFirst().first ?? ""
        let completingFields = valueFlag == "--fields" && family == "query"
        var choices: [String]
        if completingFields {
            choices = Catalog.queryFieldsByName[action] ?? []
        } else if let valueFlag {
            choices = Catalog.flagValuesByName[valueFlag] ?? []
        } else {
            choices = candidates(positionals: positionals)
            if prefix.hasPrefix("--") { choices += ["--format", "--json"] }
        }
        if completingFields || (valueFlag == nil && ["subscribe", "watch"].contains(family) && prefix.contains(",")) {
            return commaSuggestions(choices, prefix: prefix)
        }
        return Set(choices.filter { !flags.contains($0) && (!filterPrefix || $0.hasPrefix(prefix)) }).sorted()
    }

    private static func candidates(positionals: [String]) -> [String] {
        guard let family = positionals.first else { return Catalog.topLevelCommands }
        let action = positionals.dropFirst().first ?? ""
        switch family {
        case "completion":
            return positionals.count == 1 ? CLIShell.allCases.map(\.rawValue) : []
        case "query":
            return positionals.count == 1 ? Catalog.queryNames : Catalog.queryFlagsByName[action] ?? []
        case "command":
            return commandCandidates(positionals: positionals, action: action)
        case "rule":
            if positionals.count == 1 { return Catalog.ruleActionNames }
            switch action {
            case "add",
                 "replace": return Catalog.ruleDefinitionFlags
            case "apply": return Catalog.ruleApplyFlags
            default: return []
            }
        case "capture":
            if positionals.count == 1 { return Catalog.captureActionNames }
            return positionals.count == 2 && action == "start" ? Catalog.captureProfiles : []
        case "workspace":
            return workspaceCandidates(positionals: positionals, action: action)
        case "window":
            return windowCandidates(positionals: positionals, action: action)
        case "shell":
            return positionals.count == 1 ? Catalog.shellActionNames : []
        case "subscribe":
            return Catalog.subscribeTokens
        case "watch":
            return Catalog.watchTokens
        default:
            return []
        }
    }

    private static func commandCandidates(positionals: [String], action: String) -> [String] {
        let path = positionals.dropFirst().prefix(2).joined(separator: " ")
        switch positionals.count {
        case 1: return Catalog.commandFirstWords
        case 2: return Catalog.commandSlotThreeSuggestionsByFirst[action] ?? []
        case 3:
            return Catalog.commandSlotFourSuggestionsByPath[path]
                ?? Catalog.commandSlotFourFallbackByFirst[action] ?? []
        case 4: return Catalog.commandSlotFiveSuggestionsByPath[path] ?? []
        default: return []
        }
    }

    private static func workspaceCandidates(positionals: [String], action: String) -> [String] {
        if positionals.count == 1 { return Catalog.workspaceActionNames }
        guard action == Catalog.workspaceMoveActionName, positionals.count <= 4 else { return [] }
        let directions = positionals.count == 3 ? Catalog.workspaceMoveDirections : []
        return directions + Catalog.workspaceMoveOptionalFlags
    }

    private static func windowCandidates(positionals: [String], action: String) -> [String] {
        if positionals.count == 1 { return Catalog.windowActionNames }
        if action == "gather" { return [Catalog.windowGatherReachFlag] }
        guard action == "mark" else { return [] }
        if positionals.count == 2 { return Catalog.windowMarkActionNames }
        return positionals.count == 3 && positionals.last == "list" ? Catalog.windowMarkListFlags : []
    }

    private static func commaSuggestions(_ choices: [String], prefix: String) -> [String] {
        let parts = prefix.split(separator: ",", omittingEmptySubsequences: false)
        let selected = parts.dropLast()
        let partial = parts.last ?? ""
        let leading = selected.isEmpty ? "" : selected.joined(separator: ",") + ","
        return Set(choices.compactMap { choice in
            guard !choice.hasPrefix("--"), !selected.contains(Substring(choice)), choice.hasPrefix(partial) else {
                return nil
            }
            return leading + choice
        }).sorted()
    }
}
