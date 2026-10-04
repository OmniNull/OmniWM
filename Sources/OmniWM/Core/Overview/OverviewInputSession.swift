// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import Foundation
import QuartzCore

@MainActor
final class OverviewInputSession {
    private let environment: OverviewEnvironment
    private var keyEventMonitor: Any?
    private var applicationDidResignObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var inputHandler: OverviewInputHandler?
    private var onResignActive: (() -> Void)?
    private var onDisplayChange: (() -> Void)?

    init(environment: OverviewEnvironment) {
        self.environment = environment
    }

    func start(
        inputHandler: OverviewInputHandler?,
        onResignActive: @escaping () -> Void,
        onDisplayChange: @escaping () -> Void
    ) {
        self.inputHandler = inputHandler
        self.onResignActive = onResignActive
        self.onDisplayChange = onDisplayChange
        installKeyEventMonitor()
        installApplicationDidResignObserver()
        installScreenParametersObserver()
    }

    func stop() {
        removeKeyEventMonitor()
        removeApplicationDidResignObserver()
        removeScreenParametersObserver()
        inputHandler = nil
        onResignActive = nil
        onDisplayChange = nil
    }

    private func installKeyEventMonitor() {
        removeKeyEventMonitor()
        keyEventMonitor = environment.addLocalEventMonitor([.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.inputHandler?.handleKeyDown(event) == true ? nil : event
        }
    }

    private func removeKeyEventMonitor() {
        if let keyEventMonitor {
            environment.removeEventMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
    }

    private func installApplicationDidResignObserver() {
        removeApplicationDidResignObserver()
        applicationDidResignObserver = environment.notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onResignActive?()
            }
        }
    }

    private func removeApplicationDidResignObserver() {
        if let applicationDidResignObserver {
            environment.notificationCenter.removeObserver(applicationDidResignObserver)
            self.applicationDidResignObserver = nil
        }
    }

    private func installScreenParametersObserver() {
        removeScreenParametersObserver()
        screenParametersObserver = environment.notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onDisplayChange?()
            }
        }
    }

    private func removeScreenParametersObserver() {
        if let screenParametersObserver {
            environment.notificationCenter.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
    }
}
