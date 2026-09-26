// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

actor IPCApplicationBridge {
    private let controller: WMController
    private let appVersion: String?
    private let eventBroker: IPCEventBroker
    private let sessionToken: String
    private let authorizationToken: String
    private var lastPublishedDisplays: IPCResult?

    @MainActor
    init(
        controller: WMController,
        eventBroker: IPCEventBroker = IPCEventBroker(),
        appVersion: String? = Bundle.main.appVersion,
        sessionToken: String,
        authorizationToken: String
    ) {
        self.controller = controller
        self.appVersion = appVersion
        self.eventBroker = eventBroker
        self.sessionToken = sessionToken
        self.authorizationToken = authorizationToken
    }

    func mismatchResponse(for envelope: IPCRequestEnvelope) async -> IPCResponse {
        let id = envelope.id ?? ""
        let kind = envelope.kind.flatMap(IPCRequestKind.init(rawValue:))
        let responseKind = kind.map(IPCResponseKind.init(requestKind:)) ?? .error

        guard envelope.authorizationToken == authorizationToken else {
            return .failure(id: id, kind: responseKind, code: .unauthorized)
        }

        let versionResult = await versionResult()
        if kind == .version {
            return .success(id: id, kind: .version, result: versionResult)
        }

        return .failure(id: id, kind: responseKind, code: .protocolMismatch, result: versionResult)
    }

    func response(for request: IPCRequest) async -> IPCResponse {
        guard request.authorizationToken == authorizationToken else {
            return IPCResponse(failing: request, code: .unauthorized)
        }

        let versionResult = await versionResult()

        if let mismatch = protocolMismatchResponse(for: request, versionResult: versionResult) {
            return mismatch
        }

        switch request.payload {
        case .none:
            return await MainActor.run {
                responseWithoutPayload(for: request, versionResult: versionResult)
            }
        case let .command(command):
            let result = await commandResult { $0.handle(command) }
            return Self.response(for: result, id: request.id, kind: .command)
        case let .capture(capture):
            return await Self.captureResponse(for: capture, id: request.id, controller: controller)
        case let .query(query):
            return await MainActor.run {
                let queryRouter = IPCQueryRouter(
                    controller: controller,
                    appVersion: appVersion,
                    sessionToken: sessionToken
                )
                return self.response(for: query, id: request.id, queryRouter: queryRouter)
            }
        case let .rule(rule):
            let ruleRouter = await MainActor.run {
                IPCRuleRouter(controller: controller, sessionToken: sessionToken)
            }
            return await self.response(for: rule, id: request.id, ruleRouter: ruleRouter)
        case let .workspace(workspace):
            let result = await commandResult { $0.handle(workspace) }
            return Self.response(for: result, id: request.id, kind: .workspace)
        case let .window(window):
            let result = await commandResult { $0.handle(window) }
            return Self.response(for: result, id: request.id, kind: .window)
        case let .windowMark(windowMark):
            return await Self.windowMarkResponse(for: windowMark, id: request.id, controller: controller)
        case let .subscribe(subscribe):
            return await MainActor.run {
                let channels = IPCAutomationManifest.expandedChannels(for: subscribe)
                return .success(
                    id: request.id,
                    kind: .subscribe,
                    status: .subscribed,
                    result: IPCResult(subscribed: IPCSubscribeResult(channels: channels))
                )
            }
        }
    }

    private func protocolMismatchResponse(for request: IPCRequest, versionResult: IPCResult) -> IPCResponse? {
        guard request.version != OmniWMIPCProtocol.version else { return nil }
        if request.kind == .version {
            return .success(id: request.id, kind: .version, result: versionResult)
        }
        return IPCResponse(failing: request, code: .protocolMismatch, result: versionResult)
    }

    @MainActor
    private func responseWithoutPayload(for request: IPCRequest, versionResult: IPCResult) -> IPCResponse {
        let queryRouter = IPCQueryRouter(
            controller: controller,
            appVersion: appVersion,
            sessionToken: sessionToken
        )

        switch request.kind {
        case .ping:
            return .success(id: request.id, kind: .ping, result: IPCResult(pong: queryRouter.pingResult()))
        case .version:
            return .success(id: request.id, kind: .version, result: versionResult)
        case .command,
             .capture,
             .query,
             .rule,
             .workspace,
             .window,
             .windowMark,
             .subscribe:
            return IPCResponse(failing: request, code: .invalidRequest)
        }
    }

    private func versionResult() async -> IPCResult {
        let executableSHA256 = await OmniWMBuildInfo.executableSHA256.value
        return await MainActor.run {
            let queryRouter = IPCQueryRouter(
                controller: controller,
                appVersion: appVersion,
                sessionToken: sessionToken
            )
            return IPCResult(version: queryRouter.versionResult(executableSHA256: executableSHA256))
        }
    }

    private func commandResult(
        _ handle: @escaping @MainActor @Sendable (IPCCommandRouter) -> ExternalCommandResult
    ) async -> ExternalCommandResult {
        let controller = controller
        let sessionToken = sessionToken
        let perform: @MainActor @Sendable (WMController) -> ExternalCommandResult = { controller in
            handle(IPCCommandRouter(controller: controller, sessionToken: sessionToken))
        }
        return await withCheckedContinuation { continuation in
            let intake = IPCCommandIntake(
                perform: perform,
                completion: { continuation.resume(returning: $0) }
            )
            if !EventIntake.post(.ipcCommand(intake)) {
                Task { @MainActor in
                    continuation.resume(returning: perform(controller))
                }
            }
        }
    }

    func stream(for channel: IPCSubscriptionChannel) async -> AsyncStream<IPCEventEnvelope> {
        await eventBroker.registerStream(for: channel).stream
    }

    func registerStream(for channel: IPCSubscriptionChannel) async -> IPCEventStreamRegistration {
        await eventBroker.registerStream(for: channel)
    }

    func unregisterStream(_ registration: IPCEventStreamRegistration) async {
        await eventBroker.removeStream(id: registration.id, from: registration.channel)
    }

    func initialEvents(for request: IPCSubscribeRequest) async -> [IPCEventEnvelope] {
        guard request.sendInitial else { return [] }
        let channels = IPCAutomationManifest.expandedChannels(for: request)
        return await initialEvents(for: channels)
    }

    func initialEvents(for channels: [IPCSubscriptionChannel]) async -> [IPCEventEnvelope] {
        var events: [IPCEventEnvelope] = []
        for channel in channels {
            if let event = await eventEnvelope(for: channel) {
                events.append(event)
            }
        }
        return events
    }

    func publishEvent(_ channel: IPCSubscriptionChannel) async {
        guard hasSubscribers(for: channel) else { return }
        guard let event = await eventEnvelope(for: channel) else { return }
        if channel == .displayChanged {
            guard event.result != lastPublishedDisplays else { return }
            lastPublishedDisplays = event.result
        }
        await eventBroker.publish(event)
    }

    func shutdown() async {
        await eventBroker.finishAll()
    }

    nonisolated func hasSubscribers(for channel: IPCSubscriptionChannel) -> Bool {
        eventBroker.hasSubscribers(for: channel)
    }

    @MainActor
    private func response(for query: IPCQueryRequest, id: String, queryRouter: IPCQueryRouter) -> IPCResponse {
        if let validationFailure = IPCQuerySelection.validate(query, sessionToken: sessionToken) {
            return .failure(id: id, kind: .query, code: validationFailure)
        }
        return .success(id: id, kind: .query, result: IPCResult(query: query, queryRouter: queryRouter))
    }

    private func response(for rule: IPCRuleRequest, id: String, ruleRouter: IPCRuleRouter) async -> IPCResponse {
        switch await ruleRouter.handle(rule) {
        case let .success(result):
            return .success(
                id: id,
                kind: .rule,
                status: .executed,
                result: IPCResult(rules: result)
            )
        case let .failure(code):
            return .failure(id: id, kind: .rule, code: code)
        }
    }

    nonisolated static func response(
        for result: ExternalCommandResult,
        id: String,
        kind: IPCResponseKind
    ) -> IPCResponse {
        switch result {
        case .executed:
            return .success(id: id, kind: kind, status: .executed)
        case .ignoredDisabled:
            return .failure(id: id, kind: kind, status: .ignored, code: .disabled)
        case .ignoredOverview:
            return .failure(id: id, kind: kind, status: .ignored, code: .overviewOpen)
        case .ignoredLayoutMismatch:
            return .failure(id: id, kind: kind, status: .ignored, code: .layoutMismatch)
        case .staleWindowId:
            return .failure(id: id, kind: kind, code: .staleWindowId)
        case .workspaceAssignmentConflict:
            return .failure(id: id, kind: kind, code: .workspaceAssignmentConflict)
        case .workspaceStateConflict:
            return .failure(id: id, kind: kind, code: .workspaceStateConflict)
        case .notFound:
            return .failure(id: id, kind: kind, code: .notFound)
        case .noChange:
            return .failure(id: id, kind: kind, status: .ignored, code: .noChange)
        case .windowActionFailed:
            return .failure(id: id, kind: kind, code: .windowActionFailed)
        case .invalidArguments:
            return .failure(id: id, kind: kind, code: .invalidArguments)
        }
    }

    private func eventEnvelope(for channel: IPCSubscriptionChannel) async -> IPCEventEnvelope? {
        await MainActor.run {
            let queryRouter = IPCQueryRouter(
                controller: controller,
                appVersion: appVersion,
                sessionToken: sessionToken
            )
            let id = UUID().uuidString
            return IPCEventEnvelope.success(
                id: id,
                channel: channel,
                result: IPCResult(channel: channel, queryRouter: queryRouter)
            )
        }
    }
}
