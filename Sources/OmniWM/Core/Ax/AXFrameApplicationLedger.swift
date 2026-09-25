// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

@MainActor
final class AXFrameApplicationLedger {
    private var appliedFrameStates: [Int: AXAppliedFrameState] = [:]
    private var pendingFrameWrites: [Int: AXPendingFrameWrite] = [:]
    private var recentFrameWriteFailures: [Int: AXRecentFrameWriteFailure] = [:]
    private var retryBudgetByWindowId: [Int: Int] = [:]
    private var forceApplyWindowIds: Set<Int> = []
    private var rekeyedWindowIds = AXFrameRekeyMap()
    private let observers = AXFrameObserverRegistry()
    private var nextFrameApplicationRequestId: AXFrameRequestId = 1

    func forceApplyNextFrame(for windowId: Int) {
        forceApplyWindowIds.insert(windowId)
    }

    func invalidateAppliedFrame(for windowId: Int) {
        appliedFrameStates.removeValue(forKey: windowId)
        recentFrameWriteFailures[windowId]?.isTerminalRefusal = false
    }

    func invalidateAllAppliedFrames() {
        appliedFrameStates.removeAll(keepingCapacity: true)
    }

    func lastAppliedFrame(for windowId: Int) -> CGRect? {
        appliedFrameStates[windowId]?.frame
    }

    func trustedVerifiedSize(for windowId: Int) -> CGSize? {
        appliedFrameStates[windowId]?.verifiedSize
    }

    func enforcedSizePlacement(for windowId: Int, targetFrame: CGRect) -> CGRect? {
        guard let clamp = recentFrameWriteFailures[windowId]?.enforcedSizeClamp(for: targetFrame) else {
            return nil
        }
        return CGRect(
            x: targetFrame.minX,
            y: targetFrame.maxY - clamp.height,
            width: clamp.width,
            height: clamp.height
        )
    }

    func recentFrameWriteFailure(for windowId: Int) -> AXFrameWriteFailureReason? {
        recentFrameWriteFailures[windowId]?.reason
    }

    func hasTerminalRefusal(for windowId: Int) -> Bool {
        recentFrameWriteFailures[windowId]?.isTerminalRefusal == true
    }

    func recentFrameWriteFailureComponents(for windowId: Int) -> AXFrameComponents? {
        recentFrameWriteFailures[windowId]?.components
    }

    func hasPendingFrameWrite(for windowId: Int) -> Bool {
        pendingFrameWrites[windowId] != nil
    }

    func pendingFrameWrite(for windowId: Int) -> CGRect? {
        pendingFrameWrites[windowId]?.frame
    }

    func stateDump() -> String {
        let windowIds = Set(appliedFrameStates.keys)
            .union(pendingFrameWrites.keys)
            .union(recentFrameWriteFailures.keys)
            .union(retryBudgetByWindowId.keys)
        guard !windowIds.isEmpty else { return "none" }
        return windowIds.sorted()
            .map { windowId in
                var parts = ["win=\(windowId)"]
                appliedFrameStates[windowId]?.appendStateDescription(to: &parts)
                pendingFrameWrites[windowId]?.appendStateDescription(to: &parts)
                recentFrameWriteFailures[windowId]?.appendStateDescription(to: &parts)
                if let retry = retryBudgetByWindowId[windowId] { parts.append("retryBudget=\(retry)") }
                return parts.joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
        if pendingFrameWrites[windowId] != nil {
            return true
        }
        guard let observedFrame else {
            if appliedFrameStates[windowId]?.convergedTargetFrame != nil {
                appliedFrameStates.removeValue(forKey: windowId)
            }
            return false
        }
        guard let appliedState = appliedFrameStates[windowId] else {
            return false
        }
        guard observedFrame.approximatelyEqual(
            to: appliedState.frame,
            tolerance: FrameTolerance.frameWrite
        ) else {
            appliedFrameStates.removeValue(forKey: windowId)
            return false
        }
        return true
    }

    func rekeyWindowState(oldWindowId: Int, newWindowId: Int) {
        guard oldWindowId != newWindowId else { return }
        rekeyedWindowIds.record(oldWindowId: oldWindowId, newWindowId: newWindowId)

        if let state = appliedFrameStates.removeValue(forKey: oldWindowId) {
            appliedFrameStates[newWindowId] = state
        }

        if var pending = pendingFrameWrites.removeValue(forKey: oldWindowId) {
            pending.expectedWindow = AXWindowRef(
                element: pending.expectedWindow.element,
                windowId: newWindowId
            )
            pendingFrameWrites[newWindowId] = pending
        }

        if var failure = recentFrameWriteFailures.removeValue(forKey: oldWindowId) {
            failure.expectedWindow = AXWindowRef(
                element: failure.expectedWindow.element,
                windowId: newWindowId
            )
            recentFrameWriteFailures[newWindowId] = failure
        }

        if let retryBudget = retryBudgetByWindowId.removeValue(forKey: oldWindowId) {
            retryBudgetByWindowId[newWindowId] = retryBudget
        }

        if forceApplyWindowIds.remove(oldWindowId) != nil {
            forceApplyWindowIds.insert(newWindowId)
        }

        observers.rekey(oldWindowId: oldWindowId, newWindowId: newWindowId)
        clearSettledRekeyMappings(to: newWindowId)
    }

    func confirmFrameWrite(for windowId: Int, frame: CGRect) {
        appliedFrameStates[windowId] = AXAppliedFrameState(
            frame: frame,
            verifiedComponents: .all,
            convergedTargetFrame: nil
        )
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        clearSettledRekeyMappings(to: windowId)
    }

    func removeWindowState(windowId: Int) -> [AXFrameTerminalDelivery] {
        let deliveries = cancelObserver(for: windowId)
        appliedFrameStates.removeValue(forKey: windowId)
        pendingFrameWrites.removeValue(forKey: windowId)
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        forceApplyWindowIds.remove(windowId)
        rekeyedWindowIds.pruneRemovedWindow(windowId, hasUnsettledFrameState: hasUnsettledFrameState)
        return deliveries
    }

    func cancelFrameJob(windowId: Int) -> [AXFrameTerminalDelivery] {
        cancelFrameJob(pid: nil, windowId: windowId).deliveries
    }

    func cancelFrameJob(pid: pid_t, windowId: Int) -> AXFrameJobCancellationOutcome {
        cancelFrameJob(pid: Optional(pid), windowId: windowId)
    }

    private func cancelFrameJob(pid: pid_t?, windowId: Int) -> AXFrameJobCancellationOutcome {
        let pending = pendingFrameWrites[windowId]
        let currentFrameHint = appliedFrameStates[windowId]?.frame
        let deliveries = cancelObserver(for: windowId)
        let terminalFailure = pid.flatMap { pid in
            pending?.cancelledResult(pid: pid, windowId: windowId, currentFrameHint: currentFrameHint)
        }
        pendingFrameWrites.removeValue(forKey: windowId)
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        forceApplyWindowIds.remove(windowId)
        clearSettledRekeyMappings(to: windowId)
        return AXFrameJobCancellationOutcome(
            deliveries: deliveries,
            terminalFailure: terminalFailure
        )
    }

    func suppressFrameWrite(windowId: Int) -> [AXFrameTerminalDelivery] {
        let deliveries = cancelObserver(for: windowId)
        appliedFrameStates.removeValue(forKey: windowId)
        pendingFrameWrites.removeValue(forKey: windowId)
        recentFrameWriteFailures.removeValue(forKey: windowId)
        retryBudgetByWindowId.removeValue(forKey: windowId)
        forceApplyWindowIds.remove(windowId)
        clearSettledRekeyMappings(to: windowId)
        return deliveries
    }

    func resolvedWindowId(for windowId: Int) -> Int {
        rekeyedWindowIds.resolve(for: windowId)
    }

    func cancelAllPendingFrameState() -> [AXFrameTerminalDelivery] {
        let deliveries = observers.cancelAll { windowId in
            pendingFrameWrites[windowId]?.frame ?? appliedFrameStates[windowId]?.frame
        }
        pendingFrameWrites.removeAll()
        recentFrameWriteFailures.removeAll()
        retryBudgetByWindowId.removeAll()
        forceApplyWindowIds.removeAll()
        rekeyedWindowIds.removeAll()

        return deliveries
    }

    private func makeNextFrameApplicationRequestId() -> AXFrameRequestId {
        defer { nextFrameApplicationRequestId += 1 }
        return nextFrameApplicationRequestId
    }

    private func cancelObserver(for windowId: Int) -> [AXFrameTerminalDelivery] {
        observers.cancel(
            for: windowId,
            currentFrameHint: pendingFrameWrites[windowId]?.frame ?? appliedFrameStates[windowId]?.frame
        )
    }

    private func clearSettledRekeyMappings(to windowId: Int) {
        rekeyedWindowIds.clearSettled(to: windowId, hasUnsettledFrameState: hasUnsettledFrameState)
    }

    private func hasUnsettledFrameState(for windowId: Int) -> Bool {
        pendingFrameWrites[windowId] != nil
            || retryBudgetByWindowId[windowId] != nil
            || observers.requestId(for: windowId) != nil
    }
}

extension AXFrameApplicationLedger {
    func prepareFrameApplication(
        _ target: AXFrameApplicationTarget,
        isRetry: Bool,
        verify: Bool = true,
        terminalObserver: AXFrameApplicationTerminalObserver?,
        traceOrigin: FrameEffectTraceOrigin = .none,
        parentTraceRequestId: UInt64 = 0
    ) -> AXFrameEnqueueDecision {
        let preparation = AXFramePreparation(
            target: target,
            options: .init(
                isRetry: isRetry,
                verify: verify,
                terminalObserver: terminalObserver,
                traceOrigin: traceOrigin,
                parentTraceRequestId: parentTraceRequestId
            ),
            cachedState: appliedFrameStates[target.windowId],
            pendingWrite: pendingFrameWrites[target.windowId]
        )
        let shouldForceApply = forceApplyWindowIds.remove(target.windowId) != nil
        if !shouldForceApply, let decision = cachedEnqueueDecision(preparation) {
            return decision
        }
        let deliveries = !isRetry && observers.needsReplacement(
            for: target.windowId, expectedWindow: target.expectedWindow,
            targetFrame: target.frame, components: preparation.components
        ) ? cancelObserver(for: target.windowId) : []
        let existingObserverRequestId = observers.requestId(for: target.windowId)
        let request = preparation.request(id: makeNextFrameApplicationRequestId())
        publishPendingFrameWrite(
            request,
            cachedState: preparation.cachedState,
            isRetry: isRetry,
            shouldForceApply: shouldForceApply
        )
        observers.register(for: request, replacing: existingObserverRequestId, terminalObserver: terminalObserver)
        if !isRetry {
            retryBudgetByWindowId[target.windowId] = 1
        }
        preparation.recordPrepared(requestId: request.requestId)
        return AXFrameEnqueueDecision(request: request, deliveries: deliveries, shouldCancelPendingRetry: !isRetry)
    }

    private func cachedEnqueueDecision(_ preparation: AXFramePreparation) -> AXFrameEnqueueDecision? {
        if preparation.matchesPendingWrite {
            return preparation.coalescedDecision(observers: observers)
        }
        guard preparation.pendingWrite == nil else { return nil }
        let failure = recentFrameWriteFailures[preparation.target.windowId]
        if let failure, preparation.matchesTerminalRefusal(failure) {
            let requestId = preparation.options.terminalObserver == nil ? 0 : makeNextFrameApplicationRequestId()
            return preparation.refusedDecision(failure, requestId: requestId)
        }
        guard failure == nil, preparation.matchesVerifiedFrame else { return nil }
        let requestId = preparation.options.terminalObserver == nil ? 0 : makeNextFrameApplicationRequestId()
        return preparation.noOpDecision(requestId: requestId)
    }

    private func publishPendingFrameWrite(
        _ request: AXFrameApplicationRequest,
        cachedState: AXAppliedFrameState?,
        isRetry: Bool,
        shouldForceApply: Bool
    ) {
        if let cachedState, cachedState.convergedTargetFrame != nil {
            appliedFrameStates[request.windowId] = AXAppliedFrameState(
                frame: cachedState.frame,
                verifiedComponents: cachedState.verifiedComponents,
                convergedTargetFrame: nil
            )
        }
        pendingFrameWrites[request.windowId] = AXPendingFrameWrite(
            frame: request.frame,
            components: request.components,
            verify: request.verify,
            expectedWindow: request.expectedWindow,
            requestId: request.requestId,
            traceRequestId: request.traceRequestId
        )
        if !isRetry,
           recentFrameWriteFailures[request.windowId]?.retainsTerminalSizeRefusal(
               components: request.components,
               enforcedSizeTarget: shouldForceApply ? nil : request.frame
           ) != true
        {
            recentFrameWriteFailures.removeValue(forKey: request.windowId)
        }
    }

    func handleFrameApplyResults(
        _ results: [AXFrameApplyResult],
        onAcceptedSuccess: (AXFrameApplyResult) -> Void = { _ in },
        onDiscardedResult: (AXFrameApplyResult) -> Void = { _ in }
    ) -> AXFrameApplyOutcome {
        var outcome = AXFrameApplyOutcome()
        for result in results {
            let resolvedWindowId = rekeyedWindowIds.resolve(for: result.windowId)
            let resultResolvedThroughRekey = resolvedWindowId != result.windowId
            let resolvedResult = resolvedWindowId == result.windowId ? result : result.rekeyed(to: resolvedWindowId)
            guard pendingFrameWrites[resolvedWindowId]?.matchesResult(resolvedResult) == true else {
                onDiscardedResult(result)
                continue
            }

            pendingFrameWrites.removeValue(forKey: resolvedWindowId)

            if let confirmedFrame = resolvedResult.confirmedFrame {
                settleConfirmedFrame(
                    resolvedResult,
                    confirmedFrame: confirmedFrame,
                    outcome: &outcome,
                    onAcceptedSuccess: onAcceptedSuccess
                )
                continue
            }

            let priorFailure = recordFrameWriteFailure(resolvedResult)
            if prepareFrameRetry(
                after: resolvedResult,
                resultResolvedThroughRekey: resultResolvedThroughRekey,
                outcome: &outcome
            ) {
                continue
            }
            settleTerminalFrameResult(
                resolvedResult,
                priorFailure: priorFailure,
                outcome: &outcome,
                onAcceptedSuccess: onAcceptedSuccess
            )
        }
        return outcome
    }

    private func settleConfirmedFrame(
        _ result: AXFrameApplyResult,
        confirmedFrame: CGRect,
        outcome: inout AXFrameApplyOutcome,
        onAcceptedSuccess: (AXFrameApplyResult) -> Void
    ) {
        let windowId = result.windowId
        let priorState = appliedFrameStates[windowId]
        appliedFrameStates[windowId] = AXAppliedFrameState.accepting(
            confirmedFrame,
            writeResult: result.writeResult,
            priorState: priorState
        )
        let observedRefusedSize = recentFrameWriteFailures[windowId]?
            .observedFrameShowsRefusedSize(result) == true
        if observedRefusedSize || recentFrameWriteFailures[windowId]?.retainsTerminalSizeRefusal(
            components: result.writeResult.components
        ) != true {
            recentFrameWriteFailures.removeValue(forKey: windowId)
        }
        retryBudgetByWindowId.removeValue(forKey: windowId)
        onAcceptedSuccess(result)
        outcome.deliveries.append(contentsOf: observers.complete(with: result))
        clearSettledRekeyMappings(to: windowId)
    }

    private func recordFrameWriteFailure(_ result: AXFrameApplyResult) -> AXRecentFrameWriteFailure? {
        let windowId = result.windowId
        let priorFailure = recentFrameWriteFailures[windowId]
        if let failure = AXRecentFrameWriteFailure.recording(result, priorFailure: priorFailure) {
            recentFrameWriteFailures[windowId] = failure
        }
        return priorFailure
    }

    private func prepareFrameRetry(
        after result: AXFrameApplyResult,
        resultResolvedThroughRekey: Bool,
        outcome: inout AXFrameApplyOutcome
    ) -> Bool {
        let windowId = result.windowId
        let remainingRetries = retryBudgetByWindowId[windowId] ?? 0
        guard remainingRetries > 0,
              result.shouldRetryFrameWrite(resultResolvedThroughRekey: resultResolvedThroughRekey) else { return false }
        retryBudgetByWindowId[windowId] = remainingRetries - 1
        forceApplyWindowIds.insert(windowId)

        outcome.retries.append(
            AXFrameRetryRequest(
                requestId: result.requestId,
                pid: result.pid,
                windowId: windowId,
                expectedWindow: result.expectedWindow,
                frame: result.targetFrame,
                currentFrameHint: result.currentFrameHint,
                components: result.writeResult.components,
                traceRequestId: result.traceRequestId
            )
        )
        return true
    }

    private func settleTerminalFrameResult(
        _ result: AXFrameApplyResult,
        priorFailure: AXRecentFrameWriteFailure?,
        outcome: inout AXFrameApplyOutcome,
        onAcceptedSuccess: (AXFrameApplyResult) -> Void
    ) {
        let windowId = result.windowId
        retryBudgetByWindowId.removeValue(forKey: windowId)
        let assessment = AXFrameFailureAssessment(result: result, priorFailure: priorFailure)
        if assessment.stableSizeClamp {
            outcome.stableSizeClamps.append(result)
        }
        if let observedFrame = assessment.convergedFrame {
            settleSizeConvergence(
                result,
                observedFrame: observedFrame,
                outcome: &outcome,
                onAcceptedSuccess: onAcceptedSuccess
            )
            return
        }
        if let refusal = assessment.terminalRefusal {
            recentFrameWriteFailures[windowId]?.isTerminalRefusal = true
            outcome.terminalRefusals.append(refusal)
        }
        let deliveries = observers.complete(with: result)
        outcome.deliveries.append(contentsOf: deliveries)
        outcome.terminalFailures.append(result)
        clearSettledRekeyMappings(to: windowId)
    }

    private func settleSizeConvergence(
        _ result: AXFrameApplyResult,
        observedFrame: CGRect,
        outcome: inout AXFrameApplyOutcome,
        onAcceptedSuccess: (AXFrameApplyResult) -> Void
    ) {
        let windowId = result.windowId
        appliedFrameStates[windowId] = AXAppliedFrameState(
            frame: observedFrame,
            verifiedComponents: .all,
            convergedTargetFrame: result.targetFrame
        )
        let acceptedResult = AXFrameApplyResult.acceptedSizeConvergenceResult(
            result,
            observedFrame: observedFrame
        )
        recentFrameWriteFailures.removeValue(forKey: windowId)
        FrameApplyTrace.recordAcceptedSizeConvergence(acceptedResult)
        onAcceptedSuccess(acceptedResult)
        outcome.deliveries.append(
            contentsOf: observers.complete(with: acceptedResult)
        )
        clearSettledRekeyMappings(to: windowId)
    }
}
