const omniwmctl_catalog = {
    topLevelCommands: #{{topLevelCommands}}
    queryNames: #{{queryNames}}
    queryFieldsByName: #{{queryFieldsByName}}
    queryFlagsByName: #{{queryFlagsByName}}
    commandFirstWords: #{{commandFirstWords}}
    commandSlotThreeSuggestionsByFirst: #{{commandSlotThreeSuggestionsByFirst}}
    commandSlotFourSuggestionsByPath: #{{commandSlotFourSuggestionsByPath}}
    commandSlotFourFallbackByFirst: #{{commandSlotFourFallbackByFirst}}
    commandSlotFiveSuggestionsByPath: #{{commandSlotFiveSuggestionsByPath}}
    ruleActionNames: #{{ruleActionNames}}
    ruleDefinitionFlags: #{{ruleDefinitionFlags}}
    ruleApplyFlags: #{{ruleApplyFlags}}
    captureActionNames: #{{captureActionNames}}
    captureProfiles: #{{captureProfiles}}
    subscribeTokens: #{{subscribeTokens}}
    watchTokens: #{{watchTokens}}
    workspaceActionNames: #{{workspaceActionNames}}
    workspaceMoveActionName: #{{workspaceMoveActionName}}
    workspaceMoveDirections: #{{workspaceMoveDirections}}
    workspaceMoveOptionalFlags: #{{workspaceMoveOptionalFlags}}
    windowActionNames: #{{windowActionNames}}
    windowMarkActionNames: #{{windowMarkActionNames}}
    windowMarkListFlags: #{{windowMarkListFlags}}
    shellNames: #{{shellNames}}
    valueFlags: #{{valueFlags}}
    flagValuesByName: #{{flagValuesByName}}
}

def omniwmctl_choices [words: list<string>] {
    let catalog = $omniwmctl_catalog
    let count = ($words | length)
    let action = ($words | get -o 1 | default "")
    if $count == 0 { return $catalog.topLevelCommands }
    match $words.0 {
        completion => { if $count == 1 { $catalog.shellNames } else { [] } }
        query => {
            if $count == 1 { $catalog.queryNames } else {
                $catalog.queryFlagsByName | get -o $action | default []
            }
        }
        command => {
            let path = ($words | skip 1 | first 2 | str join " ")
            match $count {
                1 => { $catalog.commandFirstWords }
                2 => { $catalog.commandSlotThreeSuggestionsByFirst | get -o $action | default [] }
                3 => {
                    $catalog.commandSlotFourSuggestionsByPath | get -o $path | default {
                        $catalog.commandSlotFourFallbackByFirst | get -o $action | default []
                    }
                }
                4 => { $catalog.commandSlotFiveSuggestionsByPath | get -o $path | default [] }
                _ => { [] }
            }
        }
        rule => {
            if $count == 1 { $catalog.ruleActionNames } else {
                match $action {
                    add | replace => { $catalog.ruleDefinitionFlags }
                    apply => { $catalog.ruleApplyFlags }
                    _ => { [] }
                }
            }
        }
        capture => {
            if $count == 1 { $catalog.captureActionNames } else if $count == 2 and $action == "start" {
                $catalog.captureProfiles
            } else { [] }
        }
        workspace => {
            if $count == 1 { return $catalog.workspaceActionNames }
            if $action != $catalog.workspaceMoveActionName or $count > 4 { return [] }
            let directions = if $count == 3 { $catalog.workspaceMoveDirections } else { [] }
            $directions | append $catalog.workspaceMoveOptionalFlags
        }
        window => {
            if $count == 1 { return $catalog.windowActionNames }
            if $action != "mark" { return [] }
            let mark_action = ($words | get -o 2 | default "")
            if $count == 2 { $catalog.windowMarkActionNames }
            else if $count == 3 and $mark_action == "list" { $catalog.windowMarkListFlags }
            else { [] }
        }
        subscribe => { $catalog.subscribeTokens }
        watch => { $catalog.watchTokens }
        _ => { [] }
    }
}

def "nu-complete omniwmctl" [spans: list<string>] {
    let catalog = $omniwmctl_catalog
    let prefix = ($spans | last | str trim --char '"' | str trim --char "'")
    mut words = []
    mut flags = []
    mut value_flag = ""
    for raw in ($spans | skip 1 | drop 1) {
        let token = ($raw | str trim --char '"' | str trim --char "'")
        if $value_flag != "" {
            $value_flag = ""
        } else if $token == "--exec" {
            return []
        } else if $token in $catalog.valueFlags {
            $flags = ($flags | append $token)
            $value_flag = $token
        } else if $token starts-with "--" {
            $flags = ($flags | append $token)
        } else {
            $words = ($words | append $token)
        }
    }
    let family = ($words | get -o 0 | default "")
    let action = ($words | get -o 1 | default "")
    let field_value = $value_flag == "--fields" and $family == "query"
    mut choices = if $field_value {
        $catalog.queryFieldsByName | get -o $action | default []
    } else if $value_flag != "" {
        $catalog.flagValuesByName | get -o $value_flag | default []
    } else {
        omniwmctl_choices $words
    }
    if $value_flag == "" and ($prefix starts-with "--") {
        $choices = ($choices | append ["--format" "--json"])
    }
    if $field_value or ($value_flag == "" and $family in [subscribe watch] and ($prefix | str contains ",")) {
        let parts = ($prefix | split row ",")
        let selected = ($parts | drop 1)
        let partial = ($parts | last)
        let leading = if ($selected | is-empty) { "" } else { ($selected | str join ",") + "," }
        return ($choices | where {|choice|
            not ($choice starts-with "--") and $choice not-in $selected and ($choice starts-with $partial)
        } | each {|choice| $leading + $choice } | sort | uniq)
    }
    $choices | where {|choice| $choice not-in $flags and ($choice starts-with $prefix) } | sort | uniq
}

@complete "nu-complete omniwmctl"
export extern omniwmctl [...args: string]
