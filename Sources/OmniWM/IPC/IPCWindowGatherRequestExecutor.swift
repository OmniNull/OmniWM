// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor
struct IPCWindowGatherRequestExecutor {
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
        controller.noteUserAction()
        if let guardResult = IPCCommandValidation.controllerState(controller) {
            return IPCApplicationBridge.response(for: guardResult, id: id, kind: .windowGather)
        }

        var inputs = resolveInputs(request.windowIds)
        let handler = controller.niriLayoutHandler
        let destination = handler.gatherDestination()
        let workspace = destination.flatMap { workspaceRef($0.workspaceId) }
        guard !inputs.isEmpty else {
            return refusal(id: id, inputs: inputs, workspace: workspace, reason: .noWindows)
        }
        guard let destination else {
            return refusal(id: id, inputs: inputs, workspace: nil, reason: .destinationUnavailable)
        }

        let reach = Self.reach(request.from)
        guard inputs.allSatisfy({ $0.reason == nil }) else {
            let tokens = inputs.compactMap { $0.reason == nil ? $0.token : nil }
            apply(handler.gatherEligibilityIssues(for: tokens, from: reach, into: destination), to: &inputs)
            return refusal(id: id, inputs: inputs, workspace: workspace, reason: .windowRefused)
        }

        switch handler.gatherWindows(inputs.compactMap(\.token), from: reach, into: destination) {
        case let .gathered(plan):
            let moved = Set(plan.movedTokens)
            let windows = inputs.map { input in
                IPCWindowGatherWindowResult(
                    windowId: input.windowId,
                    status: input.token.map(moved.contains) == true ? .moved : .unchanged
                )
            }
            let result = IPCWindowGatherResult(outcome: .gathered, workspace: workspace, windows: windows)
            return .success(id: id, kind: .windowGather, status: .executed, result: IPCResult(windowGather: result))
        case .unchanged:
            let result = IPCWindowGatherResult(
                outcome: .unchanged,
                workspace: workspace,
                windows: inputs.map { .init(windowId: $0.windowId, status: .unchanged) }
            )
            return .failure(
                id: id,
                kind: .windowGather,
                status: .ignored,
                code: .noChange,
                result: IPCResult(windowGather: result)
            )
        case let .refused(failure):
            if case let .windows(issues) = failure {
                apply(issues, to: &inputs)
            }
            return refusal(id: id, inputs: inputs, workspace: workspace, reason: Self.reason(for: failure))
        }
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
                let isFirst = seenTokens.insert(token).inserted
                return Input(windowId: windowId, token: token, reason: isFirst ? nil : .duplicateWindow)
            }
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
                .init(
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

    private static func reach(_ reach: IPCWindowGatherReach) -> NiriGatherReach {
        switch reach {
        case .workspace: .workspace
        case .monitor: .monitor
        case .all: .all
        }
    }

    private static func reason(for failure: NiriGatherFailure) -> IPCWindowGatherReason {
        switch failure {
        case .destinationUnavailable: .destinationUnavailable
        case .unsupportedLayout: .unsupportedLayout
        case .windows: .windowRefused
        case .doesNotFit: .doesNotFit
        }
    }

    private static func reason(for issue: NiriGatherWindowIssue) -> IPCWindowGatherReason {
        switch issue {
        case .notFound: .notFound
        case .outsideReach: .outsideReach
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
             .windowRefused:
            .invalidArguments
        case .staleWindowId:
            .staleWindowId
        case .notFound,
             .destinationUnavailable:
            .notFound
        case .unsupportedLayout:
            .unsupportedLayout
        case .layoutConflict:
            .workspaceStateConflict
        case .doesNotFit:
            .doesNotFit
        case .outsideReach,
             .scratchpad,
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
