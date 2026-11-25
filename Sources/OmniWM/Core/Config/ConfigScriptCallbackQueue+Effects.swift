// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension ConfigScriptCallbackQueue {
    func applyTimer(
        _ result: Result<ConfigScriptInvocation, ConfigScriptError>, target: ConfigScriptTarget?,
        controller: WMController,
        owner: ConfigScriptController
    ) async {
        do throws(ConfigScriptError) {
            let invocation = try result.get()
            guard let commands = invocation.batch else { return }
            try await apply(
                commands,
                target: target ?? controller.configScriptTarget(),
                cause: nil,
                controller: controller,
                owner: owner
            )
        } catch {
            report(error, to: owner)
        }
    }

    func report(_ error: ConfigScriptError, to owner: ConfigScriptController) {
        guard !Task.isCancelled, owner.callbackQueue === self else { return }
        owner.reportCallbackError(error)
    }

    @inline(__always)
    func apply(
        _ commands: [ConfigScriptDispatch], target: ConfigScriptTarget, cause: ConfigScriptEventCause?,
        controller: WMController, owner: ConfigScriptController
    ) async throws(ConfigScriptError) {
        for dispatch in commands {
            guard !Task.isCancelled, owner.callbackQueue === self else { return }
            if let cause { try feedback.checkLaunch(dispatch, from: cause.function) }
            let outcome: ExternalCommandResult
            if case let .native(.runProgram(arguments)) = dispatch.operation {
                do {
                    outcome = try await controller.startConfigScriptProgram(arguments, target: target)
                } catch {
                    throw ConfigScriptError(
                        line: dispatch.line, message: error.localizedDescription, source: dispatch.source
                    )
                }
            } else if case let .dwindleReplace(replace) = dispatch.operation {
                switch controller.performConfigScriptDwindleReplace(replace, target: target) {
                case let .result(result):
                    outcome = result
                case let .refused(refusal):
                    throw ConfigScriptError(
                        line: dispatch.line, message: "dwindle replace: \(refusal.reason).", source: dispatch.source
                    )
                }
            } else if let cause {
                outcome = performEventCommand(
                    dispatch.operation,
                    target: target,
                    cause: cause,
                    controller: controller
                )
            } else {
                outcome = controller.performConfigScriptDispatch(dispatch.operation, target: target)
            }
            guard outcome == .executed || outcome == .noChange else {
                throw ConfigScriptError(
                    line: dispatch.line, message: "\(dispatch.displayName): \(outcome).",
                    source: dispatch.source
                )
            }
        }
    }

    private func performEventCommand(
        _ operation: borrowing ConfigScriptDispatch.Operation, target: ConfigScriptTarget,
        cause: ConfigScriptEventCause, controller: WMController
    ) -> ExternalCommandResult {
        feedback.begin(cause, controller: controller)
        let manager = controller.workspaceManager
        let closing: WindowHandle? = if hasCloseListener {
            switch operation {
            case .native(.windowState(.close)): target.token.flatMap { manager.handle(for: $0) }
            case let .window(window) where window.action == .close: manager.handle(for: window.token)
            default: nil
            }
        } else { nil }
        let fullscreen: ConfigScriptEventObservers? = switch operation {
        case .native(.fullscreen(.native)): manager.scriptWindowFullscreenObserver
        default: nil
        }
        let priorGeneration = fullscreen.map { _ in manager.nativeFullscreenTransitionGenerationCounter }
        let outcome = controller.performConfigScriptDispatch(operation, target: target)
        if let fullscreen, let priorGeneration, outcome == .executed {
            fullscreen.recordFullscreenRequest(
                for: target.token, since: priorGeneration, cause: cause, manager: manager
            )
        }
        if let closing { feedback.recordClose(closing, outcome: outcome, controller: controller) }
        feedback.end(controller: controller)
        return outcome
    }
}
