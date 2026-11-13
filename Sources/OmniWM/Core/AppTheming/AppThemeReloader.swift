// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import os

struct AppThemeReloadOutcome: Equatable, Sendable {
    var succeeded: Bool
    var message: String
}

struct AppThemeHerdrReply: Decodable {
    struct Result: Decodable {
        let status: String?
        let diagnostics: [String]?
    }

    struct Failure: Decodable {
        let message: String?
    }

    let result: Result?
    let error: Failure?
}

struct AppThemeReloader: Sendable {
    static let messageLimit = 200
    static let machineListTimeout: TimeInterval = 3
    static let machineReloadTimeout: TimeInterval = 5

    let environment: AppThemeEnvironment
    var isCurrent: @Sendable () -> Bool = { true }

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

    private func reloadHerdr(savedMachines: Bool) -> AppThemeReloadOutcome {
        let socket = AppThemeHerdrSocket.path(variables: environment.variables, home: environment.home)
        var outcome = Self.herdrOutcome(environment.herdr(socket, "server.reload_config"))
        guard savedMachines, isCurrent() else { return outcome }
        if let herdr = environment.executable("herdr") {
            if let remote = reloadSavedMachines(herdr) {
                outcome.succeeded = outcome.succeeded && remote.succeeded
                outcome.message += " · " + remote.message
            }
        } else {
            outcome.succeeded = false
            outcome.message += " · " + String(
                localized: "saved machines need herdr in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin"
            )
        }
        return outcome
    }

    static func herdrOutcome(_ reply: AppThemeSocketReply) -> AppThemeReloadOutcome {
        let summary = String(localized: "herdr didn’t reload")
        switch reply {
        case .notRunning:
            return AppThemeReloadOutcome(
                succeeded: true,
                message: String(localized: "herdr isn’t running; it uses the new colors when it starts")
            )
        case let .failed(problem):
            return AppThemeReloadOutcome(succeeded: false, message: summary + ": " + problem)
        case let .line(text):
            guard let reply = try? JSONDecoder().decode(AppThemeHerdrReply.self, from: Data(text.utf8)) else {
                return AppThemeReloadOutcome(
                    succeeded: false,
                    message: summary + ": " + String(text.prefix(messageLimit))
                )
            }
            if let error = reply.error {
                return AppThemeReloadOutcome(succeeded: false, message: summary + ": " + (error.message ?? ""))
            }
            let details = (reply.result?.diagnostics ?? []).joined(separator: "; ")
            switch reply.result?.status {
            case "applied":
                return AppThemeReloadOutcome(succeeded: true, message: String(localized: "Reloaded herdr"))
            case "partial":
                return AppThemeReloadOutcome(
                    succeeded: true,
                    message: String(localized: "Reloaded herdr with warnings") + ": " + details
                )
            default:
                return AppThemeReloadOutcome(
                    succeeded: false,
                    message: String(localized: "herdr couldn’t apply its config") + ": " + details
                )
            }
        }
    }

    private func reloadSavedMachines(_ herdr: String) -> AppThemeReloadOutcome? {
        let listing = environment.run(herdr, ["machine", "list", "--json"], Self.machineListTimeout)
        guard listing.succeeded, let labels = try? Self.enabledMachines(in: listing.output) else {
            return AppThemeReloadOutcome(
                succeeded: false,
                message: String(localized: "saved machines couldn’t be listed")
            )
        }
        guard !labels.isEmpty, isCurrent() else { return nil }
        let successes = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: labels.count) { index in
            guard isCurrent() else { return }
            let result = environment.run(
                herdr,
                ["--machine", labels[index], "server", "reload-config"],
                Self.machineReloadTimeout
            )
            if result.succeeded { successes.withLock { $0 += 1 } }
        }
        let reloaded = successes.withLock { $0 }
        return AppThemeReloadOutcome(
            succeeded: reloaded == labels.count,
            message: String(localized: "\(reloaded) of \(labels.count) saved machines reloaded")
        )
    }

    private static func enabledMachines(in json: String) throws -> [String] {
        struct Machine: Decodable {
            let label: String?
            let enabled: Bool?
        }
        let machines = try JSONDecoder().decode([Machine].self, from: Data(json.utf8))
        return machines.compactMap { machine in
            guard machine.enabled == true, let label = machine.label, !label.isEmpty, !label.hasPrefix("-") else {
                return nil
            }
            return label
        }
    }
}
