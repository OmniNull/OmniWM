// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class HiddenBarCaptureSession {
    private var captureTask: Task<Void, Never>?
    private var captureBundleIDs: Set<String> = []
    private var captureGeneration = 0
    private weak var controller: HiddenBarController?
    private let itemService: MenuBarItemService
    private let iconCache: HiddenBarIconCache

    init(itemService: MenuBarItemService, iconCache: HiddenBarIconCache) {
        self.itemService = itemService
        self.iconCache = iconCache
    }

    func connect(controller: HiddenBarController) {
        self.controller = controller
    }

    var bundleIDs: Set<String> {
        captureBundleIDs
    }

    func reconcile(
        snapshot: HiddenBarRunningAppsSnapshot,
        captureBundleIDs requestedCaptureBundleIDs: Set<String>
    ) {
        guard let controller else { return }
        let eligible = controller.captureEligibleBundleIDs.intersection(snapshot.bundleIDs)
        let targets = captureBundleIDs
            .union(requestedCaptureBundleIDs)
            .intersection(eligible)
        guard !targets.isEmpty else {
            if !captureBundleIDs.isEmpty {
                cancel()
            }
            controller.applyConcealment()
            return
        }
        guard targets != captureBundleIDs || captureTask == nil else {
            controller.applyConcealment()
            return
        }
        scheduleCapture(
            bundleIDs: targets,
            snapshot: snapshot
        )
    }

    private func scheduleCapture(
        bundleIDs: Set<String>,
        snapshot: HiddenBarRunningAppsSnapshot
    ) {
        guard let controller else { return }
        let targets = bundleIDs
            .intersection(controller.captureEligibleBundleIDs)
            .intersection(snapshot.bundleIDs)
        guard !targets.isEmpty else {
            controller.applyConcealment()
            return
        }

        captureTask?.cancel()
        captureGeneration += 1
        captureBundleIDs = targets
        let allowEmptyBundleIDs = targets.filter { iconCache.hasResolvedItems(for: $0) }
        controller.applyConcealment()
        let generation = captureGeneration
        captureTask = Task { @MainActor [weak controller] in
            guard let controller else { return }
            await controller.capture.resolveAndCapture(
                controller: controller,
                snapshot: snapshot,
                targets: targets,
                allowEmptyBundleIDs: Set(allowEmptyBundleIDs),
                generation: generation
            )
        }
    }

    private func finishCapture(
        controller: HiddenBarController,
        generation: Int,
        targets: Set<String>,
        resolution: MenuBarItemResolution,
        icons: [MenuBarItemKey: CapturedIcon]
    ) {
        guard generation == captureGeneration else { return }
        let snapshot = HiddenBarRunningAppsSnapshot.current()
        let validTargets = targets
            .intersection(controller.configuredHiddenBundleIDs)
            .subtracting(controller.revealedBundleIDs)
            .intersection(snapshot.bundleIDs)
        let resolved = resolution.itemsByBundleID.filter { validTargets.contains($0.key) }
        let captured = icons.filter { validTargets.contains($0.key.bundleID) }
        iconCache.replaceResolvedItems(
            resolved,
            capturedIcons: captured,
            replacingCapturedIcons: true
        )
        captureTask = nil
        captureBundleIDs.removeAll(keepingCapacity: true)
        controller.applyConcealment(verifiedMenuItemBundleIDs: snapshot.verifiedMenuItemBundleIDs(for: resolved))
    }

    func cancel() {
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        captureBundleIDs.removeAll(keepingCapacity: true)
    }

    func refreshVisibleIcons(_ bundleIDs: Set<String>) async {
        guard let controller else { return }
        let snapshot = HiddenBarRunningAppsSnapshot.current()
        let targets = bundleIDs.intersection(snapshot.bundleIDs)
        guard !targets.isEmpty else { return }
        let resolution = await itemService.resolveItems(
            candidates: snapshot.candidates,
            bundleIDs: targets,
            allowEmptyBundleIDs: targets.filter { iconCache.hasResolvedItems(for: $0) }
        )
        guard !Task.isCancelled else { return }
        let icons = await HiddenBarIconCaptureService.captureVisible(
            resolution.items,
            timeout: HiddenBarIconCaptureService.captureDeadline
        )
        guard !Task.isCancelled else { return }
        let currentSnapshot = HiddenBarRunningAppsSnapshot.current()
        let validTargets = targets
            .intersection(controller.configuredHiddenBundleIDs)
            .intersection(controller.revealedBundleIDs)
            .intersection(currentSnapshot.bundleIDs)
        guard !validTargets.isEmpty else { return }
        let resolved = resolution.itemsByBundleID.filter { validTargets.contains($0.key) }
        let captured = icons.filter { validTargets.contains($0.key.bundleID) }
        iconCache.replaceResolvedItems(
            resolved,
            capturedIcons: captured,
            replacingCapturedIcons: true
        )
    }

    private func resolveAndCapture(
        controller: HiddenBarController,
        snapshot: HiddenBarRunningAppsSnapshot,
        targets: Set<String>,
        allowEmptyBundleIDs: Set<String>,
        generation: Int
    ) async {
        let resolution = await itemService.resolveItems(
            candidates: snapshot.candidates,
            bundleIDs: targets,
            allowEmptyBundleIDs: allowEmptyBundleIDs
        )
        guard !Task.isCancelled, generation == captureGeneration else { return }
        let icons = await HiddenBarIconCaptureService.captureVisible(
            resolution.items,
            timeout: HiddenBarIconCaptureService.captureDeadline
        )
        guard !Task.isCancelled, generation == captureGeneration else { return }
        finishCapture(
            controller: controller,
            generation: generation,
            targets: targets,
            resolution: resolution,
            icons: icons
        )
    }
}
