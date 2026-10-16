// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMIPC

extension WorkspaceBarManager {
    func hasShellIsland(on monitor: Monitor) -> Bool {
        shellHost?.config.island?.includes(monitor) == true
    }

    func prepareShell(for bars: [DesiredBarSurface], settings: SettingsStore) {
        lastBars = bars
        if settings.workspaceBar.enabled || settings.island.enabled {
            startShellHostIfNeeded(settings: settings)
        } else if shellHost != nil {
            stopShellHost()
        }
        shellHost?.updateWorld()
        shellHost?.updateBars()
    }

    func applyIslands(_ islands: [DesiredIslandSurface]) {
        guard let settings = controller?.settings else { return }
        lastIslands = settings.island.enabled ? islands : []
        let level = lastIslands.reduce(NSWindow.Level.mainMenu.rawValue + 3) { level, island in
            max(level, settings.workspaceBar.resolved(for: island.monitor).windowLevel.nsWindowLevel.rawValue + 1)
        }
        shellHost?.updateIslands(lastIslands, level: NSWindow.Level(rawValue: level))
    }

    func shellSnapshot(for bar: DesiredBarSurface) -> WorkspaceBarSnapshot {
        var snapshot = bar.snapshot.replacingShellWidgets(shellHost?.slots(for: bar.monitor.id) ?? [])
        snapshot.barShader = shellHost?.config.barShader
        return snapshot
    }

    private func applyShellProfile(_ config: ShellConfig) {
        guard let controller else { return }
        let bar = config.barOverride
        if controller.settings.workspaceBar.profileOverride != bar {
            controller.settings.workspaceBar.profileOverride = bar
            controller.updateWorkspaceBarSettings()
        }
        if controller.settings.hiddenBar.profileOverride != config.hiddenBarOverride {
            controller.settings.hiddenBar.profileOverride = config.hiddenBarOverride
            controller.updateHiddenBarSettings()
        }
    }

    func shellConfigurationSaved(_ config: ShellConfig) {
        if let shellHost {
            shellHost.applyConfig(config, problems: shellConfiguration.configProblems)
        } else { applyShellProfile(config) }
    }

    func toggleShellSystemStats(preferring monitors: [Monitor]) -> Bool {
        guard let host = shellHost, let widget = host.systemStatsWidget else { return false }
        if host.popout?.widget == widget {
            host.closePopout()
            return true
        }
        guard let monitor = monitors.first(where: { host.shows(widget, on: $0.id) }) else { return false }
        return host.togglePopout(of: widget, on: monitor.id)
    }

    func closeShellSystemStats(on monitorId: Monitor.ID) {
        guard let host = shellHost, let popout = host.popout, popout.widget == host.systemStatsWidget,
              popout.key.monitor == monitorId
        else {
            return
        }
        host.closePopout()
    }

    func stopShellHost() {
        controller?.settings.workspaceBar.profileOverride = nil
        controller?.settings.hiddenBar.profileOverride = nil
        let host = shellHost
        shellHost = nil
        lastBars = []
        lastIslands = []
        notificationBadges.onLabelsChange = nil
        host?.stop()
        setShellBadgeDemand(false)
        controller?.mouseEventHandler.reconcileMouseMoveSubscription()
    }

    func flushShellForQuit() async {
        shellHost?.stop()
        await shellConfiguration.flush()
        await ShellWidgetHost.flushRetiredWork()
    }

    func toggleShell(_ name: String) -> Bool {
        let monitor = controller?.workspaceManager.interactionMonitorId ?? lastBars.first?.monitor.id
        return monitor.flatMap { shellHost?.toggle(name, on: $0) } == true
    }

    var needsShellEdgeMouseMoves: Bool {
        shellHost?.drawers.contains { $0.hover || $0.closesOnLeave } == true
    }

    func handleShellEdgeHover(at pointer: CGPoint) {
        guard needsShellEdgeMouseMoves, let host = shellHost, let controller else { return }
        switch shellEdgeHover.update(
            pointer: pointer,
            drawers: host.drawers,
            monitors: controller.workspaceManager.monitors,
            buttonsDown: NSEvent.pressedMouseButtons != 0,
            open: host.openDrawer
        ) {
        case let .open(drawer, monitor)?: _ = host.toggleDrawer(drawer, on: monitor)
        case .close?: host.closeDrawer()
        case nil: break
        }
    }

    func startShellHostIfNeeded(settings: SettingsStore) {
        guard shellHost == nil else { return }
        let configDirectory = settings.settingsFileURL.deletingLastPathComponent()
        let backups = ShellDefaults.sync(into: ShellWidgetHost.shellDirectory(in: configDirectory))
        if !backups.isEmpty {
            Self.presentReplacedShellDefaults(backups)
        }
        let host = makeShellHost(configDirectory: configDirectory)
        observeShellHost(host)
        shellHost = host
        host.onBadgesDemandChange = { [weak self] in self?.setShellBadgeDemand($0) }
        notificationBadges.onLabelsChange = { [weak self] in
            guard let self else { return }
            if notificationBadges.mode != .off { shellHost?.updateBars() }
            publishShellBadges()
        }
        host.setBarColors(accent: settings.workspaceBar.accentColor, foreground: settings.workspaceBar.textColor)
        host.setLocked(controller?.isLockScreenActive == true)
        host.start()
    }

    private func makeShellHost(configDirectory: URL) -> ShellWidgetHost {
        ShellWidgetHost(
            configDirectory: configDirectory,
            configurationCoordinator: shellConfiguration,
            resources: makeShellResources(),
            focusPolicyEngine: controller?.focusPolicyEngine,
            sessionToken: shellSessionToken,
            world: { [weak self] in
                self?.controller?.shellWorld() ?? ShellWorldData()
            },
            vars: { [weak self] in
                self?.shellVars ?? [:]
            },
            bars: { [weak self] in
                self?.shellBars() ?? [:]
            },
            onLayoutChange: { [weak self] in
                self?.apply(self?.lastBars ?? [])
            },
            onCommand: { [weak self] request, origin in
                self?.performShellRequest(request, origin: origin)
            },
            onMenu: { [weak self] request in
                self?.showShellMenu(request)
            },
            onPreview: { [weak self] request in
                self?.shellPreviewChanged(request)
            },
            onDrag: { [weak self] request in
                self?.shellDragChanged(request)
            },
            onPopoutChange: { [weak self] in
                self?.refreshAutoHide()
            },
            onTitleDemandChange: { demands in
                AppAXContextRegistry.setWindowTitleNotifications(demands)
            }
        )
    }

    private func makeShellResources() -> ShellResources {
        ShellResources(
            motion: motionPolicy,
            appVolumes: controller?.appVolumeMixer,
            media: controller?.mediaController,
            calendar: controller?.calendarController,
            windowIcon: { [weak self] id in self?.shellItemIcons[id] },
            iconOverride: { [weak self] bundleId in
                self?.controller?.workspaceBarIconResolver.image(for: bundleId)
            }
        )
    }

    private func observeShellHost(_ host: ShellWidgetHost) {
        host.onToggleNamesChange = { [weak self] in
            self?.controller?.settings.reconcileDynamicHotkeys()
        }
        host.onWidgetsChange = { [weak self] in
            NotificationCenter.default.post(name: .shellWidgetsDidChange, object: nil)
            guard let bridge = self?.controller?.ipcApplicationBridge else { return }
            Task {
                await bridge.publishEvent(.shellWidgets)
            }
        }
        host.onWidgetMenu = { [weak self] request in
            self?.showWidgetMenu(request)
        }
        host.onConfigChange = { [weak self] config in
            self?.shellConfiguration.adopt(config)
            NotificationCenter.default.post(name: .shellConfigDidChange, object: nil)
            self?.applyShellProfile(config)
            self?.applyIslands(self?.lastIslands ?? [])
            if self?.controller?.settings.island.enabled == true {
                self?.controller?.surfaceReconciler.noteWorldChanged()
            }
            self?.controller?.mouseEventHandler.reconcileMouseMoveSubscription()
        }
    }

    static func presentReplacedShellDefaults(_ backups: [URL]) {
        Log.shell.notice("Replaced edited default shell files; kept \(backups.map(\.lastPathComponent))")
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = String(localized: "OmniWM updated its default shell files")
            alert.informativeText = String(localized:
                "Files you had edited in the shell’s default folder were replaced. Your versions are kept next to them with “.edited” in their names."
            )
            alert.addButton(withTitle: String(localized: "Show in Finder"))
            alert.addButton(withTitle: String(localized: "OK"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting(backups)
            }
        }
    }

    func setShellLocked(_ locked: Bool) {
        shellHost?.setLocked(locked)
    }

    private func keepsShellInstance(_ bar: DesiredBarSurface) -> Bool {
        guard !bar.isRetained else { return true }
        guard let controller else { return false }
        return controller.isWorkspaceBarEnabled(
            on: bar.monitor,
            resolved: controller.settings.workspaceBar.resolved(for: bar.monitor)
        )
    }

    private func shellBars() -> [ShellBarKey: ShellBarData] {
        var result: [ShellBarKey: ShellBarData] = [:]
        var icons: [String: NSImage] = [:]
        shellCompactedScratchpads = [:]
        guard let settings = controller?.settings.workspaceBar else { return result }
        for bar in lastBars where keepsShellInstance(bar) {
            let resolved = settings.resolved(for: bar.monitor)
            var data = ShellBarData(
                monitor: bar.monitor,
                snapshot: bar.snapshot,
                style: ShellBarStyle(resolved, settings: settings, snapshot: bar.snapshot),
                sessionToken: shellSessionToken,
                badges: notificationBadges,
                icons: &icons
            )
            data.drag = ShellBarDrag(shellDrag, snapshot: bar.snapshot, sessionToken: shellSessionToken)
            let geometry = WorkspaceBarGeometry.resolve(monitor: bar.monitor, resolved: resolved, isVisible: true)
            let islands: [WorkspaceBarIslandSlice] = WorkspaceBarInstance.splits(
                bar.snapshot,
                geometry: geometry,
                monitor: bar.monitor,
                resolved: resolved
            ) ? [.active, .secondary] : [.all]
            for island in islands {
                data.island = island
                if island != .active {
                    compactScratchpads(in: &data, bar: bar, geometry: geometry, resolved: resolved)
                }
                result[ShellBarKey(monitor: bar.monitor.id, island: island)] = data
            }
        }
        shellItemIcons = icons
        return result
    }

    private func compactScratchpads(
        in data: inout ShellBarData,
        bar: DesiredBarSurface,
        geometry: WorkspaceBarGeometry,
        resolved: ResolvedBarSettings
    ) {
        guard !data.scratchpads.isEmpty, !bar.snapshot.orientation.isVertical, let shellHost else { return }
        let compact = Self.compactScratchpads(
            bar.snapshot,
            beside: shellHost.slots(for: bar.monitor.id).filter { $0.island == data.island },
            availableWidth: WorkspaceBarInstance.scratchpadWidth(
                on: data.island,
                geometry: geometry,
                monitor: bar.monitor,
                resolved: resolved
            )
        )
        for index in data.scratchpads.indices {
            data.scratchpads[index].compact = compact.contains(data.scratchpads[index].id)
        }
        shellCompactedScratchpads[bar.monitor.id] = compact
    }

    static func compactScratchpads(
        _ snapshot: WorkspaceBarSnapshot,
        beside slots: [WorkspaceBarShellWidget],
        availableWidth: CGFloat
    ) -> Set<Int> {
        let others = slots.filter { $0.id != ShellConfig.bundledScratchpads }
        let presented = WorkspaceBarScratchpadLayout.compactedItems(
            snapshot.scratchpads,
            availableWidth: availableWidth,
            baseWidth: 8 + others.reduce(0) { $0 + $1.size.width } + CGFloat(max(0, others.count - 1)) * 8,
            barHeight: snapshot.barHeight,
            hasAdjacentContent: !others.isEmpty
        )
        return Set(presented.filter { $0.presentation == .compact }.map(\.index))
    }

    enum ShellBarClick: Equatable {
        case focusWindow(WindowToken)
        case focusWorkspace(rawName: String)
        case toggleScratchpad(ScratchpadIndex)
    }
}
