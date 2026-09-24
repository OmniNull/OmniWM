// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

private enum CommandPaletteFocusSignal {
    static let name = Notification.Name("OmniWM.CommandPalette.FocusChanged")
    static let pidKey = "pid"
}

private func commandPaletteFocusedWindowChangedCallback(
    _: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _: UnsafeMutableRawPointer?
) {
    let name = notification as String
    guard name == (kAXFocusedWindowChangedNotification as String)
        || name == (kAXFocusedUIElementChangedNotification as String)
    else {
        return
    }
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }
    NotificationCenter.default.post(
        name: CommandPaletteFocusSignal.name,
        object: nil,
        userInfo: [CommandPaletteFocusSignal.pidKey: pid]
    )
}

@MainActor
final class CommandPaletteActionExecutor {
    private enum CommandFailure {
        case targetUnavailable
        case focusNotRestored
        case focusTimedOut
        case focusInterrupted
        case execution(ExternalCommandResult)

        var message: String {
            switch self {
            case .targetUnavailable:
                "The original app is no longer available."
            case .focusNotRestored:
                "The original app could not be focused."
            case .focusTimedOut:
                "Focus did not return to the original app in time."
            case .focusInterrupted:
                "Focus moved to another app."
            case let .execution(result):
                switch result {
                case .executed:
                    ""
                case .ignoredDisabled:
                    "OmniWM is disabled."
                case .ignoredOverview:
                    "The command is unavailable while Overview is open."
                case .ignoredLayoutMismatch:
                    "The command is unavailable for the current layout."
                case .noChange:
                    "The command made no change."
                case .staleWindowId,
                     .notFound:
                    "The target window is no longer available."
                case .workspaceAssignmentConflict,
                     .workspaceStateConflict,
                     .windowActionFailed,
                     .invalidArguments:
                    "The command could not be completed."
                }
            }
        }
    }

    private enum FocusedAction {
        case command(WMController, HotkeyCommand)
        case paste(WMController)
    }

    private struct PendingFocusAction {
        let action: FocusedAction
        let target: CommandPaletteAppSnapshot
        let expectedWindowID: CGWindowID?
        let generation: UInt64
    }

    private let environment: CommandPaletteEnvironment
    private let focusSession: CommandPaletteFocusSession
    private var pendingAction: PendingFocusAction?
    private var activationObserver: NSObjectProtocol?
    private var ownKeyObserver: NSObjectProtocol?
    private var focusSignalObserver: NSObjectProtocol?
    private var focusAXObserver: AXObserver?
    private var focusAppElement: AXUIElement?
    private var observedAXNotifications: [CFString] = []
    private var activationDeadline: Task<Void, Never>?
    private var activationGeneration: UInt64 = 0

    init(environment: CommandPaletteEnvironment, focusSession: CommandPaletteFocusSession) {
        self.environment = environment
        self.focusSession = focusSession
    }

    isolated deinit {
        cancelPendingCommand()
    }

    enum Action {
        case navigateWindow(WMController, WindowHandle)
        case summonWindowRight(WMController, WindowHandle, CommandPaletteSummonAnchor)
        case pressMenu(CommandPaletteFocusTarget, AXUIElement)
        case copyClipboard(WMController, UUID)
        case pasteClipboard(WMController, UUID, CommandPaletteClipboardPasteTarget?, Bool)
        case command(WMController, HotkeyCommand, CommandPaletteFocusTarget?)
    }

    func perform(_ action: Action) {
        switch action {
        case let .navigateWindow(wmController, handle):
            environment.navigateToWindow(wmController, handle)
        case let .summonWindowRight(wmController, handle, summonAnchor):
            environment.summonWindowRight(
                wmController,
                handle,
                summonAnchor.token,
                summonAnchor.workspaceId
            )
        case let .pressMenu(target, element):
            _ = focusSession.focus(target: target)
            environment.scheduleMenuAction { [environment] in
                environment.performMenuAction(element)
            }
        case let .copyClipboard(wmController, id):
            Task { @MainActor [environment] in
                _ = await environment.copyClipboardItem(wmController, id)
            }
        case let .pasteClipboard(wmController, id, target, withoutFormatting):
            cancelPendingCommand()
            let requestGeneration = activationGeneration
            Task { @MainActor [weak self, environment] in
                let didCopy = if withoutFormatting {
                    await environment.copyClipboardItemPlainText(wmController, id)
                } else {
                    await environment.copyClipboardItem(wmController, id)
                }
                guard didCopy,
                      let self,
                      self.activationGeneration == requestGeneration,
                      let target,
                      !environment.isLockScreenActive(wmController),
                      environment.isAccessibilityTrusted(),
                      !environment.isSecureInputActive()
                else {
                    return
                }
                self.beginFocusedAction(
                    .paste(wmController),
                    target: target.focusTarget,
                    expectedWindowID: target.expectedWindowId,
                    restoreFocus: { self.focusSession.focus(target: target.focusTarget) }
                )
            }
        case let .command(wmController, command, target):
            performCommand(command, controller: wmController, target: target)
        }
    }

    func cancelPendingCommand() {
        activationGeneration &+= 1
        if let activationObserver {
            environment.applicationActivationNotifications.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let ownKeyObserver {
            NotificationCenter.default.removeObserver(ownKeyObserver)
            self.ownKeyObserver = nil
        }
        if let focusSignalObserver {
            NotificationCenter.default.removeObserver(focusSignalObserver)
            self.focusSignalObserver = nil
        }
        if let focusAXObserver {
            if let focusAppElement {
                for notification in observedAXNotifications {
                    AXObserverRemoveNotification(focusAXObserver, focusAppElement, notification)
                }
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusAXObserver), .commonModes)
            self.focusAXObserver = nil
            focusAppElement = nil
            observedAXNotifications = []
        }
        activationDeadline?.cancel()
        activationDeadline = nil
        pendingAction = nil
    }
}

@MainActor
extension CommandPaletteActionExecutor {
    private func performCommand(
        _ command: HotkeyCommand,
        controller: WMController,
        target: CommandPaletteFocusTarget?
    ) {
        guard let target,
              target.app.processIdentifier != environment.ownProcessIdentifier()
        else {
            cancelPendingCommand()
            reportCommandResult(environment.performCommand(controller, command))
            return
        }
        beginFocusedAction(
            .command(controller, command),
            target: target,
            expectedWindowID: target.focusedWindowID,
            restoreFocus: { self.environment.restoreCommandFocus?(target) ?? self.focusSession.focus(target: target) }
        )
    }

    private func beginFocusedAction(
        _ action: FocusedAction,
        target: CommandPaletteFocusTarget,
        expectedWindowID: CGWindowID?,
        restoreFocus: () -> Bool
    ) {
        cancelPendingCommand()
        guard isLiveTarget(target.app) else {
            if case .command = action { reportCommandFailure(.targetUnavailable) }
            return
        }
        let needsInputFocus = switch action {
        case .paste: true
        case .command: false
        }
        activationGeneration &+= 1
        let generation = activationGeneration
        pendingAction = PendingFocusAction(
            action: action,
            target: target.app,
            expectedWindowID: expectedWindowID,
            generation: generation
        )
        observeActivation(generation: generation)
        if needsInputFocus {
            observeOwnKey(generation: generation)
        }
        if expectedWindowID != nil || needsInputFocus {
            observeFocus(
                pid: target.app.processIdentifier,
                generation: generation,
                expectedWindowID: expectedWindowID,
                needsInputFocus: needsInputFocus
            )
        }
        activationDeadline = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self, self.pendingAction?.generation == generation else { return }
            self.cancelPendingCommand()
            if !needsInputFocus { self.reportCommandFailure(.focusTimedOut) }
        }

        guard restoreFocus() else {
            cancelPendingCommand()
            if !needsInputFocus { reportCommandFailure(.focusNotRestored) }
            return
        }
        if environment.frontmostApplication()?.processIdentifier == target.app.processIdentifier {
            completePendingAction(generation: generation)
        }
    }

    private func observeActivation(generation: UInt64) {
        activationObserver = environment.applicationActivationNotifications.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                self?.handleApplicationActivation(pid: pid, generation: generation)
            }
        }
    }

    private func observeOwnKey(generation: UInt64) {
        ownKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.completePendingAction(generation: generation)
            }
        }
    }

    private func observeFocus(
        pid: pid_t,
        generation: UInt64,
        expectedWindowID: CGWindowID?,
        needsInputFocus: Bool
    ) {
        focusSignalObserver = NotificationCenter.default.addObserver(
            forName: CommandPaletteFocusSignal.name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let pid = notification.userInfo?[CommandPaletteFocusSignal.pidKey] as? pid_t else { return }
            Task { @MainActor [weak self] in
                self?.handleFocusedWindowChanged(pid: pid, generation: generation)
            }
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, commandPaletteFocusedWindowChangedCallback, &observer) == .success,
              let observer
        else {
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        var notifications: [CFString] = []
        if expectedWindowID != nil,
           AXObserverAddNotification(
               observer,
               appElement,
               kAXFocusedWindowChangedNotification as CFString,
               nil
           ) == .success
        {
            notifications.append(kAXFocusedWindowChangedNotification as CFString)
        }
        if needsInputFocus,
           AXObserverAddNotification(
               observer,
               appElement,
               kAXFocusedUIElementChangedNotification as CFString,
               nil
           ) == .success
        {
            notifications.append(kAXFocusedUIElementChangedNotification as CFString)
        }
        guard !notifications.isEmpty else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        focusAXObserver = observer
        focusAppElement = appElement
        observedAXNotifications = notifications
    }

    private func handleApplicationActivation(pid: pid_t, generation: UInt64) {
        guard let pendingAction, pendingAction.generation == generation else { return }
        applicationActivated(pid: pid)
    }

    func applicationActivated(pid: pid_t) {
        guard let pendingAction else { return }
        guard pid == pendingAction.target.processIdentifier else {
            cancelPendingCommand()
            if case .command = pendingAction.action { reportCommandFailure(.focusInterrupted) }
            return
        }
        completePendingAction(generation: pendingAction.generation)
    }

    private func handleFocusedWindowChanged(pid: pid_t, generation: UInt64) {
        guard let pendingAction, pendingAction.generation == generation else { return }
        focusedWindowChanged(pid: pid)
    }

    func focusedWindowChanged(pid: pid_t) {
        guard let pendingAction, pid == pendingAction.target.processIdentifier else { return }
        completePendingAction(generation: pendingAction.generation)
    }

    private func completePendingAction(generation: UInt64) {
        guard let pendingAction, pendingAction.generation == generation else { return }
        guard isLiveTarget(pendingAction.target) else {
            cancelPendingCommand()
            if case .command = pendingAction.action { reportCommandFailure(.targetUnavailable) }
            return
        }
        guard environment.frontmostApplication()?.processIdentifier == pendingAction.target.processIdentifier else {
            return
        }
        if let expectedWindowID = pendingAction.expectedWindowID,
           environment.focusedWindowID(pendingAction.target.processIdentifier) != expectedWindowID
        {
            return
        }
        if case .paste = pendingAction.action {
            guard !environment.isOwnWindowKey(),
                  environment.focusedInputProcessIdentifier() == pendingAction.target.processIdentifier
            else {
                return
            }
        }
        cancelPendingCommand()
        switch pendingAction.action {
        case let .command(controller, command):
            reportCommandResult(environment.performCommand(controller, command))
        case let .paste(controller):
            guard !environment.isLockScreenActive(controller),
                  environment.isAccessibilityTrusted(),
                  !environment.isSecureInputActive()
            else {
                return
            }
            _ = environment.postPasteShortcut()
        }
    }

    private func reportCommandResult(_ result: ExternalCommandResult) {
        guard result != .executed, result != .noChange else { return }
        reportCommandFailure(.execution(result))
    }

    private func reportCommandFailure(_ failure: CommandFailure) {
        environment.presentCommandFailure(failure.message)
    }

    private func isLiveTarget(_ target: CommandPaletteAppSnapshot) -> Bool {
        guard let app = environment.runningApplication(target.processIdentifier),
              !app.isTerminated,
              !app.isHidden
        else {
            return false
        }
        return app.processIdentifier == target.processIdentifier
            && app.bundleIdentifier == target.bundleIdentifier
    }
}
