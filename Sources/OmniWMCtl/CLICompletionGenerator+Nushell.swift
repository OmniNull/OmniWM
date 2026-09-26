// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension CLICompletionGenerator {
    static func nushellScript() -> String {
        let lists = [
            "topLevelCommands": Catalog.topLevelCommands,
            "queryNames": Catalog.queryNames,
            "commandFirstWords": Catalog.commandFirstWords,
            "ruleActionNames": Catalog.ruleActionNames,
            "ruleDefinitionFlags": Catalog.ruleDefinitionFlags,
            "ruleApplyFlags": Catalog.ruleApplyFlags,
            "captureActionNames": Catalog.captureActionNames,
            "captureProfiles": Catalog.captureProfiles,
            "subscribeTokens": Catalog.subscribeTokens,
            "watchTokens": Catalog.watchTokens,
            "workspaceActionNames": Catalog.workspaceActionNames,
            "workspaceMoveDirections": Catalog.workspaceMoveDirections,
            "workspaceMoveOptionalFlags": Catalog.workspaceMoveOptionalFlags,
            "windowActionNames": Catalog.windowActionNames,
            "windowMarkActionNames": Catalog.windowMarkActionNames,
            "windowMarkListFlags": Catalog.windowMarkListFlags,
            "shellNames": CLIShell.allCases.map(\.rawValue),
            "valueFlags": Catalog.valueFlags
        ]
        let maps = [
            "queryFieldsByName": Catalog.queryFieldsByName,
            "queryFlagsByName": Catalog.queryFlagsByName,
            "commandSlotThreeSuggestionsByFirst": Catalog.commandSlotThreeSuggestionsByFirst,
            "commandSlotFourSuggestionsByPath": Catalog.commandSlotFourSuggestionsByPath,
            "commandSlotFourFallbackByFirst": Catalog.commandSlotFourFallbackByFirst,
            "commandSlotFiveSuggestionsByPath": Catalog.commandSlotFiveSuggestionsByPath,
            "flagValuesByName": Catalog.flagValuesByName
        ]
        var values = lists.mapValues(nushellList)
        for (name, map) in maps {
            values[name] = "{\n" + map.keys.sorted().map { key in
                "    \(nushellString(key)): \(nushellList(map[key] ?? []))"
            }.joined(separator: "\n") + "\n}"
        }
        values["workspaceMoveActionName"] = nushellString(Catalog.workspaceMoveActionName)
        return renderTemplate(PackageResources.completion_nu, values: values)
    }

    private static func nushellList(_ values: [String]) -> String {
        "[" + Set(values).sorted().map(nushellString).joined(separator: " ") + "]"
    }

    static func nushellString(_ value: String) -> String {
        "\"" + value.unicodeScalars.map { scalar in
            switch scalar {
            case "\\": "\\\\"
            case "\"": "\\\""
            case "\n": "\\n"
            case "\r": "\\r"
            case "\t": "\\t"
            case _ where scalar.value < 0x20: "\\u{\(String(scalar.value, radix: 16))}"
            default: String(scalar)
            }
        }.joined() + "\""
    }
}
