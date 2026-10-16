// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellWidgetHost {
    func barShaderView(key: ShellBarKey) -> NSView? {
        guard started, key.placement == .bar, let shader = config.barShader else { return nil }
        if let view = barShaderViews[key] { return view }
        let view = ShellBarShaderView()
        barShaderViews[key] = view
        applyBarShader(shader, to: view)
        watchFiles()
        return view
    }

    func refreshBarShaders() {
        guard let shader = config.barShader else {
            removeBarShaders()
            return
        }
        for view in barShaderViews.values {
            applyBarShader(shader, to: view)
        }
    }

    func removeBarShaders(monitor: Monitor.ID? = nil, island: WorkspaceBarIslandSlice? = nil) {
        for (key, view) in barShaderViews where (monitor == nil || key.monitor == monitor)
            && (island == nil || key.island == island)
        {
            view.stop()
            barShaderViews.removeValue(forKey: key)
        }
    }

    func pauseBarShaders() {
        for view in barShaderViews.values {
            view.setPaused(isPaused)
        }
    }

    private func applyBarShader(_ shader: ShellBarShader, to view: ShellBarShaderView) {
        let program = resources.shaders.program(
            source: shader.source,
            directories: config.directories.map { $0.appendingPathComponent("shaders", isDirectory: true) }
        )
        let animated = resources.motion.animationsEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled
        view.update(
            program: program,
            input: ShellShaderInput(
                values: shader.values,
                rate: animated ? shader.fps : 0,
                colors: resources.palette.shaderColors
            ),
            paused: isPaused
        )
        if let failure = program.failure {
            Log.shell.error("Bar shader: \(failure)")
        }
    }
}
