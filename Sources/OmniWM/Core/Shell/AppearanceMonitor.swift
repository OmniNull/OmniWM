// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

enum ShellAppearanceCommand: Equatable, Sendable {
    case toggle

    init?(words: [String]) {
        guard words == ["toggle"] else { return nil }
        self = .toggle
    }

    func perform() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        ]
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                Log.shell.error("Switching the appearance failed: osascript exited with \(process.terminationStatus)")
            }
        }
        do {
            try process.run()
        } catch {
            Log.shell.error("Switching the appearance failed: \(error.localizedDescription)")
        }
    }
}

struct ShellAppearance: Equatable, Sendable, ShellValueWritable {
    var dark: Bool

    func write(into writer: inout ShellValueWriter) {
        writer.string(dark ? "dark" : "light")
    }

    static func of(_ appearance: NSAppearance) -> ShellAppearance {
        ShellAppearance(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
}

@MainActor
final class AppearanceMonitor: ShellDeviceSource {
    private(set) var value: ShellAppearance?
    var onChange: ((ShellAppearance?) -> Void)?
    private var listening = false

    func setListening(_ listening: Bool) {
        self.listening = listening
        value = listening ? .of(NSApplication.shared.effectiveAppearance) : nil
    }

    func refresh() {
        let next = ShellAppearance.of(NSApplication.shared.effectiveAppearance)
        guard listening, next != value else { return }
        value = next
        onChange?(next)
    }
}
