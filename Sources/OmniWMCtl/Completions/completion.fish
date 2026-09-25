# Disable file fallback even when no conditional completion matches.
complete -c omniwmctl -f

function __omniwmctl_prev_arg_is
    set -l tokens (commandline -opc)
    test (count $tokens) -gt 0; or return 1
    set -l prev $tokens[-1]
    contains -- $prev $argv
end

function __omniwmctl_has_arg
    set -l tokens (commandline -opc)
    contains -- $argv[1] $tokens
end

function __omniwmctl_workspace_positionals
    set -l count 0
    set -l action_seen false
    set -l skip_format_value false
    for token in (commandline -opc)
        if test "$action_seen" = false
            if test "$token" = "#{{workspaceMoveActionName}}"
                set action_seen true
            end
        else if test "$skip_format_value" = true
            set skip_format_value false
        else if test "$token" = "--format"
            set skip_format_value true
        else if not string match -q -- '--*' "$token"
            set count (math $count + 1)
        end
    end
    echo $count
end

function __omniwmctl_workspace_positionals_are
    test (__omniwmctl_workspace_positionals) -eq "$argv[1]"
end

function __omniwmctl_workspace_positionals_at_most
    test (__omniwmctl_workspace_positionals) -le "$argv[1]"
end
#{{baseLines}}
#{{queryLines}}
#{{queryFlagLines}}
#{{queryFieldLines}}
#{{commandRootLines}}
#{{commandNestedLines}}
#{{commandPathArgumentLines}}
#{{commandFallbackLines}}
#{{commandSecondArgumentLines}}
#{{ruleLines}}
#{{ruleDefinitionLines}}
#{{ruleApplyLines}}
#{{captureActionLines}}
#{{captureProfileLines}}
#{{subscribeLines}}
#{{watchLines}}
#{{workspaceLines}}
#{{workspaceMoveDirectionLines}}
#{{workspaceMoveFlagLines}}
#{{windowLines}}
#{{shellLines}}