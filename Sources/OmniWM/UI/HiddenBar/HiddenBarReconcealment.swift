// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class HiddenBarReconcealment {
    private struct Countdown {
        let startedAt: ContinuousClock.Instant
        var remaining: Duration
        var lastSample: ContinuousClock.Instant
        var previousMenuOpen: Bool?
        var consecutiveDeferrals = 0
        var consecutiveUnknownStates = 0
    }

    private weak var controller: HiddenBarController?
    private let itemService: MenuBarItemService
    private let performance: HiddenBarPerformanceCapture
    private(set) var task: Task<Void, Never>?
    private var generation = 0
    var menuGuardSleeper: @MainActor (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    var menuGuardNow: @MainActor () -> ContinuousClock.Instant = { ContinuousClock().now }
    var menuOpenProviderForTests: (@MainActor (Set<pid_t>) async -> Bool?)?

    init(itemService: MenuBarItemService, performance: HiddenBarPerformanceCapture) {
        self.itemService = itemService
        self.performance = performance
    }

    func connect(controller: HiddenBarController) {
        self.controller = controller
    }

    func cancel(reason: HiddenBarController.MenuGuardTerminalReason) {
        if task != nil { performance.recordTaskCancelled(reason: reason) }
        generation += 1
        task?.cancel()
        task = nil
    }

    func cancelIfRunning(reason: HiddenBarController.MenuGuardTerminalReason) {
        guard task != nil else { return }
        generation += 1
        performance.recordTaskCancelled(reason: reason)
        task?.cancel()
        task = nil
    }

    func schedule(intervalSeconds: Double) {
        guard let controller else { return }
        if task != nil { performance.recordTaskCancelled(reason: .superseded) }
        task?.cancel()
        generation += 1
        let generation = generation
        let interval = HiddenBarSettingsPolicy.validatedRehideIntervalSeconds(intervalSeconds)
        performance.recordTaskStarted()
        task = Task { @MainActor [weak controller] in
            guard let controller else { return }
            await controller.reconcealment.run(controller: controller, generation: generation, interval: interval)
        }
    }

    private func run(controller: HiddenBarController, generation: Int, interval: Double) async {
        let startedAt = menuGuardNow()
        var countdown = Countdown(startedAt: startedAt, remaining: .seconds(interval), lastSample: startedAt)
        guard await waitForRehideInterval(controller: controller, generation: generation, countdown: &countdown) else {
            return
        }
        await concealWhenMenusClose(controller: controller, generation: generation, countdown: &countdown)
    }

    private func waitForRehideInterval(
        controller: HiddenBarController,
        generation: Int,
        countdown: inout Countdown
    ) async -> Bool {
        while countdown.remaining > .zero, !Task.isCancelled {
            try? await menuGuardSleeper(
                HiddenBarMenuGuardPolicy.menuGuardRetryDelay(consecutiveDeferrals: countdown.consecutiveDeferrals)
            )
            guard isActive(controller: controller, generation: generation, startedAt: countdown.startedAt) else {
                return false
            }
            let ownerPIDs = HiddenBarRunningAppsSnapshot.menuOwnerPIDs(for: controller.revealedBundleIDs)
            performance.recordQuery()
            let menuOpen = await menuOpen(ownerPIDs: ownerPIDs)
            guard isActive(controller: controller, generation: generation, startedAt: countdown.startedAt) else {
                return false
            }
            let now = menuGuardNow()
            countdown.remaining = HiddenBarMenuGuardPolicy.rehideRemaining(
                remaining: countdown.remaining,
                elapsed: countdown.lastSample.duration(to: now),
                previousMenuOpen: countdown.previousMenuOpen,
                menuOpen: menuOpen
            )
            countdown.lastSample = now
            countdown.previousMenuOpen = menuOpen
            guard !recordMenuGuardResult(menuOpen, controller: controller, countdown: &countdown) else { return false }
        }
        return !Task.isCancelled && generation == self.generation
    }

    private func concealWhenMenusClose(
        controller: HiddenBarController,
        generation: Int,
        countdown: inout Countdown
    ) async {
        while !Task.isCancelled, generation == self.generation {
            guard !terminateIfWatchdogExpired(controller: controller, startedAt: countdown.startedAt) else { return }
            let revealed = controller.revealedBundleIDs
            guard !revealed.isEmpty else {
                performance.recordTerminal(reason: .noRevealedItems)
                task = nil
                return
            }
            let ownerPIDs = HiddenBarRunningAppsSnapshot.menuOwnerPIDs(for: revealed)
            performance.recordQuery()
            let menuOpenBeforeRefresh = await menuOpen(ownerPIDs: ownerPIDs)
            guard isActive(controller: controller, generation: generation, startedAt: countdown.startedAt)
            else { return }
            if menuOpenBeforeRefresh != false {
                guard await deferForMenuState(menuOpenBeforeRefresh, controller: controller, countdown: &countdown)
                else {
                    return
                }
                continue
            }
            _ = recordMenuGuardResult(menuOpenBeforeRefresh, controller: controller, countdown: &countdown)
            await controller.capture.refreshVisibleIcons(revealed)
            guard isActive(controller: controller, generation: generation, startedAt: countdown.startedAt)
            else { return }
            performance.recordQuery()
            let menuOpenAfterRefresh = await menuOpen(
                ownerPIDs: HiddenBarRunningAppsSnapshot.menuOwnerPIDs(for: controller.revealedBundleIDs)
            )
            guard isActive(controller: controller, generation: generation, startedAt: countdown.startedAt)
            else { return }
            guard menuOpenAfterRefresh == false else {
                guard await deferForMenuState(menuOpenAfterRefresh, controller: controller, countdown: &countdown)
                else {
                    return
                }
                continue
            }
            controller.concealRevealed(revealed)
            performance.recordTerminal(reason: .concealed)
            task = nil
            return
        }
    }

    private func deferForMenuState(
        _ menuOpen: Bool?, controller: HiddenBarController, countdown: inout Countdown
    ) async -> Bool {
        guard !recordMenuGuardResult(menuOpen, controller: controller, countdown: &countdown) else { return false }
        try? await menuGuardSleeper(
            HiddenBarMenuGuardPolicy.menuGuardRetryDelay(consecutiveDeferrals: countdown.consecutiveDeferrals)
        )
        return true
    }

    private func isActive(
        controller: HiddenBarController, generation: Int, startedAt: ContinuousClock.Instant
    ) -> Bool {
        guard !Task.isCancelled, generation == self.generation else { return false }
        return !terminateIfWatchdogExpired(controller: controller, startedAt: startedAt)
    }

    private func recordMenuGuardResult(
        _ menuOpen: Bool?, controller: HiddenBarController, countdown: inout Countdown
    ) -> Bool {
        guard menuOpen != false else {
            countdown.consecutiveDeferrals = 0
            countdown.consecutiveUnknownStates = 0
            return false
        }
        countdown.consecutiveDeferrals += 1
        countdown.consecutiveUnknownStates = menuOpen == nil ? countdown.consecutiveUnknownStates + 1 : 0
        performance.recordDeferral(countdown.consecutiveDeferrals)
        guard HiddenBarMenuGuardPolicy.shouldTerminateMenuGuardForUnknownState(
            consecutiveUnknownStates: countdown.consecutiveUnknownStates
        ) else { return false }
        forceTerminalConcealment(controller: controller, reason: .unknownStateLimit)
        return true
    }

    private func terminateIfWatchdogExpired(
        controller: HiddenBarController, startedAt: ContinuousClock.Instant
    ) -> Bool {
        guard HiddenBarMenuGuardPolicy.menuGuardWatchdogExpired(elapsed: startedAt.duration(to: menuGuardNow())) else {
            return false
        }
        forceTerminalConcealment(controller: controller, reason: .watchdog)
        return true
    }

    private func forceTerminalConcealment(
        controller: HiddenBarController, reason: HiddenBarController.MenuGuardTerminalReason
    ) {
        controller.concealAllRevealed()
        performance.recordTerminal(reason: reason)
        task = nil
    }

    private func menuOpen(ownerPIDs: Set<pid_t>) async -> Bool? {
        if let menuOpenProviderForTests { return await menuOpenProviderForTests(ownerPIDs) }
        return await itemService.isMenuOpen(ownerPIDs: ownerPIDs)
    }
}
