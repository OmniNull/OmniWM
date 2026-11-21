// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

enum CLICompletionGenerator {
    static func script(for shell: CLIShell) -> String {
        switch shell {
        case .bash:
            #"complete -C 'omniwmctl __complete bash' omniwmctl"#
        case .zsh:
            #"""
            #compdef omniwmctl
            _omniwmctl() { local -a matches; matches=(${(f)"$(omniwmctl __complete zsh "$CURRENT" "${words[@]}")"}); (( $#matches )) && compadd -- $matches }
            if [[ $funcstack[1] == _omniwmctl ]]; then _omniwmctl "$@"; else compdef _omniwmctl omniwmctl; fi
            """#
        case .fish:
            #"complete -c omniwmctl -f -a '(omniwmctl __complete fish -- (commandline -xpc) "$(commandline -ct)")'"#
        case .nu:
            """
            def "nu-complete omniwmctl" [place: record] { ^omniwmctl __complete nu ...$place.command | lines }
            @complete "nu-complete omniwmctl"
            export extern omniwmctl [...args: string]
            """
        }
    }
}
