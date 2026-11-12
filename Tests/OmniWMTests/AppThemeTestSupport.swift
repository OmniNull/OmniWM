// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import os

enum AppThemeFixtures {
    static func roles(_ values: [ShellRole: String]) -> [ShellRole: AppThemeColor] {
        values.compactMapValues { AppThemeColor(hex: $0) }
    }

    static let light = roles([
        .background: "#EFF1F5", .surface: "#E6E9EF", .elevatedSurface: "#DCE0E8", .foreground: "#4C4F69",
        .secondaryForeground: "#5C5F77", .mutedForeground: "#6C6F85", .border: "#A5ADCB", .accent: "#8839EF",
        .accentForeground: "#EFF1F5", .accentContainer: "#D9C6FA", .accentContainerForeground: "#2A1450",
        .red: "#D20F39", .green: "#40A02B", .yellow: "#DF8E1D", .blue: "#1E66F5", .purple: "#8839EF",
        .cyan: "#04A5E5", .scrim: "#11111B66", .secondaryAccent: "#179299", .tertiaryAccent: "#EA76CB",
        .error: "#D20F39"
    ])

    static let dark = roles([
        .background: "#11111B", .surface: "#181825", .elevatedSurface: "#1E1E2E", .foreground: "#CDD6F4",
        .secondaryForeground: "#BAC2DE", .mutedForeground: "#A6ADC8", .border: "#4C4F69", .accent: "#CBA6F7",
        .accentForeground: "#11111B", .accentContainer: "#45307A", .accentContainerForeground: "#EADCFF",
        .red: "#F38BA8", .green: "#A6E3A1", .yellow: "#F9E2AF", .blue: "#89B4FA", .purple: "#CBA6F7",
        .cyan: "#89DCEB", .scrim: "#11111B66", .secondaryAccent: "#94E2D5", .tertiaryAccent: "#F5C2E7",
        .error: "#F38BA8"
    ])

    static let palette = AppThemePalette(light: light, dark: dark)

    static func shifted(_ hex: String) -> AppThemePalette {
        var dark = dark
        dark[.background] = AppThemeColor(hex: hex)
        return AppThemePalette(light: light, dark: dark)
    }
}

final class AppThemeFakeEnvironment: @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    struct Signal: Equatable {
        let pid: pid_t
        let signal: Int32
    }

    static let ghosttyPID: pid_t = 4242
    static let kittyPID: pid_t = 4343
    static let neovimPID: pid_t = 4444

    private let lock = NSLock()
    private var recorded: [String] = []
    private var commands: [Call] = []
    private var sent: [Signal] = []
    var responses: [String: AppThemeCommandResult] = [:]
    var ghostty: [AppThemeGhosttyApp] = []
    var processes: [String: [pid_t]] = ["kitty": [kittyPID], "nvim": [neovimPID]]
    var signalErrors: [pid_t: Int32] = [:]
    var executables: [String: String] = ["herdr": "/opt/homebrew/bin/herdr"]
    var onEvent: (@Sendable (String) -> Void)?
    var variables: [String: String] = ["HOME": "/Users/omniwm-test"]
    var herdrReply = AppThemeSocketReply.line(
        #"{"id":"omniwm:app-theming","result":{"type":"config_reload","status":"applied","diagnostics":[]}}"#
    )
    private var sockets: [String] = []

    var herdrSockets: [String] {
        lock.withLock { sockets }
    }

    var calls: [Call] {
        lock.withLock { commands }
    }

    var signals: [Signal] {
        lock.withLock { sent }
    }

    var events: [String] {
        lock.withLock { recorded }
    }

    func runGhostty(version: String = "1.4.0") {
        ghostty = [AppThemeGhosttyApp(pid: Self.ghosttyPID, version: version)]
    }

    private func announce(_ event: String) {
        let hook = lock.withLock { onEvent }
        hook?(event)
    }

    var environment: AppThemeEnvironment {
        AppThemeEnvironment(
            run: { [self] executable, arguments, _ in
                let event = (["run", executable] + arguments).joined(separator: " ")
                defer { announce(event) }
                return lock.withLock {
                    commands.append(Call(executable: executable, arguments: arguments))
                    recorded.append(event)
                    let key = ([executable] + arguments).joined(separator: " ")
                    return responses.first { key.hasPrefix($0.key) }?.value
                        ?? AppThemeCommandResult(status: 0, output: "")
                }
            },
            ghosttyApps: { [self] in lock.withLock { ghostty } },
            processes: { [self] name in
                lock.withLock { (processes[name] ?? []).map { AppThemeProcess(listed: $0, name: name) } }
            },
            signal: { [self] process, signal in
                let pid = process.pid
                let event = "signal \(pid) \(signal)"
                defer { announce(event) }
                return lock.withLock {
                    sent.append(Signal(pid: pid, signal: signal))
                    recorded.append(event)
                    return signalErrors[pid] ?? 0
                }
            },
            herdr: { [self] socket, method in
                defer { announce("herdr \(method)") }
                return lock.withLock {
                    sockets.append(socket)
                    recorded.append("herdr \(method)")
                    return herdrReply
                }
            },
            variables: variables,
            executable: { [self] name in lock.withLock { executables[name] } }
        )
    }
}

struct AppThemeSandbox {
    let root: URL
    let home: URL
    let policy: AppThemeOutputPolicy
    let store: AppThemeStateStore

    init() throws {
        let temporary = AppThemeOutputPolicy.resolve(FileManager.default.temporaryDirectory)
        root = temporary.appendingPathComponent("AppTheme-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".config"),
            withIntermediateDirectories: true
        )
        policy = AppThemeOutputPolicy.live(environment: [:], home: home)
        store = AppThemeStateStore(directory: home.appendingPathComponent(".local/state/omniwm/app-theming"))
    }

    func path(_ relative: String) -> URL {
        home.appendingPathComponent(relative)
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOf: path(relative), encoding: .utf8)
    }

    func write(_ text: String, to relative: String) throws {
        let url = path(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func engine(_ fake: AppThemeFakeEnvironment) -> AppThemeEngine {
        AppThemeEngine(policy: policy, store: store, environment: fake.environment)
    }

    @MainActor
    func service(
        _ settings: AppThemingSettings,
        _ fake: AppThemeFakeEnvironment,
        perform: @escaping AppThemeService.Perform = { $0() },
        deliver: @escaping AppThemeService.Deliver = { MainActor.assumeIsolated($0) },
        systemIsDark: @escaping @MainActor () -> Bool
    ) -> AppThemeService {
        AppThemeService(
            settings: settings,
            engine: engine(fake),
            systemIsDark: systemIsDark,
            perform: perform,
            deliver: deliver
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class AppThemeTestFlag {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

@MainActor
final class AppThemeTestCounter {
    var value = 0
}

final class AppThemeHeldWork: Sendable {
    private let held = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])

    var count: Int {
        held.withLock { $0.count }
    }

    func perform(_ work: @escaping @Sendable () -> Void) {
        held.withLock { $0.append(work) }
    }

    func release() {
        let work = held.withLock { held in
            defer { held.removeAll() }
            return held
        }
        for item in work {
            item()
        }
    }
}

final class AppThemeHeldHops: Sendable {
    private let held = OSAllocatedUnfairLock<[@MainActor @Sendable () -> Void]>(initialState: [])

    var count: Int {
        held.withLock { $0.count }
    }

    func deliver(_ work: @escaping @MainActor @Sendable () -> Void) {
        held.withLock { $0.append(work) }
    }

    @MainActor
    func release() {
        let work = held.withLock { held in
            defer { held.removeAll() }
            return held
        }
        for item in work {
            item()
        }
    }
}

extension AppThemeProcess {
    init(listed pid: pid_t, name: String) {
        self.init(pid: pid, startSeconds: 0, startMicroseconds: 0, realUserID: getuid(), name: name)
    }
}

extension AppThemeGhosttyApp {
    init(pid: pid_t, version: String?) {
        self.init(process: AppThemeProcess(listed: pid, name: "ghostty"), version: version)
    }
}

final class AppThemeSeen: Sendable {
    private let seen = OSAllocatedUnfairLock(initialState: false)

    var value: Bool {
        seen.withLock { $0 }
    }

    func note(_ value: Bool) {
        seen.withLock { $0 = $0 || value }
    }

    static func replacementIsPrepared(beside url: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.contains { $0.hasPrefix(".\(url.lastPathComponent).omniwm-") }
    }

    static func leftovers(beside url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasPrefix(".") && $0.hasSuffix(".tmp") }
    }
}
