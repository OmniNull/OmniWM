// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

@MainActor
final class AccessibilityPermissionMonitor {
    static let shared = AccessibilityPermissionMonitor()

    private var task: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// `com.apple.accessibility.api` is not posted reliably when the permission is revoked,
    /// so the trust state is also polled.
    static let pollInterval: Duration = .seconds(1)
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private(set) var isGranted: Bool

    private init() {
        isGranted = AXIsProcessTrusted()
        task = Task {
            let notifications = DistributedNotificationCenter.default()
                .notifications(named: Notification.Name("com.apple.accessibility.api"))
            for await _ in notifications {
                try? await Task.sleep(for: .milliseconds(250))
                let status = AXIsProcessTrusted()
                yield(status)
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                self?.yield(AXIsProcessTrusted())
            }
        }
    }

    deinit {
        task?.cancel()
        pollTask?.cancel()
        let currentContinuations = Array(continuations.values)
        for continuation in currentContinuations {
            continuation.finish()
        }
    }

    func stream(initial: Bool = true) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            if initial { continuation.yield(isGranted) }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    private func yield(_ value: Bool) {
        guard value != isGranted else { return }
        isGranted = value
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }
}
