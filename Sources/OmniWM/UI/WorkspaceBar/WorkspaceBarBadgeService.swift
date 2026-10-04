// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Observation

@MainActor @Observable
final class WorkspaceBarBadgeService {
    private(set) var mode: WorkspaceBarNotificationBadgeMode = .off
    private(set) var labels: [String: String] = [:]
    @ObservationIgnored private(set) var bundleIDs: Set<String> = []
    @ObservationIgnored private var interval: TimeInterval = 5
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var dockPID: pid_t?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let read: @Sendable (Set<String>, UInt64) async -> DockBadgeReadResult
    @ObservationIgnored private let reset: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(
        reader: DockBadgeReader = DockBadgeReader(),
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.notificationCenter = notificationCenter
        read = { await reader.read(bundleIDs: $0, generation: $1) }
        reset = { await reader.reset(generation: $0) }
        sleep = { try await Task.sleep(for: $0) }
    }

    init(
        notificationCenter: NotificationCenter,
        read: @escaping @Sendable (Set<String>, UInt64) async -> DockBadgeReadResult,
        reset: @escaping @Sendable (UInt64) async -> Void = { _ in },
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.read = read
        self.reset = reset
        self.sleep = sleep
    }

    isolated deinit {
        readTask?.cancel()
        timerTask?.cancel()
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    func label(for bundleID: String?) -> String? {
        guard mode != .off, let bundleID else { return nil }
        return labels[bundleID.lowercased()]
    }

    func configure(mode: WorkspaceBarNotificationBadgeMode, interval: TimeInterval, bundleIDs: Set<String>) {
        let targets = mode == .off ? [] : Set(bundleIDs.map { $0.lowercased() }.filter { !$0.isEmpty })
        let targetsChanged = targets != self.bundleIDs
        let intervalChanged = interval != self.interval
        self.mode = mode
        self.interval = interval
        guard !targets.isEmpty else {
            stop()
            return
        }
        if targetsChanged {
            generation &+= 1
            self.bundleIDs = targets
            labels = labels.filter { targets.contains($0.key) }
            installObservers()
            readNow()
        } else if intervalChanged {
            scheduleRead()
        }
    }

    func stop() {
        guard !bundleIDs.isEmpty || !observers.isEmpty else { return }
        generation &+= 1
        bundleIDs.removeAll()
        labels.removeAll()
        dockPID = nil
        timerTask?.cancel()
        timerTask = nil
        readTask?.cancel()
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        let generation = generation
        let reset = reset
        Task { @concurrent in await reset(generation) }
    }

    func applicationChanged(bundleID: String, terminated: Bool) {
        let bundleID = bundleID.lowercased()
        guard !bundleIDs.isEmpty, bundleID == "com.apple.dock" || bundleIDs.contains(bundleID) else { return }
        generation &+= 1
        if bundleID == "com.apple.dock" {
            labels.removeAll()
            dockPID = nil
        } else if terminated {
            labels.removeValue(forKey: bundleID)
        }
        readNow()
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let terminated = name == NSWorkspace.didTerminateApplicationNotification
            observers
                .append(notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          let bundleID = app.bundleIdentifier
                    else { return }
                    Task { @MainActor in self?.applicationChanged(bundleID: bundleID, terminated: terminated) }
                })
        }
    }

    private func readNow() {
        timerTask?.cancel()
        timerTask = nil
        guard !bundleIDs.isEmpty, readTask == nil else { return }
        let generation = generation
        let targets = bundleIDs
        let read = read
        readTask = Task { @concurrent [weak self] in
            let result = await read(targets, generation)
            await self?.completeRead(result, generation: generation)
        }
    }

    private func completeRead(_ result: DockBadgeReadResult, generation: UInt64) {
        readTask = nil
        guard !bundleIDs.isEmpty else { return }
        guard generation == self.generation, !Task.isCancelled else {
            readNow()
            return
        }
        var updated = dockPID == result.dockPID ? labels : [:]
        dockPID = result.dockPID
        for bundleID in result.clearedBundleIDs {
            updated.removeValue(forKey: bundleID)
        }
        for (bundleID, label) in result.labels where bundleIDs.contains(bundleID) {
            if label.isEmpty {
                updated.removeValue(forKey: bundleID)
            } else {
                updated[bundleID] = label
            }
        }
        if updated != labels { labels = updated }
        scheduleRead()
    }

    private func scheduleRead() {
        timerTask?.cancel()
        timerTask = nil
        guard !bundleIDs.isEmpty, readTask == nil else { return }
        let interval = interval
        let sleep = sleep
        timerTask = Task { @concurrent [weak self] in
            do {
                try await sleep(.seconds(interval))
            } catch {
                return
            }
            await self?.timerFired()
        }
    }

    private func timerFired() {
        guard !Task.isCancelled else { return }
        readNow()
    }
}
