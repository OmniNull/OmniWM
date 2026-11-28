// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation
import OmniWMScriptHost

extension ConfigScriptStage {
    static let shellControlCallback: omni_config_shell_control_callback =
        { context, words, count, at, error, capacity in
            dispatch(into: context, at: at, error: error, capacity: capacity) {
                () throws(ConfigScriptError) in
                try shellControl(UnsafeBufferPointer(start: words, count: count))
            }
        }

    private static func shellControl(
        _ words: UnsafeBufferPointer<omni_config_span>
    ) throws(ConfigScriptError) -> ConfigScriptDispatch.Operation {
        let invalid = ConfigScriptError(line: nil, message: "Invalid shell action or arguments.")
        guard let first = words.first else { throw invalid }
        let request: ShellRuntimeRequest = switch (try string(first), words.count) {
        case ("set", 3):
            try .set(key: string(words[1]), value: string(words[2]))
        case ("unset", 2):
            try .unset(key: string(words[1]))
        case ("toggle", 2):
            try .toggle(widget: string(words[1]))
        case ("trigger", 3),
             ("trigger", 4):
            try .trigger(
                widget: string(words[1]),
                name: string(words[2]),
                value: words.count == 4 ? string(words[3]) : nil
            )
        default:
            throw invalid
        }
        guard request.isValid else { throw invalid }
        if case let .toggle(widget) = request { return .native(.shellToggle(widget)) }
        return .shell(request)
    }
}

extension WMController {
    func performConfigScriptShell(
        _ request: borrowing ShellRuntimeRequest, target: ConfigScriptTarget
    ) -> ExternalCommandResult {
        guard target.sessionID == scriptSession.identity else { return .staleWindowId }
        switch request {
        case .trigger:
            if let refusal = automationRefusal { return refusal }
        default:
            break
        }
        return workspaceBarManager.applyShellRuntimeRequest(request)
    }
}

extension ConfigScriptDispatch {
    func shellRefusalReason(_ outcome: ExternalCommandResult) -> String {
        switch outcome {
        case .staleWindowId:
            "the callback belongs to an earlier session"
        case .ignoredOverview:
            "Overview is open"
        case .ignoredDisabled:
            "OmniWM is disabled"
        case .invalidArguments:
            "the runtime variable limit is full"
        case .notFound:
            if case .shell(.trigger) = operation { "the widget has no available trigger" }
            else { "no matching widget or drawer is available" }
        default:
            String(describing: outcome)
        }
    }
}
