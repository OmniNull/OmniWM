// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum CLICompletionGenerator {
    typealias Catalog = CLICompletionCatalog

    static func script(for shell: CLIShell) -> String {
        switch shell {
        case .zsh:
            zshScript()
        case .bash:
            bashScript()
        case .fish:
            fishScript()
        case .nu:
            nushellScript()
        }
    }

    private static func zshScript() -> String {
        renderTemplate(PackageResources.completion_zsh, values: [
            "shellNames": shellWords(CLIShell.allCases.map(\.rawValue)),
            "topLevelCommands": shellWords(Catalog.topLevelCommands),
            "queryNames": shellWords(Catalog.queryNames),
            "queryFieldsByName": renderZshCase(map: Catalog.queryFieldsByName),
            "queryFlagsByName": renderZshCase(map: Catalog.queryFlagsByName),
            "commandFirstWords": shellWords(Catalog.commandFirstWords),
            "commandSlotThreeSuggestionsByFirst": renderZshCase(map: Catalog.commandSlotThreeSuggestionsByFirst),
            "commandSlotFourSuggestionsByPath": renderZshCase(map: Catalog.commandSlotFourSuggestionsByPath),
            "commandSlotFourFallbackByFirst": renderZshCase(map: Catalog.commandSlotFourFallbackByFirst),
            "commandSlotFiveSuggestionsByPath": renderZshCase(map: Catalog.commandSlotFiveSuggestionsByPath),
            "ruleActionNames": shellWords(Catalog.ruleActionNames),
            "ruleDefinitionFlags": shellWords(Catalog.ruleDefinitionFlags),
            "ruleApplyFlags": shellWords(Catalog.ruleApplyFlags),
            "captureActionNames": shellWords(Catalog.captureActionNames),
            "captureProfiles": shellWords(Catalog.captureProfiles),
            "subscribeTokens": shellWords(Catalog.subscribeTokens),
            "watchTokens": shellWords(Catalog.watchTokens),
            "workspaceActionNames": shellWords(Catalog.workspaceActionNames),
            "workspaceMoveActionName": Catalog.workspaceMoveActionName,
            "workspaceMoveDirections": shellWords(Catalog.workspaceMoveDirections),
            "workspaceMoveOptionalFlags": shellWords(Catalog.workspaceMoveOptionalFlags),
            "windowActionNames": shellWords(Catalog.windowActionNames),
            "windowMarkActionNames": shellWords(Catalog.windowMarkActionNames),
            "windowMarkListFlags": shellWords(Catalog.windowMarkListFlags)
        ])
    }

    private static func bashScript() -> String {
        renderTemplate(PackageResources.completion_bash, values: [
            "shellNames": shellWords(CLIShell.allCases.map(\.rawValue)),
            "topLevelCommands": shellWords(Catalog.topLevelCommands),
            "queryNames": shellWords(Catalog.queryNames),
            "queryFieldsByName": renderBashCase(map: Catalog.queryFieldsByName),
            "queryFlagsByName": renderBashCase(map: Catalog.queryFlagsByName),
            "commandFirstWords": shellWords(Catalog.commandFirstWords),
            "commandSlotThreeSuggestionsByFirst": renderBashCase(map: Catalog.commandSlotThreeSuggestionsByFirst),
            "commandSlotFourSuggestionsByPath": renderBashCase(map: Catalog.commandSlotFourSuggestionsByPath),
            "commandSlotFourFallbackByFirst": renderBashCase(map: Catalog.commandSlotFourFallbackByFirst),
            "commandSlotFiveSuggestionsByPath": renderBashCase(map: Catalog.commandSlotFiveSuggestionsByPath),
            "ruleActionNames": shellWords(Catalog.ruleActionNames),
            "ruleDefinitionFlags": shellWords(Catalog.ruleDefinitionFlags),
            "ruleApplyFlags": shellWords(Catalog.ruleApplyFlags),
            "captureActionNames": shellWords(Catalog.captureActionNames),
            "captureProfiles": shellWords(Catalog.captureProfiles),
            "subscribeTokens": shellWords(Catalog.subscribeTokens),
            "watchTokens": shellWords(Catalog.watchTokens),
            "workspaceActionNames": shellWords(Catalog.workspaceActionNames),
            "workspaceMoveActionName": Catalog.workspaceMoveActionName,
            "workspaceMoveDirections": shellWords(Catalog.workspaceMoveDirections),
            "workspaceMoveOptionalFlags": shellWords(Catalog.workspaceMoveOptionalFlags),
            "windowActionNames": shellWords(Catalog.windowActionNames),
            "windowMarkActionNames": shellWords(Catalog.windowMarkActionNames),
            "windowMarkListFlags": shellWords(Catalog.windowMarkListFlags)
        ])
    }

    private static func fishScript() -> String {
        let query = "__fish_seen_subcommand_from query"
        let command = "__fish_seen_subcommand_from command"
        let rule = "__fish_seen_subcommand_from rule"
        let capture = "__fish_seen_subcommand_from capture"
        let workspace = "__fish_seen_subcommand_from workspace"
        let moveWorkspace = "\(workspace); and __fish_seen_subcommand_from \(Catalog.workspaceMoveActionName)"
        return renderTemplate(PackageResources.completion_fish, values: [
            "workspaceMoveActionName": Catalog.workspaceMoveActionName,
            "baseLines": fishCompletions(Catalog.topLevelCommands, when: "__fish_use_subcommand"),
            "queryLines": fishCompletions(Catalog.queryNames, when: query),
            "queryFlagLines": fishCases(Catalog.queryFlagsByName, when: query),
            "queryFieldLines": fishCases(
                Catalog.queryFieldsByName,
                when: query,
                suffix: "; and __omniwmctl_prev_arg_is --fields"
            ),
            "commandRootLines": fishCompletions(Catalog.commandFirstWords, when: command),
            "commandNestedLines": fishCases(Catalog.commandSlotThreeSuggestionsByFirst, when: command),
            "commandPathArgumentLines": fishCommandPaths(Catalog.commandSlotFourSuggestionsByPath),
            "commandFallbackLines": fishCases(Catalog.commandSlotFourFallbackByFirst, when: command),
            "commandSecondArgumentLines": fishCommandPaths(Catalog.commandSlotFiveSuggestionsByPath),
            "ruleLines": fishCompletions(Catalog.ruleActionNames, when: rule),
            "ruleDefinitionLines": fishRuleDefinitions(),
            "ruleApplyLines": fishCompletions(
                Catalog.ruleApplyFlags,
                when: "\(rule); and __fish_seen_subcommand_from apply"
            ),
            "captureActionLines": fishChoiceCompletions(Catalog.captureActionNames, when: capture),
            "captureProfileLines": fishChoiceCompletions(
                Catalog.captureProfiles,
                when: "\(capture); and __fish_seen_subcommand_from start"
            ),
            "subscribeLines": fishCompletions(Catalog.subscribeTokens, when: "__fish_seen_subcommand_from subscribe"),
            "watchLines": fishCompletions(Catalog.watchTokens, when: "__fish_seen_subcommand_from watch"),
            "workspaceLines": fishChoiceCompletions(Catalog.workspaceActionNames, when: workspace),
            "workspaceMoveDirectionLines": fishCompletions(
                Catalog.workspaceMoveDirections,
                when: "\(moveWorkspace); and __omniwmctl_workspace_positionals_are 1"
            ),
            "workspaceMoveFlagLines": fishWorkspaceMoveFlags(when: moveWorkspace),
            "windowLines": fishCompletions(Catalog.windowActionNames, when: "__fish_seen_subcommand_from window"),
            "windowMarkActionLines": fishWindowMarkActionLines(),
            "windowMarkListFlagLines": fishWindowMarkListFlagLines(),
            "shellLines": fishCompletions(
                CLIShell.allCases.map(\.rawValue),
                when: "__fish_seen_subcommand_from completion"
            )
        ])
    }

    private static func fishCompletion(_ token: String, when condition: String) -> String {
        "complete -c omniwmctl -f -n '\(condition)' -a '\(token)'"
    }

    private static func fishCompletions(_ tokens: [String], when condition: String) -> String {
        tokens.map { fishCompletion($0, when: condition) }.joined(separator: "\n")
    }

    private static func fishChoiceCompletions(_ tokens: [String], when condition: String) -> String {
        fishCompletions(tokens, when: "\(condition); and not __fish_seen_subcommand_from \(shellWords(tokens))")
    }

    private static func fishCases(_ map: [String: [String]], when condition: String, suffix: String = "") -> String {
        map.flatMap { name, tokens in
            tokens.map { fishCompletion($0, when: "\(condition); and __fish_seen_subcommand_from \(name)\(suffix)") }
        }
        .sorted()
        .joined(separator: "\n")
    }

    private static func fishCommandPaths(_ map: [String: [String]]) -> String {
        map.flatMap { path, tokens in
            let words = path.split(separator: " ")
            guard words.count == 2 else { return [String]() }
            let condition = "__fish_seen_subcommand_from command; and __fish_seen_subcommand_from \(words[0]); and __fish_seen_subcommand_from \(words[1])"
            return tokens.map { fishCompletion($0, when: condition) }
        }
        .sorted()
        .joined(separator: "\n")
    }

    private static func fishRuleDefinitions() -> String {
        Catalog.ruleDefinitionFlags.flatMap { flag in
            ["add", "replace"].map { action in
                fishCompletion(
                    flag,
                    when: "__fish_seen_subcommand_from rule; and __fish_seen_subcommand_from \(action)"
                )
            }
        }
        .joined(separator: "\n")
    }

    private static func fishWorkspaceMoveFlags(when condition: String) -> String {
        Catalog.workspaceMoveOptionalFlags.map { flag in
            fishCompletion(
                flag,
                when: "\(condition); and __omniwmctl_workspace_positionals_at_most 2; and not __omniwmctl_has_arg \(flag)"
            )
        }
        .joined(separator: "\n")
    }

    private static func fishWindowMarkActionLines() -> String {
        fishCompletions(
            Catalog.windowMarkActionNames,
            when: "__fish_seen_subcommand_from window; and __fish_seen_subcommand_from mark"
        )
    }

    private static func fishWindowMarkListFlagLines() -> String {
        fishCompletions(
            Catalog.windowMarkListFlags,
            when: "__fish_seen_subcommand_from window; and __fish_seen_subcommand_from mark; and __fish_seen_subcommand_from list"
        )
    }

    static func renderTemplate(_ bytes: [UInt8], values: [String: String]) -> String {
        let template = String(decoding: bytes, as: UTF8.self)
        var result = ""
        result.reserveCapacity(template.utf8.count)
        var position = template.startIndex
        while let opening = template.range(of: "#{{", range: position ..< template.endIndex) {
            result.append(contentsOf: template[position ..< opening.lowerBound])
            guard let closing = template.range(of: "}}", range: opening.upperBound ..< template.endIndex),
                  let value = values[String(template[opening.upperBound ..< closing.lowerBound])]
            else {
                preconditionFailure("Invalid completion template variable")
            }
            result.append(contentsOf: value)
            position = closing.upperBound
        }
        result.append(contentsOf: template[position...])
        return result
    }

    private static func renderZshCase(map: [String: [String]]) -> String {
        map.keys.sorted().map { key in
            """
            \(quotedCasePattern(key)))
                            suggestions="\(shellWords(map[key] ?? []))"
                            ;;
            """
        }
        .joined(separator: "\n                  ")
    }

    private static func renderBashCase(map: [String: [String]]) -> String {
        map.keys.sorted().map { key in
            """
            \(quotedCasePattern(key)))
                  suggestions="\(shellWords(map[key] ?? []))"
                  ;;
            """
        }
        .joined(separator: "\n                ")
    }

    private static func quotedCasePattern(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func shellWords(_ words: [String]) -> String {
        Array(Set(words)).sorted().joined(separator: " ")
    }
}
