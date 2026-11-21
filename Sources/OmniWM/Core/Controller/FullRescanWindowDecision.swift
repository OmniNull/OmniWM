// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct FullRescanCandidateIdentity {
    let token: WindowToken
    let existingEntry: WindowState?
    let bundleId: String?

    var isTracked: Bool {
        existingEntry?.token != nil
    }
}

struct FullRescanWindowDecision {
    let appFullscreen: Bool
    let evaluation: WMController.WindowDecisionEvaluation
    let deferredTrackedEntry: WindowState?
    let createPlacementContext: WindowCreatePlacementContext?
    let placementOrigin: WorkspacePlacementOrigin
    let shouldPreservePreFullscreenState: Bool
    let effectiveTrackedMode: TrackedWindowMode?
}
