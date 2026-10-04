// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ScreenCaptureKit

@MainActor
final class ScreenCapturePermissionMonitor {
    static let shared = ScreenCapturePermissionMonitor()

    private let preflight: @MainActor () -> Bool
    private let notificationCenter: NotificationCenter
    private var deactivationObserver: NotificationCenter.ObservationToken?
    private var granted: Bool?

    init(
        preflight: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.preflight = preflight
        self.notificationCenter = notificationCenter
        deactivationObserver = notificationCenter.addObserver(
            for: NSWorkspace.DidDeactivateApplicationMessage.self
        ) { [weak self] message in
            self?.applicationDidDeactivate(bundleIdentifier: message.application.bundleIdentifier)
        }
    }

    isolated deinit {
        if let deactivationObserver { notificationCenter.removeObserver(deactivationObserver) }
    }

    var isGranted: Bool {
        granted ?? refresh()
    }

    @discardableResult
    func refresh() -> Bool {
        let value = MainThreadAXSpanTrace.measure(.screenCapturePreflight) { preflight() } succeeded: { $0 }
        granted = value
        return value
    }

    func applicationDidDeactivate(bundleIdentifier: String?) {
        guard bundleIdentifier == "com.apple.systempreferences" else { return }
        refresh()
    }

    func noteCaptureFailure(_ error: any Error) {
        guard (error as? SCStreamError)?.code == .userDeclined else { return }
        granted = false
    }
}
