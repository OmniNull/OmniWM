// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension HiddenBarController {
    var configuredHiddenBundleIDs: Set<String> {
        Set(settings.hiddenBar.hiddenBundleIDs)
    }

    var revealedBundleIDs: Set<String> {
        temporarilyRevealed
    }

    var captureEligibleBundleIDs: Set<String> {
        HiddenBarConcealmentPolicy.effectiveHiddenBundleIDs(
            configured: configuredHiddenBundleIDs,
            temporarilyRevealed: temporarilyRevealed
        )
    }

    func applyConcealment(verifiedMenuItemBundleIDs: Set<String> = []) {
        let configured = Set(settings.hiddenBar.hiddenBundleIDs)
        guard HiddenBarConcealmentPolicy.wantsRefresh(
            enabled: settings.effectiveHiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else { return }
        hider.apply(
            configuredBundleIDs: configured,
            hiddenBundleIDs: HiddenBarConcealmentPolicy.effectiveHiddenBundleIDs(
                configured: configured,
                temporarilyRevealed: temporarilyRevealed,
                pendingCapture: capture.bundleIDs
            ),
            verifiedMenuItemBundleIDs: verifiedMenuItemBundleIDs
        )
    }

    func concealRevealed(_ bundleIDs: Set<String>) {
        temporarilyRevealed.subtract(bundleIDs)
        applyConcealment()
    }

    func concealAllRevealed() {
        temporarilyRevealed.removeAll(keepingCapacity: true)
        applyConcealment()
    }

    func handleRunningApplicationChanged(bundleID: String?, terminated: Bool) {
        let configured = Set(settings.hiddenBar.hiddenBundleIDs)
        guard HiddenBarConcealmentPolicy.wantsRefresh(
            enabled: settings.effectiveHiddenBarEnabled,
            available: hider.available,
            hiddenBundleIDs: configured
        ) else { return }

        if terminated, let bundleID {
            temporarilyRevealed.remove(bundleID)
            if menuSession.bundleID == bundleID {
                dismissPanel()
            }
        }

        let snapshot = HiddenBarRunningAppsSnapshot.current()
        temporarilyRevealed.formIntersection(snapshot.bundleIDs)
        cancelActivationIfInvalid(configured: configured, snapshot: snapshot)
        cancelReconcealIfNoTemporaryReveals()
        iconCache.prune(keeping: configured.intersection(snapshot.bundleIDs))
        let captures: Set<String>
        if !terminated, let bundleID, configured.contains(bundleID) {
            captures = [bundleID]
        } else {
            captures = []
        }
        capture.reconcile(snapshot: snapshot, captureBundleIDs: captures)
        refreshPanelIfVisible()
    }
}
