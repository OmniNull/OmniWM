// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class WorkspaceBarRevealMonitor {
    var onRevealChanged: ((Bool) -> Void)?
    private(set) var isRevealed = false

    private var modifier: WorkspaceBarRevealModifier
    private var holdMilliseconds: Int64
    private(set) var holdTask: Task<Void, Never>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let sleep: @MainActor (Duration) async throws -> Void

    init(
        modifier: WorkspaceBarRevealModifier = .off,
        holdMilliseconds: Double = 200,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.modifier = modifier
        self.holdMilliseconds = Self.normalizedHoldMilliseconds(holdMilliseconds)
        self.sleep = sleep
    }

    func start(modifier: WorkspaceBarRevealModifier, holdMilliseconds: Double) {
        self.modifier = modifier
        self.holdMilliseconds = Self.normalizedHoldMilliseconds(holdMilliseconds)
        installEventMonitors()
        handleFlagsChanged(rawFlags: UInt64(NSEvent.modifierFlags.rawValue))
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        resetReveal()
    }

    func resetReveal() {
        holdTask?.cancel()
        holdTask = nil
        setRevealed(false)
    }

    func handleFlagsChanged(rawFlags: UInt64) {
        let held = modifier.isHeld(inRawFlags: rawFlags)
        if held {
            guard !isRevealed, holdTask == nil else { return }
            guard holdMilliseconds > 0 else {
                setRevealed(true)
                return
            }
            let delay = holdMilliseconds
            let sleep = sleep
            holdTask = Task { @MainActor [weak self, delay] in
                try? await sleep(.milliseconds(delay))
                guard let self, !Task.isCancelled else { return }
                holdTask = nil
                setRevealed(true)
            }
        } else {
            holdTask?.cancel()
            holdTask = nil
            setRevealed(false)
        }
    }

    private func installEventMonitors() {
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(rawFlags: UInt64(event.modifierFlags.rawValue))
                return event
            }
        }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleFlagsChanged(rawFlags: UInt64(event.modifierFlags.rawValue))
                }
            }
        }
    }

    private func setRevealed(_ revealed: Bool) {
        guard isRevealed != revealed else { return }
        isRevealed = revealed
        onRevealChanged?(revealed)
    }

    private static func normalizedHoldMilliseconds(_ value: Double) -> Int64 {
        guard value.isFinite else { return 200 }
        return Int64(min(max(value.rounded(), 0), 1000))
    }
}
