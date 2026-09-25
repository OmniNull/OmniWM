_omniwmctl()
{
  local cur prev command first second query_name suggestions workspace_action
  local workspace_positionals index token skip_format_value
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  command="${COMP_WORDS[1]}"

  __omniwmctl_compgen() {
    COMPREPLY=( $(compgen -W "$1" -- "$cur") )
  }

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    __omniwmctl_compgen "#{{topLevelCommands}}"
    return 0
  fi

  case "$command" in
    query)
      if [[ ${COMP_CWORD} -eq 2 ]]; then
        __omniwmctl_compgen "#{{queryNames}}"
        return 0
      fi

      query_name="${COMP_WORDS[2]}"
      suggestions=""
      if [[ "$prev" == "--fields" ]]; then
        case "$query_name" in
          #{{queryFieldsByName}}
        esac
      else
        case "$query_name" in
          #{{queryFlagsByName}}
        esac
      fi
      __omniwmctl_compgen "$suggestions"
      return 0
      ;;
    command)
      first="${COMP_WORDS[2]}"
      second="${COMP_WORDS[3]}"
      if [[ ${COMP_CWORD} -eq 2 ]]; then
        __omniwmctl_compgen "#{{commandFirstWords}}"
        return 0
      elif [[ ${COMP_CWORD} -eq 3 ]]; then
        suggestions=""
        case "$first" in
          #{{commandSlotThreeSuggestionsByFirst}}
        esac
        __omniwmctl_compgen "$suggestions"
        return 0
      elif [[ ${COMP_CWORD} -eq 4 ]]; then
        suggestions=""
        case "$first $second" in
          #{{commandSlotFourSuggestionsByPath}}
          *)
            case "$first" in
              #{{commandSlotFourFallbackByFirst}}
            esac
            ;;
        esac
        __omniwmctl_compgen "$suggestions"
        return 0
      elif [[ ${COMP_CWORD} -eq 5 ]]; then
        suggestions=""
        case "$first $second" in
          #{{commandSlotFiveSuggestionsByPath}}
        esac
        __omniwmctl_compgen "$suggestions"
        return 0
      fi
      ;;
    rule)
      if [[ ${COMP_CWORD} -eq 2 ]]; then
        __omniwmctl_compgen "#{{ruleActionNames}}"
        return 0
      fi
      if [[ "${COMP_WORDS[2]}" == "add" || "${COMP_WORDS[2]}" == "replace" ]]; then
        if [[ " #{{ruleDefinitionFlags}} " != *" $prev "* ]]; then
          __omniwmctl_compgen "#{{ruleDefinitionFlags}}"
          return 0
        fi
      fi
      if [[ "${COMP_WORDS[2]}" == "apply" && "$prev" != "--window" && "$prev" != "--pid" ]]; then
        __omniwmctl_compgen "#{{ruleApplyFlags}}"
        return 0
      fi
      ;;
    capture)
      if [[ ${COMP_CWORD} -eq 2 ]]; then
        __omniwmctl_compgen "#{{captureActionNames}}"
        return 0
      elif [[ ${COMP_CWORD} -eq 3 && "${COMP_WORDS[2]}" == "start" ]]; then
        __omniwmctl_compgen "#{{captureProfiles}}"
        return 0
      fi
      ;;
    subscribe)
      if [[ " ${COMP_WORDS[*]} " != *" --exec "* ]]; then
        __omniwmctl_compgen "#{{subscribeTokens}}"
        return 0
      fi
      ;;
    watch)
      if [[ " ${COMP_WORDS[*]} " != *" --exec "* ]]; then
        __omniwmctl_compgen "#{{watchTokens}}"
        return 0
      fi
      ;;
    workspace)
      workspace_action="${COMP_WORDS[2]}"
      if [[ ${COMP_CWORD} -eq 2 ]]; then
        __omniwmctl_compgen "#{{workspaceActionNames}}"
      elif [[ "$workspace_action" == "#{{workspaceMoveActionName}}" ]]; then
        workspace_positionals=0
        skip_format_value=0
        for (( index = 3; index < COMP_CWORD; index++ )); do
          token="${COMP_WORDS[index]}"
          if [[ ${skip_format_value} -eq 1 ]]; then
            skip_format_value=0
          elif [[ "$token" == "--format" ]]; then
            skip_format_value=1
          elif [[ "$token" != --* ]]; then
            (( workspace_positionals += 1 ))
          fi
        done
        if [[ ${workspace_positionals} -eq 1 ]]; then
          suggestions="#{{workspaceMoveDirections}}"
        fi
        if [[ ${workspace_positionals} -le 2 ]] &&
           [[ " ${COMP_WORDS[*]} " != *" --force "* ]]; then
          suggestions="$suggestions #{{workspaceMoveOptionalFlags}}"
        fi
        __omniwmctl_compgen "$suggestions"
      fi
      return 0
      ;;
    window)
      if [[ ${COMP_CWORD} -eq 2 ]]; then
        __omniwmctl_compgen "#{{windowActionNames}}"
      elif [[ ${COMP_CWORD} -eq 3 && "${COMP_WORDS[2]}" == "mark" ]]; then
        __omniwmctl_compgen "#{{windowMarkActionNames}}"
      elif [[ ${COMP_CWORD} -eq 4 && "${COMP_WORDS[2]}" == "mark" && "${COMP_WORDS[3]}" == "list" ]]; then
        __omniwmctl_compgen "#{{windowMarkListFlags}}"
      fi
      return 0
      ;;
    completion)
      __omniwmctl_compgen "#{{shellNames}}"
      return 0
      ;;
  esac
}

complete -F _omniwmctl omniwmctl
