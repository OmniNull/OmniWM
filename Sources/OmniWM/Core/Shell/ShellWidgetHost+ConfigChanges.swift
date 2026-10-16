// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC
import OmniWMScriptHost

extension ShellWidgetHost {
    func reloadConfig() {
        guard configurationWriter?.deferReloadIfWriting() != true else { return }
        var problems: [String] = []
        let loaded = ShellConfig.load(shellDirectory: shellDirectory, problems: &problems)
        configProblems = problems
        guard let next = loaded else { return }
        applyConfig(next, problems: problems)
    }

    func applyConfig(_ next: ShellConfig, problems: [String] = []) {
        let problemsChanged = configProblems != problems
        configProblems = problems
        guard next != config else {
            if problemsChanged { publishToggleNames() }
            return
        }
        let previous = config
        if next.profile != previous.profile { closeHiddenBarMenu() }
        config = next
        refreshBarShaders()
        updateConfiguredComponents(next, from: previous)
        onConfigChange?(next)
        if next.theme != previous.theme || next.barOverride?.accentColor != previous.barOverride?.accentColor
            || next.barOverride?.textColor != previous.barOverride?.textColor
        {
            Log.shell.notice("Using theme \(next.themeName)")
            appearanceDidChange()
        }
        if next.themeName != previous.themeName || next.wallpaperScheme != previous.wallpaperScheme {
            updateWallpaperPalette()
        }
        updateConfiguredWidgets(next, from: previous)
        updateConfiguredLayout(next, from: previous)
        publishToggleNames()
    }

    private func updateConfiguredComponents(_ next: ShellConfig, from previous: ShellConfig) {
        if next.island?.root != previous.island?.root || next.directories != previous.directories {
            configurationCatalog = nil
            for state in widgets.values { publishConfigurationCatalog(to: state) }
            processConfigurationQueue()
        }
        if next.island?.root != previous.island?.root {
            for name in Set([previous.island?.root, next.island?.root].compactMap { $0 }) {
                guard let state = widgets[name] else { continue }
                state.fingerprint = fingerprint(of: state.sourceURL)
                load(state)
            }
        }
    }

    private func updateConfiguredWidgets(_ next: ShellConfig, from previous: ShellConfig) {
        feed?.setWeatherLocation(next.weather)
        for state in widgets.values where next.widgetSettings[state.name] != previous.widgetSettings[state.name] {
            state.mailbox?.yield(.settings(next.widgetSettings[state.name] ?? []))
        }
        if next.widgetIntervals != previous.widgetIntervals {
            for state in widgets.values {
                state.mailbox?.yield(.interval(interval(of: state)))
            }
            publishDemand()
        }
        if next.drawers != previous.drawers {
            closeDrawer()
        }
        if next.directories == previous.directories, next.island?.root == previous.island?.root,
           next.island?.components != previous.island?.components
        {
            syncComponents()
        }
    }

    private func updateConfiguredLayout(_ next: ShellConfig, from previous: ShellConfig) {
        let lanesChanged = next.leading != previous.leading || next.center != previous.center
            || next.trailing != previous.trailing || next.drawers != previous.drawers
        if lanesChanged || next.directories != previous.directories || next.island != previous.island {
            updateIslands(desiredIslands, level: islandLevel)
            rescan(reloadConfiguration: false)
            onLayoutChange()
        } else if next.barShader != previous.barShader {
            onLayoutChange()
        }
    }
}
