// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct AppThemeReloadOutcome: Equatable, Sendable {
    var succeeded: Bool
    var message: String
}

struct AppThemeReloader: Sendable {
    let environment: AppThemeEnvironment

    func reload(_ action: AppThemeReloadAction, newFiles: Bool = false) -> AppThemeReloadOutcome {
        switch action {
        case .ghostty: reloadGhostty()
        case .kitty: reloadKitty(newFiles: newFiles)
        case .neovim: reloadNeovim()
        }
    }

    private func reloadGhostty() -> AppThemeReloadOutcome {
        let apps = environment.ghosttyApps()
        guard !apps.isEmpty else {
            return AppThemeReloadOutcome(
                succeeded: true,
                message: String(localized: "Ghostty isn’t running; it uses the new theme when it opens")
            )
        }
        var problems: [String] = []
        for app in apps {
            guard app.reloadsOnSignal else {
                problems.append(app.version.map {
                    String(
                        localized: "Ghostty \($0) doesn’t reload on a signal; update it, or reload its config with ⌘⇧,"
                    )
                } ?? String(
                    localized: "OmniWM can’t tell which Ghostty version is running, so it didn’t signal it; reload its config with ⌘⇧,"
                ))
                continue
            }
            let error = environment.signal(app.process, SIGUSR2)
            if error != 0, error != ESRCH {
                problems.append(failure(String(localized: "Ghostty didn’t reload"), error: error).message)
            }
        }
        return problems.isEmpty
            ? AppThemeReloadOutcome(succeeded: true, message: String(localized: "Reloaded Ghostty"))
            : AppThemeReloadOutcome(succeeded: false, message: problems.joined(separator: " · "))
    }

    private func reloadKitty(newFiles: Bool) -> AppThemeReloadOutcome {
        switch signalAll("kitty") {
        case .notRunning:
            AppThemeReloadOutcome(
                succeeded: true,
                message: String(localized: "kitty isn’t running; it uses the new theme when it opens")
            )
        case .signalled:
            AppThemeReloadOutcome(
                succeeded: true,
                message: newFiles
                    ? String(localized: "Reloaded kitty; kitty 0.49 or older uses new theme files after a restart")
                    : String(localized: "Reloaded kitty")
            )
        case let .failed(error):
            failure(String(localized: "kitty didn’t reload"), error: error)
        }
    }

    private func reloadNeovim() -> AppThemeReloadOutcome {
        switch signalAll("nvim") {
        case .notRunning:
            AppThemeReloadOutcome(
                succeeded: true,
                message: String(localized: "Neovim isn’t running; it loads the new colors when it starts")
            )
        case .signalled:
            AppThemeReloadOutcome(succeeded: true, message: String(localized: "Reloaded Neovim"))
        case let .failed(error):
            failure(String(localized: "Neovim didn’t reload"), error: error)
        }
    }

    private enum Signalled {
        case notRunning
        case signalled
        case failed(Int32)
    }

    private func signalAll(_ name: String) -> Signalled {
        let processes = environment.processes(name)
        guard !processes.isEmpty else { return .notRunning }
        var firstError: Int32?
        for process in processes {
            let error = environment.signal(process, SIGUSR1)
            if error != 0, error != ESRCH, firstError == nil { firstError = error }
        }
        return firstError.map(Signalled.failed) ?? .signalled
    }

    private func failure(_ summary: String, error: Int32) -> AppThemeReloadOutcome {
        AppThemeReloadOutcome(succeeded: false, message: summary + ": " + String(cString: strerror(error)))
    }
}
