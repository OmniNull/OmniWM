// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Cocoa
import GhosttyKit

enum QuakeTerminalRestoreTarget: Equatable {
    case managed(WindowToken)
    case external(KeyboardFocusTarget)
}

@MainActor
final class QuakeTerminalController: NSObject {
    private enum HideBehavior {
        case restoreLatestTarget
        case preserveCurrentFocus
    }

    private(set) var window: QuakeTerminalWindow?

    private var containerView: NSView?
    private let tabs = QuakeTerminalTabs()

    private var surfaceView: GhosttySurfaceView? {
        tabs.surfaceView
    }

    private(set) var visible: Bool = false
    private var restoreTarget: QuakeTerminalRestoreTarget?
    private var pendingRestoreTarget: QuakeTerminalRestoreTarget?
    private var isHandlingResize: Bool = false
    private let animator: QuakeTerminalAnimator

    private let settings: SettingsStore
    private let background: QuakeTerminalBackground
    let clipboardPrompts = QuakeClipboardPromptCoordinator()
    let ghosttyRuntime: QuakeGhosttyRuntime
    private let surfaceCoordinator = SurfaceCoordinator.shared
    private let captureRestoreTarget: @MainActor () -> QuakeTerminalRestoreTarget?
    private let restoreFocusTarget: @MainActor (QuakeTerminalRestoreTarget) -> Void
    private let isWindowFocused: @MainActor (NSWindow) -> Bool
    private let focusedWindowScreenProvider: @MainActor () -> NSScreen?

    init(
        settings: SettingsStore,
        motionPolicy: MotionPolicy,
        captureRestoreTarget: @escaping @MainActor () -> QuakeTerminalRestoreTarget? = { nil },
        restoreFocusTarget: @escaping @MainActor (QuakeTerminalRestoreTarget) -> Void = { _ in },
        isWindowFocused: @escaping @MainActor (NSWindow) -> Bool = { $0.isKeyWindow },
        focusedWindowScreenProvider: @escaping @MainActor () -> NSScreen? = { nil },
        ghosttyConfigBuilder: QuakeGhosttyConfigBuilder = QuakeGhosttyConfigBuilder()
    ) {
        self.settings = settings
        animator = QuakeTerminalAnimator(settings: settings, motionPolicy: motionPolicy)
        ghosttyRuntime = QuakeGhosttyRuntime(settings: settings, configBuilder: ghosttyConfigBuilder)
        background = QuakeTerminalBackground(settings: settings)
        self.captureRestoreTarget = captureRestoreTarget
        self.restoreFocusTarget = restoreFocusTarget
        self.isWindowFocused = isWindowFocused
        self.focusedWindowScreenProvider = focusedWindowScreenProvider
        super.init()
        tabs.connect(
            makeSurfaceView: { [weak self] in self?.createSurfaceView() },
            onLastTabClosed: { [weak self] in
                guard let self, self.visible else { return }
                self.animateOut()
            }
        )
        clipboardPrompts.attach(to: self)
    }

    isolated deinit {
        cleanup()
    }

    func setup() {
        guard ghosttyRuntime.startIfNeeded(for: self) else { return }
        createWindow()
    }

    func cleanup() {
        ghosttyRuntime.stopAppearanceSync()
        clipboardPrompts.cancelActivePrompt()
        tabs.removeAll()

        ghosttyRuntime.releaseAppAndConfiguration()
        surfaceCoordinator.unregister(id: surfaceID)
        window?.close()
        window = nil
        background.reset()
        containerView = nil
        restoreTarget = nil
        pendingRestoreTarget = nil
        visible = false
        animator.invalidate()
    }

    func reloadOpacityConfig() {
        ghosttyRuntime.reloadConfiguration(for: self)
    }

    func prepareForGhosttyConfigurationUpdate() {
        if settings.quakeTerminal.backgroundEffect != .standardBlur {
            background.applyBlurRadius(
                QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius,
                to: window
            )
        }
    }

    func reloadBackgroundBlur() {
        reconcileBackgroundEffect()
    }

    func updateGhosttyAppearance(_ appearance: QuakeGhosttyAppearance?, deferred: Bool = false) {
        guard background.updateAppearance(appearance) else { return }
        if deferred {
            DispatchQueue.main.async { [weak self] in
                self?.reconcileBackgroundEffect()
            }
        } else {
            reconcileBackgroundEffect()
        }
    }

    private func reconcileBackgroundEffect() {
        background.reconcile(in: containerView, window: window)
    }

    func applyGeometryToVisibleWindow() {
        guard let window, visible else { return }
        let screen = targetScreen()

        if let customFrame = customFrameForShow(on: screen) {
            window.setFrame(customFrame, display: true)
            tabs.refreshSurfacesForCurrentScreen()
            return
        }

        QuakeTerminalPlacement(
            position: settings.quakeTerminal.position,
            on: screen,
            widthPercent: settings.quakeTerminal.widthPercent,
            heightPercent: settings.quakeTerminal.heightPercent
        ).setFinal(in: window)
        tabs.refreshSurfacesForCurrentScreen()
    }

    private func createWindow() {
        let win = QuakeTerminalWindow()
        win.delegate = self
        self.window = win
        surfaceCoordinator.register(
            window: win,
            id: surfaceID,
            policy: SurfacePolicy(
                kind: .quake,
                hitTestPolicy: .interactive,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: true
            )
        )

        let container = NSView(frame: win.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        win.contentView = container
        self.containerView = container

        tabs.attach(to: win, container: container)

        reconcileBackgroundEffect()
    }

    private var surfaceID: String {
        "quake-terminal"
    }

    private func createSurfaceView() -> GhosttySurfaceView? {
        guard let view = ghosttyRuntime.makeSurfaceView(for: self) else { return nil }
        view.onFrameChanged = { [weak self] frame in
            self?.persistCustomFrame(frame)
        }
        return view
    }

    private func createInitialSurface() {
        guard tabs.isEmpty else { return }
        tabs.createTab()

        if let window {
            let screen = targetScreen()
            QuakeTerminalPlacement(
                position: settings.quakeTerminal.position,
                on: screen,
                widthPercent: settings.quakeTerminal.widthPercent,
                heightPercent: settings.quakeTerminal.heightPercent
            ).setFinal(in: window)
        }
    }

    func toggle() {
        if visible {
            animateOut()
        } else {
            animateIn()
        }
    }

    func animateIn() {
        guard let window else { return }
        guard !visible else { return }

        restoreTarget = captureRestoreTarget()
        pendingRestoreTarget = nil
        visible = true

        if tabs.isEmpty {
            createInitialSurface()
        }

        let screen = targetScreen()
        animator.animateIn(
            window: window,
            screen: screen,
            customFrame: { customFrameForShow(on: screen) },
            orderFront: orderFront,
            completion: { [weak self] phase in
                guard let self, phase == .immediate || self.visible else { return }
                self.finishWindowIn(window)
            }
        )
    }

    func animateOut() {
        animateOut(hideBehavior: .restoreLatestTarget)
    }

    private func animateOut(hideBehavior: HideBehavior) {
        guard let window else { return }
        guard visible else { return }

        clipboardPrompts.cancelActivePrompt()
        pendingRestoreTarget = switch hideBehavior {
        case .restoreLatestTarget:
            if isWindowFocused(window) {
                restoreTarget
            } else {
                nil
            }
        case .preserveCurrentFocus:
            nil
        }
        restoreTarget = nil
        visible = false
        animator.animateOut(
            window: window,
            screen: { window.screen ?? targetScreen() },
            completion: { [weak self] phase in
                guard let self, phase == .immediate || !self.visible else { return }
                self.finishWindowOut(window)
            }
        )
    }

    private func persistCustomFrame(_ frame: NSRect) {
        guard let customFrame = QuakeTerminalGeometryPolicy.normalizedCustomFrame(frame) else {
            settings.resetQuakeTerminalCustomFrame()
            return
        }

        settings.quakeTerminalUseCustomFrame = true
        settings.quakeTerminalCustomFrame = customFrame
    }

    private func finishWindowIn(_ window: NSWindow) {
        let quakeWindow = window as? QuakeTerminalWindow
        quakeWindow?.isAnimating = false
        window.alphaValue = 1
        window.level = .floating
        makeWindowKey(window)
        tabs.refreshSurfacesForCurrentScreen()

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible, !window.isKeyWindow else { return }
                self.makeWindowKey(window, retries: 10)
            }
        }
    }

    private func finishWindowOut(_ window: NSWindow) {
        let quakeWindow = window as? QuakeTerminalWindow
        quakeWindow?.isAnimating = false
        window.orderOut(nil)
        window.alphaValue = 1

        if let pendingRestoreTarget {
            self.pendingRestoreTarget = nil
            restoreFocusTarget(pendingRestoreTarget)
        }
    }

    private func makeWindowKey(_ window: NSWindow, retries: UInt8 = 0) {
        guard visible else { return }
        orderFront(window)

        if let surfaceView {
            window.makeFirstResponder(surfaceView)
        }

        guard !window.isKeyWindow, retries > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            self?.makeWindowKey(window, retries: retries - 1)
        }
    }

    private func orderFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        reconcileBackgroundEffect()
    }

    private func customFrameForShow(on screen: NSScreen) -> NSRect? {
        guard settings.quakeTerminalUseCustomFrame else { return nil }
        guard let customFrame = QuakeTerminalGeometryPolicy.normalizedCustomFrame(settings.quakeTerminalCustomFrame)
        else {
            settings.resetQuakeTerminalCustomFrame()
            return nil
        }
        guard QuakeTerminalGeometryPolicy.customFrameFits(customFrame, in: screen.frame) else { return nil }
        return customFrame
    }

    func targetScreen(
        screens: [NSScreen] = NSScreen.screens,
        mainScreen: NSScreen? = NSScreen.main,
        monitors: @autoclosure () -> [Monitor] = Monitor.current()
    ) -> NSScreen {
        QuakeTerminalPlacement.targetScreen(
            settings: settings,
            screens: screens,
            mainScreen: mainScreen,
            monitors: monitors,
            focusedWindowScreenProvider: focusedWindowScreenProvider
        )
    }
}

extension QuakeTerminalController: NSWindowDelegate {
    nonisolated func windowDidResignKey(_ notification: Notification) {
        guard let notificationWindow = notification.object as? NSWindow else { return }
        Task { @MainActor in
            guard notificationWindow === window else { return }
            background.updateKeyStatus(notificationWindow.isKeyWindow)
            guard visible else { return }
            guard window?.attachedSheet == nil else { return }

            await Task.yield()
            guard visible else { return }
            restoreTarget = captureRestoreTarget()

            if settings.quakeTerminal.autoHide {
                animateOut(hideBehavior: .preserveCurrentFocus)
            }
        }
    }

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        guard let notificationWindow = notification.object as? NSWindow else { return }
        Task { @MainActor in
            guard notificationWindow === window else { return }
            background.updateKeyStatus(notificationWindow.isKeyWindow)
        }
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        guard let notificationWindow = notification.object as? NSWindow else { return }
        Task { @MainActor in
            guard notificationWindow == self.window,
                  visible,
                  !isHandlingResize else { return }
            guard let window = self.window,
                  let screen = window.screen ?? NSScreen.main else { return }

            isHandlingResize = true
            defer { isHandlingResize = false }

            if surfaceView?.isInteracting != true && !settings.quakeTerminalUseCustomFrame {
                let position = settings.quakeTerminal.position
                switch position {
                case .top,
                     .bottom,
                     .center:
                    let newOrigin = position.centeredOrigin(for: window, on: screen)
                    window.setFrameOrigin(newOrigin)
                case .left,
                     .right:
                    let newOrigin = position.verticallyCenteredOrigin(for: window, on: screen)
                    window.setFrameOrigin(newOrigin)
                }
            }

            tabs.updateTabBarVisibility()
        }
    }
}

extension QuakeTerminalController {
    func handleGhosttyAction(_ action: ghostty_action_s, from view: GhosttySurfaceView) -> Bool {
        tabs.handleGhosttyAction(action, from: view)
    }

    func isActiveSurface(_ view: GhosttySurfaceView) -> Bool {
        surfaceView === view
    }

    func cancelClipboardPrompt(for view: GhosttySurfaceView) {
        clipboardPrompts.cancelPrompt(for: view)
    }

    func surfaceClosed(view closedView: GhosttySurfaceView, processAlive: Bool) {
        guard !processAlive else {
            if visible { animateOut() }
            return
        }

        tabs.surfaceClosed(closedView)
    }
}
