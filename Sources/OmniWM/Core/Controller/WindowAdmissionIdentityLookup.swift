// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    static func lookupCreatedWindowIdentity(_ token: WindowToken) async throws -> AXWindowRef? {
        let windowId = UInt32(token.windowId)
        guard let app = NSRunningApplication(processIdentifier: token.pid),
              AXManager.shouldTrack(app, pid: token.pid),
              let context = try await AppAXContextRegistry.getOrCreate(app, pid: token.pid)
        else { return AXWindowService.axWindowRef(for: windowId, pid: token.pid) }
        return try await context.windowRefAsync(windowId: windowId)
    }

    func suspendCreatedWindowLookupExecution(_ execution: AdmissionRetryExecution) {
        guard var state = admissionRetryStateByWindowId[execution.windowId],
              state.generation == execution.generation,
              state.executionPhase == .running(execution.executionOwner)
        else { return }
        switch state.trigger {
        case .create,
             .candidate: break
        default: return
        }
        state.task = nil
        state.executionPhase = .waiting
        admissionRetryStateByWindowId[execution.windowId] = state
    }

    func requestCreatedWindowIdentity(token: WindowToken, execution: AdmissionRetryExecution?) {
        let windowId = UInt32(token.windowId)
        var state: AdmissionRetryState
        if let existing = admissionRetryStateByWindowId[windowId] {
            // A new create can look up identity while keeping the exhausted retry budget.
            if !existing.exhausted || execution != nil {
                guard case .create = existing.trigger else { return }
            }
            if case let .running(owner) = existing.executionPhase,
               execution != .init(windowId: windowId, generation: existing.generation, executionOwner: owner)
            {
                return
            }
            state = existing
        } else {
            guard execution == nil else { return }
            let generation = nextAdmissionRetryGeneration
            nextAdmissionRetryGeneration &+= 1
            state = AdmissionRetryState(
                expectedToken: token, axRef: nil, reason: .axWindowMissing,
                attempt: 0, generation: generation, trigger: .create,
                exhausted: false, task: nil
            )
        }
        state.task?.cancel()
        let executionOwner = nextAdmissionRetryExecutionOwner
        nextAdmissionRetryExecutionOwner &+= 1
        let lookupExecution = AdmissionRetryExecution(
            windowId: windowId, generation: state.generation, executionOwner: executionOwner
        )
        state.expectedToken = token
        state.trigger = .create
        state.identityRebindSource = nil
        state.executionPhase = .running(executionOwner)
        let provider = createdWindowAXRefProvider
        let query = lifecycleQueries.query
        state.task = Task { @MainActor [weak self] in
            let axRef: AXWindowRef?
            do {
                axRef = try await provider(token)
            } catch {
                guard !Task.isCancelled else { return }
                axRef = nil
            }
            guard !Task.isCancelled else { return }
            let windowInfo = if axRef != nil { try? await query(windowId) } else { nil as WindowServerInfo? }
            guard !Task.isCancelled else { return }
            self?.completeCreatedWindowIdentity(
                axRef, token: token, execution: lookupExecution, windowInfo: windowInfo
            )
        }
        admissionRetryStateByWindowId[windowId] = state
    }

    func completeCreatedWindowIdentity(
        _ axRef: AXWindowRef?, token: WindowToken, execution: AdmissionRetryExecution, windowInfo: WindowServerInfo?
    ) {
        let windowId = execution.windowId
        guard let controller,
              var state = admissionRetryStateByWindowId[windowId],
              state.generation == execution.generation,
              state.executionPhase == .running(execution.executionOwner),
              state.expectedToken == token,
              case .create = state.trigger
        else { return }
        defer { advanceLifecycleRetryGeneration(windowId: windowId, from: execution.generation) }
        state.task = nil
        state.executionPhase = .waiting
        admissionRetryStateByWindowId[windowId] = state
        if controller.isDiscoveryInProgress {
            deferCreateDuringDiscovery(windowId)
            return
        }
        guard let axRef, axRef.windowId == Int(windowId) else {
            retryCreatedWindowIdentity(token: token, reason: .axWindowMissing)
            return
        }
        guard windowInfo?.token(matching: windowId) == token else {
            retryCreatedWindowIdentity(token: token, reason: .windowInfoMissing)
            return
        }
        if shouldDeferCreateForInactiveNativeSpace(liveCreateSpace(for: windowId)) {
            deferCreatedWindow(windowId)
            return
        }
        prepareAndTrackCreatedWindow(
            windowId: windowId, windowInfo: windowInfo,
            fallbackToken: token, fallbackAXRef: axRef
        )
    }

    private func retryCreatedWindowIdentity(token: WindowToken, reason: WindowAdmissionPendingReason) {
        _ = preparedCreateCandidate(
            from: .pending(token: token, axRef: nil, reason: reason),
            windowId: UInt32(token.windowId),
            trigger: .create
        )
    }
}
