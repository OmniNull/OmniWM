// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

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
