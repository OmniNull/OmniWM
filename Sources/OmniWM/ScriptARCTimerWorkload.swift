// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost
import ScriptARCCounters

private actor ScriptARCTimerClock {
    private var fired = false

    func next() throws {
        if fired {
            script_arc_finish()
            throw CancellationError()
        }
        fired = true
        script_arc_follow_timer()
    }
}

@MainActor
extension ScriptARCFixture {
    func timerEvents(in directory: URL) async throws {
        let interval = Double(OMNI_CONFIG_TIMER_MINIMUM_SECONDS)
        let cases = [
            ("timer/empty", "function() end"),
            ("timer/reads", "function(e) assert(#e.workspaceWindows > 0) end, {reads={'workspaceWindows'}}"),
            ("timer/effect", "function() omniwm.dispatch(omniwm.cmd.focusMonitor('next')) end")
        ]
        script.stop()
        for (route, code) in cases {
            for report in [false, true] {
                let clock = ScriptARCTimerClock()
                let owner = ConfigScriptController(
                    fileURL: directory.appendingPathComponent("init.luau"), settings: controller.settings,
                    wmController: controller, timerSleep: { _ in try await clock.next() }, didChangeBindings: { _ in }
                )
                controller.configScript = owner
                let mask = controller.settings.hyperKeyModifiers.carbonMask
                let source = "omniwm.timer({everySeconds=\(interval)}, \(code))"
                let evaluation = try await loader.evaluate(Data(source.utf8), hyperMask: mask)
                precondition(owner.apply(.init(versions: [:], result: .success(evaluation)), hyperMask: mask))
                await owner.timerWorker!.value
                if let diagnostic = owner.diagnostic { throw ScriptARCError(route + ": " + diagnostic) }
                if report { script_arc_report(route, "native", 1) }
                owner.stop()
            }
        }
    }
}
