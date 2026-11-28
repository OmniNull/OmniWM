// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct ConfigScriptRuleApplyOwner: Equatable {
    struct Focus: Equatable {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
    }

    let session: ConfigScriptSession
    let generation: UInt64
    let focus: Focus?

    @MainActor
    func currentQueue(in controller: WMController) -> ConfigScriptCallbackQueue? {
        guard controller.scriptSession.identity == session,
              let queue = controller.configScript?.callbackQueue,
              queue.ruleApplyGeneration == generation, !queue.isRetired
        else { return nil }
        return queue
    }

    @MainActor
    func refusal(in controller: WMController) -> ConfigScriptDispatchRefusal? {
        if let refusal = controller.configScriptAutomationRefusal(session: session) { return refusal }
        guard currentQueue(in: controller) != nil else {
            return ConfigScriptDispatchRefusal(reason: "the callback belongs to an earlier session")
        }
        if let focus, !controller.matchesAutomationFocus(focus.token, workspaceId: focus.workspaceId) {
            return ConfigScriptDispatchRefusal(reason: "the captured managed focus changed")
        }
        return nil
    }
}

struct ConfigScriptRuleApplyAuthorization {
    let owner: ConfigScriptRuleApplyOwner
    let cause: ConfigScriptEventCause?
}

extension WMController {
    func configScriptAutomationRefusal(session: ConfigScriptSession) -> ConfigScriptDispatchRefusal? {
        guard session == scriptSession.identity else {
            return ConfigScriptDispatchRefusal(reason: "the callback belongs to an earlier session")
        }
        switch automationRefusal {
        case .ignoredOverview: return ConfigScriptDispatchRefusal(reason: "Overview is open")
        case .some: return ConfigScriptDispatchRefusal(reason: "OmniWM is disabled")
        case nil: return nil
        }
    }
}

extension ConfigScriptCallbackQueue {
    private static var ruleApplyGenerationCounter: UInt64 = 0

    static func nextRuleApplyGeneration() -> UInt64 {
        ruleApplyGenerationCounter += 1
        return ruleApplyGenerationCounter
    }

    func applyRule(
        _ request: ConfigScriptRuleApplyTarget, dispatch: borrowing ConfigScriptDispatch,
        target: ConfigScriptTarget, cause: ConfigScriptEventCause?, controller: WMController
    ) async throws(ConfigScriptError) {
        do {
            try await performRuleApply(request, target: target, cause: cause, controller: controller)
        } catch {
            throw ConfigScriptError(
                line: dispatch.line, message: "\(dispatch.displayName): \(error.reason).", source: dispatch.source
            )
        }
    }

    private func performRuleApply(
        _ request: ConfigScriptRuleApplyTarget, target: ConfigScriptTarget,
        cause: ConfigScriptEventCause?, controller: WMController
    ) async throws(ConfigScriptDispatchRefusal) {
        if let refusal = controller.configScriptAutomationRefusal(session: target.sessionID) { throw refusal }
        let nativeTarget: WindowRuleReevaluationTarget
        var focus: ConfigScriptRuleApplyOwner.Focus?
        switch request {
        case .focused:
            guard let token = target.token, let workspaceId = target.workspaceId else {
                throw ConfigScriptDispatchRefusal(reason: "no captured managed window has focus")
            }
            focus = .init(token: token, workspaceId: workspaceId)
            nativeTarget = .window(token)
        case let .window(token, session):
            guard target.sessionID == session else {
                throw ConfigScriptDispatchRefusal(reason: "the window ID belongs to an earlier session")
            }
            nativeTarget = .window(token)
        case let .pid(pid):
            guard controller.workspaceManager.hasEntries(forPid: pid) else {
                throw ConfigScriptDispatchRefusal(reason: "the process has no managed windows")
            }
            nativeTarget = .pid(pid)
        }
        let authorization = ConfigScriptRuleApplyAuthorization(
            owner: .init(session: target.sessionID, generation: ruleApplyGeneration, focus: focus),
            cause: cause
        )
        let outcome = await controller.reevaluateWindowRules(
            for: [nativeTarget], context: .explicitRuleApply, script: authorization
        )
        if outcome.stale {
            throw authorization.owner.refusal(in: controller)
                ?? ConfigScriptDispatchRefusal(reason: "rule re-evaluation became stale")
        }
        guard outcome.resolvedAnyTarget, outcome.evaluatedAnyWindow else {
            throw ConfigScriptDispatchRefusal(reason: "no managed window was evaluated")
        }
    }
}
