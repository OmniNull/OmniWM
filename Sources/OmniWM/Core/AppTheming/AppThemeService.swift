// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor @Observable
final class AppThemeService {
    typealias Perform = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias Deliver = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    private(set) var results: [String: AppThemeResult]
    private(set) var theme: ShellTheme?
    private(set) var isDark: Bool
    private(set) var isRunning = false
    var lastBackup: URL?
    private(set) var reviewAgain: String?

    @ObservationIgnored var onGhosttyThemesChanged: (() -> Void)?
    @ObservationIgnored var onRunFinished: (() -> Void)?
    @ObservationIgnored let settings: AppThemingSettings
    @ObservationIgnored let engine: AppThemeEngine
    @ObservationIgnored private let systemIsDark: @MainActor () -> Bool
    @ObservationIgnored private let perform: Perform
    @ObservationIgnored private let deliver: Deliver
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var appearanceChanged = false
    @ObservationIgnored private var takeOver: [String: String] = [:]
    @ObservationIgnored private var forceReload: Set<String> = []
    @ObservationIgnored private var enabledTargets: Set<String> = []
    @ObservationIgnored private let currentTargets = AppThemeEnabledTargets([])
    @ObservationIgnored private var paletteTerminalColors = AppThemeTerminalColors.palette
    @ObservationIgnored private var effectiveAppearanceObserver: NSKeyValueObservation?
    @ObservationIgnored private var fallbackTheme: (@MainActor () -> ShellTheme)?
    @ObservationIgnored private var cachedPalette: AppThemePalette?
    @ObservationIgnored private var appliedPalette: AppThemePalette?

    init(
        settings: AppThemingSettings,
        engine: AppThemeEngine,
        reloadsEnabledApps: Bool = false,
        systemIsDark: @escaping @MainActor () -> Bool = AppThemeService.liveSystemIsDark,
        perform: @escaping Perform = AppThemeService.performOnWorkerQueue,
        deliver: @escaping Deliver = AppThemeService.deliverOnMain
    ) {
        self.settings = settings
        self.engine = engine
        self.systemIsDark = systemIsDark
        self.perform = perform
        self.deliver = deliver
        isDark = systemIsDark()
        paletteTerminalColors = settings.values.terminalColors
        if !reloadsEnabledApps {
            enabledTargets = Set(settings.values.targets(configHome: engine.policy.configHome).map(\.id))
        }
        results = engine.store.load().results
        currentTargets.set(Set(settings.values.targets(configHome: engine.policy.configHome).map(\.id)))
    }

    private nonisolated static let queue = DispatchQueue(label: "com.barut.OmniWM.app-theming", qos: .userInitiated)

    nonisolated static func performOnWorkerQueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    nonisolated static func deliverOnMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }

    static func liveSystemIsDark() -> Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    var configHome: URL {
        engine.policy.configHome
    }

    func start() {
        guard effectiveAppearanceObserver == nil else { return }
        effectiveAppearanceObserver = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.appearanceDidChange() }
        }
    }

    func stop() {
        effectiveAppearanceObserver?.invalidate()
        effectiveAppearanceObserver = nil
        currentTargets.set([])
    }

    func setFallbackTheme(_ provider: @escaping @MainActor () -> ShellTheme) {
        fallbackTheme = provider
        theme = nil
        cachedPalette = nil
    }

    func setTheme(_ theme: ShellTheme) {
        fallbackTheme = nil
        self.theme = theme
        cachedPalette = nil
    }

    func useThemeWhileShellIsOff(_ provider: @escaping @MainActor () -> ShellTheme, refresh: Bool = false) {
        guard refresh || fallbackTheme == nil else { return }
        setFallbackTheme(provider)
        guard settings.values.anyEnabled, palette != appliedPalette else { return }
        schedule()
    }

    var palette: AppThemePalette? {
        if let cachedPalette { return cachedPalette }
        guard let theme = theme ?? fallbackTheme?() else { return nil }
        let palette = AppThemePalette(theme: theme, terminalColors: settings.values.terminalColors)
        cachedPalette = palette
        return palette
    }

    func paletteDidChange(_ theme: ShellTheme) {
        setTheme(theme)
        guard settings.values.anyEnabled, palette != appliedPalette else { return }
        schedule()
    }

    func appearanceDidChange() {
        let dark = systemIsDark()
        guard dark != isDark else { return }
        isDark = dark
        appearanceChanged = true
        schedule()
    }

    func settingsDidChange() {
        if settings.values.terminalColors != paletteTerminalColors {
            paletteTerminalColors = settings.values.terminalColors
            cachedPalette = nil
        }
        let enabled = Set(settings.values.targets(configHome: configHome).map(\.id))
        forceReload.formUnion(enabled.subtracting(enabledTargets))
        enabledTargets = enabled
        currentTargets.set(enabled)
        schedule()
    }

    func reviewShown() {
        reviewAgain = nil
    }

    func applyNow() {
        schedule()
    }

    func markTakeOver(_ path: String, reviewed digest: String) {
        takeOver[path] = digest
    }

    func markForceReload(_ targetID: String) {
        forceReload.insert(targetID)
    }

    func schedule() {
        guard !isRunning else {
            rerun = true
            return
        }
        let targets = settings.values.targets(configHome: configHome)
        guard !targets.isEmpty, let palette else { return }
        let dark = systemIsDark()
        if dark != isDark {
            isDark = dark
            appearanceChanged = true
        }
        let job = AppThemeJob(
            palette: palette,
            dark: isDark,
            appearanceChanged: appearanceChanged,
            targets: targets,
            takeOver: takeOver,
            forceReload: forceReload,
            enabled: currentTargets
        )
        appearanceChanged = false
        takeOver = [:]
        forceReload = []
        appliedPalette = palette
        isRunning = true
        let engine = engine
        let deliver = deliver
        perform { [weak self] in
            let report = engine.run(job)
            deliver { [weak self] in self?.finish(report) }
        }
    }

    private func finish(_ report: AppThemeRunReport) {
        results.merge(report.results) { $1 }
        if let backup = report.backups.last { lastBackup = backup }
        if let target = report.reviewAgain.first { reviewAgain = target }
        isRunning = false
        if report.ghosttyThemesChanged { onGhosttyThemesChanged?() }
        if rerun {
            rerun = false
            schedule()
        }
        onRunFinished?()
    }
}
