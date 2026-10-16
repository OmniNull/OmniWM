// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC
import OmniWMScriptHost

extension ShellWidgetHost {
    func start() {
        guard !started else { return }
        do {
            try SettingsFileAccess.ensureDirectoryExists(at: widgetsDirectory)
        } catch {
            Log.shell.error("Failed to create widget directory \(widgetsDirectory.path): \(error.localizedDescription)")
            return
        }
        started = true
        resources.resourceImages = ShellResourceImages(store: resourceStore)
        joinTraceCapture()
        installAuthoringFiles()
        configProblems = []
        config = ShellConfig.resolve(shellDirectory: shellDirectory, problems: &configProblems)
        onConfigChange?(config)
        resources.palette.refresh(theme: paletteTheme, appearance: NSApplication.shared.effectiveAppearance)
        resources.shaders.onChange = { [weak self] in
            self?.shadersChanged(includingAssets: false)
        }
        resources.images.onAssetChange = { [weak self] url in
            self?.refreshAssets(at: url)
        }
        resources.shaders.onAssetChange = { [weak self] url in
            self?.refreshAssets(at: url)
        }
        resources.images.onLoad = { [weak self] in
            Task { @MainActor [weak self] in
                self?.watchFiles()
            }
        }
        outbox = ShellWidgetOutbox { [weak self] batch in
            self?.receive(batch)
        }
        observation = ShellDirectoryObservation { [weak self] in
            self?.rescan()
        }
        observeSystem()
        rescan()
        updateWallpaperPalette()
    }

    private func observeSystem() {
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.shadersChanged()
            }
        }
        displaySleepObservers = [
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.screensDidWakeNotification, false)
        ].map { name, asleep in
            NSWorkspace.shared.notificationCenter
                .addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.setDisplaysAsleep(asleep)
                    }
                }
        }
        systemColorsObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appearanceDidChange()
            }
        }
    }

    func stop() {
        started = false
        removeBarShaders()
        if let focusedSurface { releaseShellFocus(from: focusedSurface, restore: true) }
        stopConfiguration()
        feed?.stop()
        feed = nil
        latestData.publish(ShellWidgetData())
        observation?.cancel()
        observation = nil
        wallpaperPalette?.stop()
        wallpaperPalette = nil
        if let systemColorsObserver {
            NotificationCenter.default.removeObserver(systemColorsObserver)
            self.systemColorsObserver = nil
        }
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
        displaySleepObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        displaySleepObservers = []
        displaysAsleep = false
        outbox = nil
        closePopout()
        finishClosing()
        closeDrawer(animated: false)
        tooltip.hide()
        for state in widgets.values {
            retire(state)
        }
        closeIslands()
        if let images = resources.resourceImages {
            resources.resourceImages = nil
            let id = ObjectIdentifier(images)
            let metrics = retireTraceImages(images)
            Self.retiringTasks[id] = Task {
                await metrics?.value
                await images.close()
                Self.retiringTasks.removeValue(forKey: id)
            }
        }
        desiredIslands = []
        islandData = [:]
        widgets.removeAll()
        publishTitleDemand(false)
        publishToggleNames()
        bars = [:]
        placedSlots = [:]
    }

    func updateWallpaperPalette() {
        guard config.themeName == ShellWallpaperPalette.themeName else {
            wallpaperPalette?.stop()
            wallpaperPalette = nil
            return
        }
        if let wallpaperPalette {
            wallpaperPalette.setScheme(config.wallpaperScheme)
            return
        }
        let writer = ShellWallpaperPaletteWriter(
            destination: shellDirectory.appendingPathComponent("themes/\(ShellWallpaperPalette.themeName).toml"),
            scheme: config.wallpaperScheme
        ) { [weak self] problem in
            guard let self, !configProblems.contains(problem) else { return }
            ShellConfig.report(problem, &configProblems)
            publishToggleNames()
        }
        wallpaperPalette = writer
        writer.start()
    }

    func setBarColors(accent: SettingsColor?, foreground: SettingsColor?) {
        guard barColors.accent != accent || barColors.foreground != foreground else { return }
        barColors = (accent, foreground)
        guard started, config.themeName == "native" else { return }
        appearanceDidChange()
    }

    private var paletteTheme: ShellTheme {
        var theme = config.theme
        let profile = config.barOverride
        let accent = profile?.accentColor ?? (profile?.usesThemeColors == true ? nil : barColors.accent)
        let foreground = profile?.textColor ?? (profile?.usesThemeColors == true ? nil : barColors.foreground)
        for (role, color) in [(ShellRole.accent, accent), (.foreground, foreground)] {
            guard let color else { continue }
            let resolved = NSColor(deviceRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
            theme.light[role.rawValue] = resolved
            theme.dark[role.rawValue] = resolved
        }
        return theme
    }

    func appearanceDidChange() {
        resources.palette.refresh(theme: paletteTheme, appearance: NSApplication.shared.effectiveAppearance)
        refreshBarShaders()
        resources.devices.appearance.refresh()
        iconsDidChange()
    }

    func iconsDidChange() {
        closePopout()
        redrawInstances()
    }

    private func redrawInstances() {
        for state in widgets.values {
            for instance in state.instances.values {
                instance.redraw(text: state.text)
            }
        }
    }

    func rescan(reloadConfiguration: Bool = true) {
        guard started else { return }
        let (found, directories) = discoverPackages()
        syncDiscoveredPackages(found)
        updateBars()
        for (name, sourceURL) in found {
            guard let state = widgets[name] else { continue }
            place(state)
            let fingerprint = fingerprint(of: sourceURL)
            if fingerprint != state.fingerprint {
                state.fingerprint = fingerprint
                if name == config.island?.root, state.package != nil, state.loadingPackage == nil {
                    syncComponents()
                } else {
                    load(state)
                }
            }
        }
        reconcileIslandWindows()
        watchedPaths = configPaths() + directories
            + found.values.flatMap { packageFiles(of: $0).map(\.url) + packageDirectories(of: $0) }
        updateFeed()
        resources.shaders.refresh()
        if resources.images.refresh() {
            redrawInstances()
        }
        shadersChanged(includingAssets: false)
        refreshSlots()
        if reloadConfiguration { reloadConfig() }
        refreshConfigurationCatalog()
        publishToggleNames()
    }

    private func syncDiscoveredPackages(_ found: [String: URL]) {
        for (name, state) in widgets where found[name] != state.sourceURL {
            if popout?.widget == name {
                closePopout()
            }
            if drawer?.sections.contains(where: { $0.widget == name }) == true {
                closeDrawer()
            }
            if let removed = widgets.removeValue(forKey: name) { retire(removed) }
        }
        for (name, sourceURL) in found where widgets[name] == nil {
            let state = WidgetState(name: name, sourceURL: sourceURL)
            if let trip = trips[name], trip.source != sourceURL {
                state.fallback = trip.failure
            }
            widgets[name] = state
        }
    }

    func folders(of state: WidgetState) -> [URL] {
        [state.sourceURL.deletingLastPathComponent()] + config.directories
    }

    func refreshShaders() {
        guard started else { return }
        shadersChanged()
    }

    func watchFiles() {
        observation?
            .sync(paths: watchedPaths + resources.shaders.files + resources.images.files + configurationMetadataPaths)
    }

    private func shadersChanged(includingAssets: Bool = true) {
        refreshBarShaders()
        watchFiles()
        for state in widgets.values {
            for instance in state.instances.values {
                instance.surface?.refreshShaders(includingAssets: includingAssets)
            }
        }
        popout?.surface.refreshShaders(includingAssets: includingAssets)
        let previous = placedSlots
        refreshSlots()
        if placedSlots != previous {
            onLayoutChange()
        }
    }

    private func installAuthoringFiles() {
        let luaurc = shellDirectory.appendingPathComponent(".luaurc")
        let definitions = shellDirectory.appendingPathComponent("omniwm.d.luau")
        do {
            if !FileManager.default.fileExists(atPath: luaurc.path) {
                try Data(#"{"lint": {"FunctionUnused": false}}\#n"#.utf8).write(to: luaurc, options: .atomic)
            }
            guard let source = Self.definitionsURL else {
                Log.shell.error("The bundled omniwm.d.luau type definitions are missing")
                return
            }
            let contents = try Data(contentsOf: source)
            guard (try? Data(contentsOf: definitions)) != contents else { return }
            try contents.write(to: definitions, options: .atomic)
        } catch {
            Log.shell
                .error(
                    "Failed to write widget authoring files in \(shellDirectory.path): \(error.localizedDescription)"
                )
        }
    }

    private func configPaths() -> [URL] {
        config.directories.flatMap { directory -> [URL] in
            let themes = directory.appendingPathComponent("themes", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: themes,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return [
                directory,
                directory.appendingPathComponent("shell.toml"),
                directory.appendingPathComponent("widgets", isDirectory: true),
                directory.appendingPathComponent("shaders", isDirectory: true),
                themes
            ] + files.filter { $0.pathExtension == "toml" }
        }
    }

    private func discoverPackages() -> ([String: URL], [URL]) {
        var packages: [String: URL] = [:]
        var directories: [URL] = []
        ownWidgets = []
        for layer in config.directories {
            for entry in ShellConfig.widgetFolders(in: layer) {
                directories.append(entry)
                let source = entry.appendingPathComponent("init.luau")
                if layer == shellDirectory, FileManager.default.fileExists(atPath: source.path) {
                    packages[entry.lastPathComponent] = source
                    ownWidgets.insert(entry.lastPathComponent)
                }
            }
        }
        for name in config.leading + config.center + config.trailing + [config.hiddenBarWidget, config.island?.root]
            .compactMap(\.self)
            + config.drawers.flatMap(\.widgets) where packages[name] == nil
        {
            packages[name] = config.widget(name) ?? ShellConfig.bundledWidget(name)
            if packages[name] == nil, reportedMissing.insert(name).inserted {
                Log.shell.error("shell.toml names a widget \(name) that is not in any widgets folder")
            }
        }
        for (name, trip) in trips {
            guard packages[name] == trip.source, fingerprint(of: trip.source) == trip.fingerprint else {
                trips[name] = nil
                continue
            }
            if let bundled = ShellConfig.bundledWidget(name) {
                packages[name] = bundled
            }
        }
        return (packages, directories)
    }

    private func updateFeed() {
        defer { publishDemand() }
        if widgets.isEmpty {
            feed?.stop()
            feed = nil
            latestData.publish(ShellWidgetData())
        } else if feed == nil {
            let feed = ShellDataFeed(
                appVolumes: resources.appVolumes,
                media: resources.media,
                calendar: resources.calendar,
                devices: resources.devices,
                onBadgesDemandChange: { [weak self] in self?.onBadgesDemandChange?($0) },
                deliver: { [weak self] data in
                    self?.broadcast(data)
                }
            )
            self.feed = feed
            feed.setWorld(world())
            feed.setVars(vars())
            feed.setWeatherLocation(config.weather)
            feed.setPaused(isPaused)
            feed.start()
        }
    }

    var isPaused: Bool {
        locked || displaysAsleep
    }

    func setLocked(_ locked: Bool) {
        self.locked = locked
        feed?.setPaused(isPaused)
        pauseBarShaders()
    }

    private func setDisplaysAsleep(_ asleep: Bool) {
        displaysAsleep = asleep
        feed?.setPaused(isPaused)
        pauseBarShaders()
    }
}
