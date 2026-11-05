// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
final class FloatDemotionTracker {
    private var floatDemotionFirstSamplesByToken: [WindowToken: ContinuousClock.Instant] = [:]
    static let floatDemotionStabilityInterval: Duration = .milliseconds(300)
    var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }

    func clearSample(for token: WindowToken) {
        floatDemotionFirstSamplesByToken.removeValue(forKey: token)
    }

    func mode(
        for token: WindowToken,
        decision: WindowDecision
    ) -> TrackedWindowMode {
        guard !decision.heuristicReasons.contains(.attributeFetchFailed),
              !decision.heuristicReasons.contains(.disabledFullscreenButton),
              !decision.heuristicReasons.contains(.missingFullscreenButton),
              !decision.heuristicReasons.contains(.nonStandardSubrole),
              !decision.heuristicReasons.contains(.noButtonsOnNonStandardSubrole)
        else {
            return .tiling
        }

        let now = self.now()
        guard let firstSampledAt = floatDemotionFirstSamplesByToken[token] else {
            floatDemotionFirstSamplesByToken[token] = now
            return .tiling
        }
        guard firstSampledAt.duration(to: now) >= Self.floatDemotionStabilityInterval else {
            return .tiling
        }

        floatDemotionFirstSamplesByToken.removeValue(forKey: token)
        return .floating
    }
}
