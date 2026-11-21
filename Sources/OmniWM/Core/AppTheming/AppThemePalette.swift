// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

struct AppThemePalette: Equatable, Sendable {
    struct Scheme: Equatable, Sendable {
        let roles: [ShellRole: AppThemeColor]
        let ansi: [AppThemeColor]
        let base16: [String: AppThemeColor]

        init(
            roles: [ShellRole: AppThemeColor],
            dark: Bool,
            terminalColors: AppThemeTerminalColors = .palette,
            ownHues: Bool = true
        ) {
            self.roles = roles
            ansi = AppThemeANSI.colors(roles: roles, dark: dark, terminalColors: terminalColors, ownHues: ownHues)
            base16 = AppThemeBase16.colors(roles: roles, ansi: ansi)
        }
    }

    let light: Scheme
    let dark: Scheme

    init(
        light: [ShellRole: AppThemeColor],
        dark: [ShellRole: AppThemeColor],
        terminalColors: AppThemeTerminalColors = .palette,
        ownHues: Bool = true
    ) {
        self.light = Scheme(roles: light, dark: false, terminalColors: terminalColors, ownHues: ownHues)
        self.dark = Scheme(roles: dark, dark: true, terminalColors: terminalColors, ownHues: ownHues)
    }

    @MainActor
    init(theme: ShellTheme, terminalColors: AppThemeTerminalColors = .palette) {
        self.init(
            light: Self.resolve(theme, dark: false),
            dark: Self.resolve(theme, dark: true),
            terminalColors: terminalColors,
            ownHues: Self.ownsHues(theme)
        )
    }

    @MainActor
    static func ownsHues(_ theme: ShellTheme) -> Bool {
        let native = ShellTheme.native
        let setsHues = AppThemeANSI.hueRoles.contains { role in
            theme.light[role.rawValue] != native.light[role.rawValue] ||
                theme.dark[role.rawValue] != native.dark[role.rawValue]
        }
        let materialPalette = !theme.derivedLight.contains(.tertiaryAccent) || !theme.derivedDark
            .contains(.tertiaryAccent)
        return setsHues || !materialPalette
    }

    func scheme(dark isDark: Bool) -> Scheme {
        isDark ? dark : light
    }

    @MainActor
    private static func resolve(_ theme: ShellTheme, dark: Bool) -> [ShellRole: AppThemeColor] {
        let source = dark ? theme.dark : theme.light
        var colors: [CGColor] = []
        if let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) {
            appearance.performAsCurrentDrawingAppearance {
                colors = source.map(\.cgColor)
            }
        } else {
            colors = source.map(\.cgColor)
        }
        theme.deriveRoles(&colors, dark: dark)
        var roles: [ShellRole: AppThemeColor] = [:]
        for role in ShellRole.allCases where colors.indices.contains(role.rawValue) {
            roles[role] = AppThemeColor(ShellRGBA(colors[role.rawValue]))
        }
        return roles
    }
}
