// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
enum FullRescanCandidateSelection {
    static func selectFullRescanCandidates(
        _ candidatesByWindowId: [Int: [FullRescanWindowCandidate]],
        activationPolicyByPID: [pid_t: NSApplication.ActivationPolicy],
        preservingPIDsByWindowId: [Int: pid_t]
    ) -> [FullRescanWindowCandidate] {
        var selected: [FullRescanWindowCandidate] = []
        selected.reserveCapacity(candidatesByWindowId.count)
        for windowId in candidatesByWindowId.keys.sorted() {
            guard let candidates = candidatesByWindowId[windowId], var current = candidates.first else {
                continue
            }
            for candidate in candidates.dropFirst() {
                let preference = Self.fullRescanCandidatePreference(
                    candidate,
                    over: current,
                    activationPolicyByPID: activationPolicyByPID,
                    ownerPID: candidate.windowServerOwnerPID ?? current.windowServerOwnerPID,
                    existingPID: preservingPIDsByWindowId[windowId]
                )
                let winner = preference.prefersCandidate ? candidate : current
                let loser = preference.prefersCandidate ? current : candidate
                WindowAdmissionTrace.record(
                    .init(
                        action: .fullRescanRejected,
                        pid: loser.pid,
                        windowId: windowId,
                        axPid: loser.axPid,
                        windowServerPid: loser.windowServerOwnerPID,
                        competingPid: winner.pid,
                        reason: preference.reason.rawValue,
                        outcome: preference.prefersCandidate ? "replaced" : "not_preferred",
                        callbackGeneration: loser.callbackGeneration,
                        manageable: loser.isManageable,
                        axRef: loser.axRef
                    )
                )
                if preference.prefersCandidate {
                    current = candidate
                }
            }
            selected.append(current)
        }
        return selected
    }

    static func oneShotPromotionCandidatesByPID(
        _ selectedCandidates: [FullRescanWindowCandidate]
    ) -> [pid_t: [FullRescanWindowCandidate]] {
        Dictionary(
            grouping: selectedCandidates.filter { $0.enumerationRoute == .oneShot },
            by: \.pid
        )
    }

    static func forEachOneShotPromotionBatch(
        _ selectedCandidates: [FullRescanWindowCandidate],
        operation: (pid_t, [FullRescanWindowCandidate]) async throws -> Void
    ) async rethrows {
        let grouped = oneShotPromotionCandidatesByPID(selectedCandidates)
        for pid in grouped.keys.sorted() {
            guard let candidates = grouped[pid] else { continue }
            try await operation(pid, candidates)
        }
    }

    static func fullRescanCandidatePreference(
        _ candidate: FullRescanWindowCandidate,
        over current: FullRescanWindowCandidate,
        activationPolicyByPID: [pid_t: NSApplication.ActivationPolicy],
        ownerPID: pid_t?,
        existingPID: pid_t?
    ) -> FullRescanCandidatePreference {
        if candidate.isManageable != current.isManageable {
            return .init(prefersCandidate: candidate.isManageable, reason: .manageability)
        }
        let candidateIsExisting = candidate.pid == existingPID
        let currentIsExisting = current.pid == existingPID
        if candidateIsExisting != currentIsExisting {
            return .init(prefersCandidate: candidateIsExisting, reason: .preservedLogicalPID)
        }
        let candidateIsRegular = activationPolicyByPID[candidate.pid] == .regular
        let currentIsRegular = activationPolicyByPID[current.pid] == .regular
        if candidateIsRegular != currentIsRegular {
            return .init(prefersCandidate: candidateIsRegular, reason: .regularActivationPolicy)
        }
        let candidateHostsAXElement = candidate.pid == candidate.axPid
        let currentHostsAXElement = current.pid == current.axPid
        if candidateHostsAXElement != currentHostsAXElement {
            return .init(prefersCandidate: candidateHostsAXElement, reason: .axHostPID)
        }
        let candidateOwnsWindow = candidate.pid == ownerPID
        let currentOwnsWindow = current.pid == ownerPID
        if candidateOwnsWindow != currentOwnsWindow {
            return .init(prefersCandidate: candidateOwnsWindow, reason: .windowServerOwnerPID)
        }
        guard candidate.pid != current.pid else {
            return .init(prefersCandidate: false, reason: .stableFirstCandidate)
        }
        return .init(prefersCandidate: candidate.pid < current.pid, reason: .lowerPID)
    }
}
