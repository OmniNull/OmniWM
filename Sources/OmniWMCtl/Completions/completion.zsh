#compdef omniwmctl

_omniwmctl() {
  local cur
  cur="${words[CURRENT]}"

  local suggestions=""
  if (( CURRENT == 2 )); then
    suggestions="#{{topLevelCommands}}"
    compadd -- ${=suggestions}
    return
  fi

  case "${words[2]}" in
    query)
      if (( CURRENT == 3 )); then
        suggestions="#{{queryNames}}"
      else
        local query_name="${words[3]}"
        local prev="${words[CURRENT-1]}"
        if [[ "$prev" == "--fields" ]]; then
          case "$query_name" in
            #{{queryFieldsByName}}
          esac
        else
          case "$query_name" in
            #{{queryFlagsByName}}
          esac
        fi
      fi
      ;;
    command)
      local first="${words[3]}"
      local second="${words[4]}"
      if (( CURRENT == 3 )); then
        suggestions="#{{commandFirstWords}}"
      elif (( CURRENT == 4 )); then
        case "$first" in
          #{{commandSlotThreeSuggestionsByFirst}}
        esac
      elif (( CURRENT == 5 )); then
        case "$first $second" in
          #{{commandSlotFourSuggestionsByPath}}
          *)
            case "$first" in
              #{{commandSlotFourFallbackByFirst}}
            esac
            ;;
        esac
      elif (( CURRENT == 6 )); then
        case "$first $second" in
          #{{commandSlotFiveSuggestionsByPath}}
        esac
      fi
      ;;
    rule)
      if (( CURRENT == 3 )); then
        suggestions="#{{ruleActionNames}}"
      elif [[ "${words[3]}" == "add" || "${words[3]}" == "replace" ]]; then
        local prev="${words[CURRENT-1]}"
        if [[ " #{{ruleDefinitionFlags}} " != *" $prev "* ]]; then
          suggestions="#{{ruleDefinitionFlags}}"
        fi
      elif [[ "${words[3]}" == "apply" ]]; then
        local prev="${words[CURRENT-1]}"
        if [[ "$prev" != "--window" && "$prev" != "--pid" ]]; then
          suggestions="#{{ruleApplyFlags}}"
        fi
      fi
      ;;
    capture)
      if (( CURRENT == 3 )); then
        suggestions="#{{captureActionNames}}"
      elif (( CURRENT == 4 )) && [[ "${words[3]}" == "start" ]]; then
        suggestions="#{{captureProfiles}}"
      fi
      ;;
    subscribe)
      if [[ " ${words[*]} " != *" --exec "* ]]; then
        suggestions="#{{subscribeTokens}}"
      fi
      ;;
    watch)
      if [[ " ${words[*]} " != *" --exec "* ]]; then
        suggestions="#{{watchTokens}}"
      fi
      ;;
    workspace)
      local action="${words[3]}"
      local workspace_positionals=0
      local index token skip_format_value=0
      if (( CURRENT == 3 )); then
        suggestions="#{{workspaceActionNames}}"
      elif [[ "$action" == "#{{workspaceMoveActionName}}" ]]; then
        for (( index = 4; index < CURRENT; index++ )); do
          token="${words[index]}"
          if (( skip_format_value )); then
            skip_format_value=0
          elif [[ "$token" == "--format" ]]; then
            skip_format_value=1
          elif [[ "$token" != --* ]]; then
            (( workspace_positionals += 1 ))
          fi
        done
        if (( workspace_positionals == 1 )); then
          suggestions="#{{workspaceMoveDirections}}"
        fi
        if (( workspace_positionals <= 2 )) &&
           [[ " ${words[*]} " != *" --force "* ]]; then
          suggestions="$suggestions #{{workspaceMoveOptionalFlags}}"
        fi
      fi
      ;;
    window)
      if (( CURRENT == 3 )); then
        suggestions="#{{windowActionNames}}"
      elif (( CURRENT == 4 )) && [[ "${words[3]}" == "mark" ]]; then
        suggestions="#{{windowMarkActionNames}}"
      elif (( CURRENT == 5 )) && [[ "${words[3]}" == "mark" && "${words[4]}" == "list" ]]; then
        suggestions="#{{windowMarkListFlags}}"
      fi
      ;;
    completion)
      suggestions="#{{shellNames}}"
      ;;
  esac

  [[ -n "$suggestions" ]] && compadd -- ${=suggestions}
}

_omniwmctl "$@"
