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
        case let .herdr(savedMachines): reloadHerdr(savedMachines: savedMachines)
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
                    String(localized: "Ghostty \($0) doesn’t reload on a signal; update it, or reload its config with ⌘⇧,")
                } ?? String(
                    localized: "OmniWM can’t tell which Ghostty version is running, so it didn’t signal it; reload its config with ⌘⇧,"
                ))
                continue
            }
            let error = environment.signal(app.pid, SIGUSR2)
            if error != 0, error != ESRCH {
                problems.append(String(localized: "Ghostty didn’t reload") + ": " + String(cString: strerror(error)))
            }
        }
        return problems.isEmpty
            ? AppThemeReloadOutcome(succeeded: true, message: String(localized: "Reloaded Ghostty"))
            : AppThemeReloadOutcome(succeeded: false, message: problems.joined(separator: " · "))
    }

    private func reloadKitty(newFiles: Bool) -> AppThemeReloadOutcome {
        let result = environment.run("/usr/bin/pkill", ["-USR1", "-U", String(environment.userID), "-x", "kitty"], 3)
        switch result.status {
        case 0 where !result.timedOut:
            return AppThemeReloadOutcome(
                succeeded: true,
                message: newFiles
                    ? String(localized: "Reloaded kitty; kitty 0.49 or older uses new theme files after a restart")
                    : String(localized: "Reloaded kitty")
            )
        case 1 where !result.timedOut:
            return AppThemeReloadOutcome(
                succeeded: true,
                message: String(localized: "kitty isn’t running; it uses the new theme when it opens")
            )
        default:
            return failure(String(localized: "kitty didn’t reload"), result)
        }
    }

    private func reloadNeovim() -> AppThemeReloadOutcome {
        let result = environment.run("/usr/bin/pkill", ["-USR1", "-U", String(environment.userID), "-x", "nvim"], 3)
        switch result.status {
        case 0 where !result.timedOut:
            return AppThemeReloadOutcome(succeeded: true, message: String(localized: "Reloaded Neovim"))
        case 1 where !result.timedOut:
            return AppThemeReloadOutcome(
                succeeded: true,
                message: String(localized: "Neovim isn’t running; it loads the new colors when it starts")
            )
        default:
            return failure(String(localized: "Neovim didn’t reload"), result)
        }
    }

    private func reloadHerdr(savedMachines: Bool) -> AppThemeReloadOutcome {
        guard let herdr = environment.executable("herdr") else {
            return AppThemeReloadOutcome(
                succeeded: false,
                message: String(localized: "herdr wasn’t found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin")
            )
        }
        let local = environment.run(herdr, ["server", "reload-config"], 5)
        let notRunning = local.output.contains("server_not_running") || local.output.contains("not running")
        var outcome = if local.succeeded {
            AppThemeReloadOutcome(succeeded: true, message: String(localized: "Reloaded herdr"))
        } else if notRunning, !local.timedOut {
            AppThemeReloadOutcome(
                succeeded: true,
                message: String(localized: "herdr isn’t running; it uses the new colors when it starts")
            )
        } else {
            failure(String(localized: "herdr didn’t reload"), local)
        }
        if savedMachines, let remote = reloadSavedMachines(herdr) {
            outcome.message += " · " + remote
        }
        return outcome
    }

    private func reloadSavedMachines(_ herdr: String) -> String? {
        let listing = environment.run(herdr, ["machine", "list", "--json"], 3)
        guard listing.succeeded else { return String(localized: "saved machines couldn’t be listed") }
        let labels = Self.enabledMachines(in: listing.output)
        guard !labels.isEmpty else { return nil }
        let results = AppThemeLockedArray<Bool>(count: labels.count, value: false)
        DispatchQueue.concurrentPerform(iterations: labels.count) { index in
            let result = environment.run(herdr, ["--machine", labels[index], "server", "reload-config"], 5)
            results.set(index, result.succeeded)
        }
        let reloaded = results.values.filter(\.self).count
        return String(localized: "\(reloaded) of \(labels.count) saved machines reloaded")
    }

    static func enabledMachines(in json: String) -> [String] {
        struct Machine: Decodable {
            let label: String?
            let enabled: Bool?
        }
        let machines = (try? JSONDecoder().decode([Machine].self, from: Data(json.utf8))) ?? []
        return machines.compactMap { machine in
            guard machine.enabled == true, let label = machine.label, !label.isEmpty, !label.hasPrefix("-") else {
                return nil
            }
            return label
        }
    }

    private func failure(_ summary: String, _ result: AppThemeCommandResult) -> AppThemeReloadOutcome {
        let detail = result.timedOut ? String(localized: "timed out") : result.output
        return AppThemeReloadOutcome(
            succeeded: false,
            message: detail.isEmpty ? summary : "\(summary): \(detail.prefix(200))"
        )
    }
}

final class AppThemeLockedArray<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element]

    init(count: Int, value: Element) {
        storage = Array(repeating: value, count: count)
    }

    var values: [Element] {
        lock.withLock { storage }
    }

    func set(_ index: Int, _ value: Element) {
        lock.withLock { storage[index] = value }
    }
}
