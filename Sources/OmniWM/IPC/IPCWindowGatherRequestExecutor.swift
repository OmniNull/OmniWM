// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor
struct IPCWindowGatherRequestExecutor {
    private enum Destination {
        case resolved(WorkspaceDescriptor.ID)
        case refused(IPCWindowGatherReason)
    }

    private struct Input {
        let windowId: String
        var token: WindowToken?
        var reason: IPCWindowGatherReason?
    }

    private let controller: WMController
    private let sessionToken: String

    init(controller: WMController, sessionToken: String) {
        self.controller = controller
        self.sessionToken = sessionToken
    }

    func response(for request: IPCWindowGatherRequest, id: String) -> IPCResponse {
        switch IPCCommandValidation.controllerState(controller) {
        case .ignoredDisabled:
            return .failure(id: id, kind: .windowGather, code: .disabled)
        case .ignoredOverview:
            return .failure(id: id, kind: .windowGather, code: .overviewOpen)
        default:
            break
        }

        var inputs = resolveInputs(request.windowIds)
        let destinationId: WorkspaceDescriptor.ID
        switch resolveDestination(request.workspaceTarget) {
        case let .refused(reason):
            return refusal(id: id, inputs: inputs, workspace: nil, reason: reason)
        case let .resolved(resolved):
            destinationId = resolved
        }
        let workspace = workspaceRef(destinationId)
        guard !inputs.isEmpty else {
            return refusal(id: id, inputs: inputs, workspace: workspace, reason: .noWindows)
        }

        let handler = controller.niriLayoutHandler
        guard inputs.allSatisfy({ $0.reason == nil }) else {
            let issues = handler.gatherEligibilityIssues(for: inputs.compactMap { $0.reason == nil ? $0.token : nil })
            apply(issues, to: &inputs)
            return refusal(id: id, inputs: inputs, workspace: workspace, reason: .windowRefused)
        }

        switch handler.gatherWindows(inputs.compactMap(\.token), into: destinationId) {
        case let .gathered(plan):
            return gathered(plan, id: id, inputs: inputs, workspace: workspace)
        case .unchanged:
            return unchanged(id: id, inputs: inputs, workspace: workspace)
        case let .refused(failure):
            if case let .windows(issues) = failure {
                apply(issues, to: &inputs)
            }
            return refusal(id: id, inputs: inputs, workspace: workspace, reason: Self.reason(for: failure))
        }
    }

    private func gathered(
        _ plan: NiriGatherPlan,
        id: String,
        inputs: [Input],
        workspace: IPCWorkspaceRef?
    ) -> IPCResponse {
        let moved = Set(plan.movedTokens)
        let isMoved: (Input) -> Bool = { $0.token.map(moved.contains) == true }
        let result = IPCWindowGatherResult(
            outcome: .gathered,
            workspace: workspace,
            windows: inputs.map {
                IPCWindowGatherWindowResult(windowId: $0.windowId, status: isMoved($0) ? .moved : .unchanged)
            },
            moved: inputs.filter(isMoved).map(\.windowId),
            relayoutWorkspaces: plan.affectedWorkspaceIds.compactMap(workspaceRef)
        )
        return .success(id: id, kind: .windowGather, status: .executed, result: IPCResult(windowGather: result))
    }

    private func unchanged(id: String, inputs: [Input], workspace: IPCWorkspaceRef?) -> IPCResponse {
        let result = IPCWindowGatherResult(
            outcome: .unchanged,
            workspace: workspace,
            windows: inputs.map { IPCWindowGatherWindowResult(windowId: $0.windowId, status: .unchanged) }
        )
        return .failure(
            id: id,
            kind: .windowGather,
            status: .ignored,
            code: .noChange,
            result: IPCResult(windowGather: result)
        )
    }

    private func resolveInputs(_ windowIds: [String]) -> [Input] {
        var seenTokens = Set<WindowToken>()
        return windowIds.map { windowId in
            switch IPCWindowOpaqueID.validate(windowId, expectingSessionToken: sessionToken) {
            case .invalid:
                return Input(windowId: windowId, reason: .invalidWindowId)
            case .stale:
                return Input(windowId: windowId, reason: .staleWindowId)
            case let .valid(pid, rawWindowId):
                let token = WindowToken(pid: pid, windowId: rawWindowId)
                guard seenTokens.insert(token).inserted else {
                    return Input(windowId: windowId, token: token, reason: .duplicateWindow)
                }
                return Input(windowId: windowId, token: token)
            }
        }
    }

    private func resolveDestination(_ target: WorkspaceTarget) -> Destination {
        switch IPCCommandValidation.workspaceTarget(target, controller: controller) {
        case .failure(.notFound):
            return .refused(.destinationNotFound)
        case .failure:
            return .refused(.invalidDestination)
        case let .success(rawWorkspaceID):
            guard let workspaceId = controller.workspaceManager.workspaceId(
                for: rawWorkspaceID,
                createIfMissing: false
            ) else {
                return .refused(.destinationNotFound)
            }
            return .resolved(workspaceId)
        }
    }

    private func apply(_ issues: [WindowToken: NiriGatherWindowIssue], to inputs: inout [Input]) {
        for index in inputs.indices where inputs[index].reason == nil {
            if let issue = inputs[index].token.flatMap({ issues[$0] }) {
                inputs[index].reason = Self.reason(for: issue)
            }
        }
    }

    private func refusal(
        id: String,
        inputs: [Input],
        workspace: IPCWorkspaceRef?,
        reason: IPCWindowGatherReason
    ) -> IPCResponse {
        let result = IPCWindowGatherResult(
            outcome: .refused,
            workspace: workspace,
            reason: reason,
            windows: inputs.map { input in
                IPCWindowGatherWindowResult(
                    windowId: input.windowId,
                    status: input.reason.map(Self.status(for:)) ?? .blocked,
                    reason: input.reason
                )
            }
        )
        let code = reason == .windowRefused
            ? inputs.lazy.compactMap(\.reason).first.map(Self.code(for:)) ?? .invalidArguments
            : Self.code(for: reason)
        return .failure(id: id, kind: .windowGather, code: code, result: IPCResult(windowGather: result))
    }

    private func workspaceRef(_ workspaceId: WorkspaceDescriptor.ID) -> IPCWorkspaceRef? {
        controller.workspaceManager.descriptor(for: workspaceId).map {
            IPCWorkspaceRef(descriptor: $0, settings: controller.settings)
        }
    }

    private static func reason(for failure: NiriGatherFailure) -> IPCWindowGatherReason {
        switch failure {
        case .destinationNotFound: .destinationNotFound
        case .invalidDestination: .invalidDestination
        case .unsupportedLayout: .unsupportedLayout
        case .windows: .windowRefused
        case .doesNotFit: .doesNotFit
        case .stalePlan: .stalePlan
        }
    }

    private static func reason(for issue: NiriGatherWindowIssue) -> IPCWindowGatherReason {
        switch issue {
        case .notFound: .notFound
        case .scratchpad: .scratchpad
        case .nativeFullscreen: .nativeFullscreen
        case .appHidden: .appHidden
        case .minimized: .minimized
        case .nativeWithdrawn: .nativeWithdrawn
        case .floating: .floating
        case .unsupportedLayout: .unsupportedLayout
        case .layoutConflict: .layoutConflict
        case .layoutFullscreen: .layoutFullscreen
        }
    }

    private static func status(for reason: IPCWindowGatherReason) -> IPCWindowGatherWindowStatus {
        switch reason {
        case .invalidWindowId,
             .staleWindowId,
             .notFound:
            .unresolved
        default:
            .refused
        }
    }

    private static func code(for reason: IPCWindowGatherReason) -> IPCErrorCode {
        switch reason {
        case .invalidWindowId,
             .duplicateWindow,
             .noWindows,
             .invalidDestination,
             .windowRefused:
            .invalidArguments
        case .staleWindowId:
            .staleWindowId
        case .notFound,
             .destinationNotFound:
            .notFound
        case .unsupportedLayout:
            .unsupportedLayout
        case .layoutConflict,
             .stalePlan:
            .workspaceStateConflict
        case .doesNotFit:
            .doesNotFit
        case .scratchpad,
             .nativeFullscreen,
             .appHidden,
             .minimized,
             .nativeWithdrawn,
             .floating,
             .layoutFullscreen:
            .ineligibleWindow
        }
    }
}
