// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import GhosttyKit

@MainActor
final class QuakeGhosttyRuntime {
    private var ghosttyApp: ghostty_app_t?
    private var ghosttyConfig: ghostty_config_t?
    private var retainedAppCallbackContext: Unmanaged<GhosttyAppCallbackContext>?
    private var appearanceObserver: NSKeyValueObservation?
    private var appliedColorScheme: ghostty_color_scheme_e?
    private let settings: SettingsStore
    private let ghosttyConfigBuilder: QuakeGhosttyConfigBuilder

    private static var ghosttyInitialized = false

    init(settings: SettingsStore, configBuilder: QuakeGhosttyConfigBuilder) {
        self.settings = settings
        ghosttyConfigBuilder = configBuilder
    }

    func startIfNeeded(for controller: QuakeTerminalController) -> Bool {
        guard ghosttyApp == nil else { return false }

        initializeGhosttyIfNeeded()
        guard Self.ghosttyInitialized else {
            Log.terminal.error("GhosttyKit not initialized")
            return false
        }

        guard let config = makeGhosttyConfig() else {
            Log.terminal.error("Failed to create ghostty config")
            return false
        }
        ghosttyConfig = config
        controller.updateGhosttyAppearance(QuakeGhosttyAppearance(config: config))

        let retainedAppContext = Unmanaged.passRetained(GhosttyAppCallbackContext(controller: controller))
        var runtimeConfig = makeRuntimeConfiguration(userdata: retainedAppContext.toOpaque())

        ghosttyApp = ghostty_app_new(&runtimeConfig, config)
        guard ghosttyApp != nil else {
            retainedAppContext.release()
            Log.terminal.error("Failed to create ghostty app")
            ghostty_config_free(config)
            ghosttyConfig = nil
            controller.updateGhosttyAppearance(nil)
            return false
        }
        retainedAppCallbackContext = retainedAppContext

        startGhosttyAppearanceSync(for: controller)
        applyCurrentGhosttyColorScheme()
        return true
    }

    private func makeRuntimeConfiguration(userdata: UnsafeMutableRawPointer) -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: userdata,
            supports_selection_clipboard: true,
            wakeup_cb: GhosttyAppCallbackContext.wakeupCallback,
            action_cb: GhosttyAppCallbackContext.actionCallback,
            read_clipboard_cb: QuakeClipboardPromptCoordinator.readCallback,
            confirm_read_clipboard_cb: QuakeClipboardPromptCoordinator.confirmationCallback,
            write_clipboard_cb: QuakeClipboardPromptCoordinator.writeCallback,
            close_surface_cb: GhosttySurfaceCallbackContext.closeCallback
        )
    }

    func releaseAppAndConfiguration() {
        if let ghosttyApp {
            ghostty_app_free(ghosttyApp)
            self.ghosttyApp = nil
        }
        if let retainedAppCallbackContext {
            retainedAppCallbackContext.release()
            self.retainedAppCallbackContext = nil
        }
        if let ghosttyConfig {
            ghostty_config_free(ghosttyConfig)
            self.ghosttyConfig = nil
        }
    }

    private func initializeGhosttyIfNeeded() {
        guard !Self.ghosttyInitialized else { return }
        var arguments: UnsafeMutablePointer<CChar>?
        let result = ghostty_init(0, &arguments)
        Self.restoreCNumericLocale()
        if result == GHOSTTY_SUCCESS {
            Self.ghosttyInitialized = true
        } else {
            Log.terminal.error("ghostty_init failed with code \(result)")
        }
    }

    static func restoreCNumericLocale() {
        _ = setlocale(LC_NUMERIC, "C")
    }

    private func makeGhosttyConfig(explicitCommand: Bool = false) -> ghostty_config_t? {
        ghosttyConfigBuilder.build(
            opacity: settings.quakeTerminal.opacity,
            backgroundEffect: settings.quakeTerminal.backgroundEffect,
            explicitCommand: explicitCommand
        )
    }

    func reloadConfiguration(for controller: QuakeTerminalController) {
        guard let ghosttyApp else { return }
        guard let newConfig = makeGhosttyConfig() else { return }

        controller.prepareForGhosttyConfigurationUpdate()
        guard applyConfiguration(newConfig, app: ghosttyApp, controller: controller) else {
            ghostty_config_free(newConfig)
            return
        }
        if let ghosttyConfig {
            ghostty_config_free(ghosttyConfig)
        }
        ghosttyConfig = newConfig
        applyCurrentGhosttyColorScheme()
    }

    func reloadConfiguration(soft: Bool, for controller: QuakeTerminalController) {
        guard let ghosttyApp else { return }
        guard soft, let ghosttyConfig else {
            reloadConfiguration(for: controller)
            return
        }
        _ = applyConfiguration(ghosttyConfig, app: ghosttyApp, controller: controller)
    }

    private func applyConfiguration(
        _ config: ghostty_config_t, app: ghostty_app_t, controller: QuakeTerminalController
    ) -> Bool {
        let surfaces = controller.launcherSurfaces
        if surfaces.isEmpty {
            ghostty_app_update_config(app, config)
            return true
        }
        guard let held = ghosttyConfigBuilder.keepingCommandOutput(in: config) else { return false }
        defer { ghostty_config_free(held) }
        ghostty_app_update_config(app, config)
        for view in surfaces {
            if let surface = view.ghosttySurface { ghostty_surface_update_config(surface, held) }
        }
        return true
    }

    func receiveAppearance(_ appearance: QuakeGhosttyAppearance, for controller: QuakeTerminalController) {
        guard ghosttyApp != nil else { return }
        controller.updateGhosttyAppearance(appearance, deferred: true)
    }

    private func startGhosttyAppearanceSync(for controller: QuakeTerminalController) {
        appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new, .initial]
        ) { [weak controller] _, _ in
            Task { @MainActor [weak controller] in
                guard let controller else { return }
                controller.ghosttyRuntime.applyCurrentGhosttyColorScheme()
            }
        }
    }

    func stopAppearanceSync() {
        appearanceObserver?.invalidate()
        appearanceObserver = nil
        appliedColorScheme = nil
    }

    private func applyCurrentGhosttyColorScheme() {
        applyGhosttyColorScheme(for: NSApplication.shared.effectiveAppearance)
    }

    private func applyGhosttyColorScheme(for appearance: NSAppearance) {
        guard let ghosttyApp else { return }
        let scheme = Self.ghosttyColorScheme(for: appearance)
        guard appliedColorScheme != scheme else { return }
        ghostty_app_set_color_scheme(ghosttyApp, scheme)
        appliedColorScheme = scheme
    }

    static func ghosttyColorScheme(for appearance: NSAppearance) -> ghostty_color_scheme_e {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    func tick() {
        guard let ghosttyApp else { return }
        ghostty_app_tick(ghosttyApp)
    }

    func makeSurfaceView(
        for controller: QuakeTerminalController,
        launch: LauncherLaunchRequest? = nil,
        hasSurfaces: Bool = true
    ) -> GhosttySurfaceView? {
        guard let ghosttyApp else { return nil }
        let previousConfig = ghosttyConfig
        var launchConfig: ghostty_config_t?
        if launch != nil, !hasSurfaces {
            guard let config = makeGhosttyConfig(explicitCommand: true) else { return nil }
            launchConfig = config
            ghostty_app_update_config(ghosttyApp, config)
        }
        let context = GhosttySurfaceCallbackContext(controller: controller)
        let view = GhosttySurfaceView(ghosttyApp: ghosttyApp, callbackContext: context, launch: launch)
        guard view.ghosttySurface != nil else {
            if let launchConfig {
                if let previousConfig { ghostty_app_update_config(ghosttyApp, previousConfig) }
                ghostty_config_free(launchConfig)
            }
            return nil
        }
        if let launchConfig {
            ghosttyConfig = launchConfig
            if let previousConfig { ghostty_config_free(previousConfig) }
        }
        return view
    }
}
