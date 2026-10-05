// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class HiddenBarObservation {
    private enum ObserverEvent: Sendable {
        case didBecomeActive
        case runningApplicationChanged(bundleID: String?, terminated: Bool)
        case runningApplicationsChanged
    }

    private var didBecomeActiveObserver: NSObjectProtocol?
    private var appLaunchObserver: NSObjectProtocol?
    private var appTerminationObserver: NSObjectProtocol?
    private var runningApplicationsObservation: NSKeyValueObservation?
    private var runningApplicationsRefreshQueued = false
    private var observerGeneration = 0

    var onRunningApplicationsRefreshForTests: (() -> Void)?
    private weak var controller: HiddenBarController?

    func connect(controller: HiddenBarController) {
        self.controller = controller
    }

    func start() {
        if didBecomeActiveObserver == nil, appLaunchObserver == nil,
           appTerminationObserver == nil, runningApplicationsObservation == nil
        {
            observerGeneration &+= 1
        }
    }

    func install() {
        installDidBecomeActiveObserver(generation: observerGeneration)
        installRunningApplicationObservers(generation: observerGeneration)
    }

    func invalidate() {
        observerGeneration &+= 1
    }

    func removeObservers() {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
            self.didBecomeActiveObserver = nil
        }
        removeRunningApplicationObservers()
    }

    private func installDidBecomeActiveObserver(generation: Int) {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.enqueueObserverEvent(.didBecomeActive, generation: generation)
        }
    }

    private func installRunningApplicationObservers(generation: Int) {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if appLaunchObserver == nil {
            appLaunchObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                self?.enqueueObserverEvent(
                    .runningApplicationChanged(bundleID: bundleID, terminated: false),
                    generation: generation
                )
            }
        }
        if appTerminationObserver == nil {
            appTerminationObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                self?.enqueueObserverEvent(
                    .runningApplicationChanged(bundleID: bundleID, terminated: true),
                    generation: generation
                )
            }
        }
        if runningApplicationsObservation == nil {
            runningApplicationsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
                self?.enqueueObserverEvent(.runningApplicationsChanged, generation: generation)
            }
        }
    }

    @discardableResult
    private nonisolated func enqueueObserverEvent(_ event: ObserverEvent, generation: Int) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self, generation == observerGeneration, let controller else { return }
            switch event {
            case .didBecomeActive:
                controller.refreshAvailabilityAndItems()
            case let .runningApplicationChanged(bundleID, terminated):
                controller.handleRunningApplicationChanged(bundleID: bundleID, terminated: terminated)
            case .runningApplicationsChanged:
                queueRunningApplicationsRefresh(generation: generation)
            }
        }
    }

    @discardableResult
    private func queueRunningApplicationsRefresh(generation: Int) -> Task<Void, Never>? {
        guard !runningApplicationsRefreshQueued else { return nil }
        runningApplicationsRefreshQueued = true
        return Task { @MainActor [weak self] in
            guard let self else { return }
            runningApplicationsRefreshQueued = false
            guard generation == observerGeneration, let controller else { return }
            onRunningApplicationsRefreshForTests?()
            MainThreadAXSpanTrace.measure(.hiddenBarRunningApps) {
                controller.handleRunningApplicationChanged(bundleID: nil, terminated: false)
            }
        }
    }

    func enqueueDidBecomeActiveForTests() -> Task<Void, Never> {
        enqueueObserverEvent(.didBecomeActive, generation: observerGeneration)
    }

    func enqueueRunningApplicationsChangedForTests() -> Task<Void, Never> {
        enqueueObserverEvent(.runningApplicationsChanged, generation: observerGeneration)
    }

    func queueRunningApplicationsRefreshForTests() -> Task<Void, Never>? {
        queueRunningApplicationsRefresh(generation: observerGeneration)
    }

    private func removeRunningApplicationObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        if let appLaunchObserver {
            notificationCenter.removeObserver(appLaunchObserver)
            self.appLaunchObserver = nil
        }
        if let appTerminationObserver {
            notificationCenter.removeObserver(appTerminationObserver)
            self.appTerminationObserver = nil
        }
        runningApplicationsObservation?.invalidate()
        runningApplicationsObservation = nil
    }

    var hasRunningApplicationsObservationForTests: Bool {
        runningApplicationsObservation != nil
    }
}
