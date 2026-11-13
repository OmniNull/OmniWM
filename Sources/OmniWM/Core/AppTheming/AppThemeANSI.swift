// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum AppThemeANSI {
    static let readableContrast = ShellRGBA.readableTextContrast
    static let hueRoles: [ShellRole] = [.red, .green, .yellow, .blue, .purple, .cyan]
    static let colorCount = 16
    static let normalHueSlots = 1 ... 6
    static let brightHueSlots = 9 ... 14
    private static let brightLightness = 0.08
    private static let brightSaturation = 1.15
    private static let hueNudges: [Double] = [0, 10, -10, 20, -20]
    private static let lightnessNudges: [Double] = [0, 0.05, 0.1]
    static let maximumHueShift = 15.0
    private static let minimumChroma = 0.05

    static var maximumHueNudge: Double {
        hueNudges.map(abs).max() ?? 0
    }

    static let fixedDimLightness = 0.78

    private struct Ground {
        let background: AppThemeColor
        let lightens: Bool
        let foreground: AppThemeColor
        let keepsHue: Bool
    }

    static func colors(
        roles: [ShellRole: AppThemeColor],
        dark: Bool,
        terminalColors: AppThemeTerminalColors = .palette,
        ownHues: Bool = true
    ) -> [AppThemeColor] {
        let background = (roles[.background] ?? (dark ? .black : .white)).opaque
        let lightens = AppThemeColor.white.contrast(background) >= AppThemeColor.black.contrast(background)
        let bestExtreme = lightens ? AppThemeColor.white : .black
        let foregroundRole = (roles[.foreground] ?? bestExtreme).opaque
        let foreground = readable(foregroundRole, on: background, lightens: lightens) ?? bestExtreme
        let followsAccents = terminalColors == .palette && !ownHues
        let ground = Ground(
            background: background,
            lightens: lightens,
            foreground: foreground,
            keepsHue: followsAccents
        )
        var palette = [AppThemeColor](repeating: foreground, count: colorCount)
        palette[0] = ((followsAccents ? roles[.highestSurface] : nil) ?? roles[.surface] ?? background).opaque
        palette[7] = readable((roles[.secondaryForeground] ?? foreground).opaque, on: background, lightens: lightens)
            ?? foreground
        palette[8] = readable((roles[.mutedForeground] ?? foreground).opaque, on: background, lightens: lightens)
            ?? foreground
        palette[15] = foreground
        var used: Set<AppThemeColor> = [palette[7], palette[8], palette[15]]
        let sources = followsAccents
            ? accentSources(roles, foreground: foreground)
            : hueSources(roles, foreground: foreground, harmonize: terminalColors == .standard)
        for (offset, source) in sources.enumerated() {
            let normal = distinctReadable(source, bright: false, ground: ground, avoiding: used)
            used.insert(normal)
            let bright = distinctReadable(normal, bright: true, ground: ground, avoiding: used)
            used.insert(bright)
            palette[normalHueSlots.lowerBound + offset] = normal
            palette[brightHueSlots.lowerBound + offset] = bright
        }
        return palette
    }

    private static func hueSources(
        _ roles: [ShellRole: AppThemeColor],
        foreground: AppThemeColor,
        harmonize: Bool
    ) -> [AppThemeColor] {
        hueRoles.map { role in
            let color = (roles[role] ?? foreground).opaque
            return harmonize ? harmonized(color, toward: roles[.accent]?.opaque) : color
        }
    }

    private static func accentSources(
        _ roles: [ShellRole: AppThemeColor],
        foreground: AppThemeColor
    ) -> [AppThemeColor] {
        let primary = (roles[.accent] ?? foreground).opaque
        let secondary = roles[.secondaryAccent]?.opaque ?? primary
        let tertiary = roles[.tertiaryAccent]?.opaque ?? secondary
        let error = roles[.error]?.opaque ?? foreground
        return [error, primary, secondary, tertiary, fixedDim(primary), fixedDim(secondary)]
    }

    private static func fixedDim(_ color: AppThemeColor) -> AppThemeColor {
        var hsl = color.hsl
        hsl.lightness = fixedDimLightness
        return AppThemeColor(hsl: hsl)
    }

    private static func distinctReadable(
        _ source: AppThemeColor,
        bright: Bool,
        ground: Ground,
        avoiding used: Set<AppThemeColor>
    ) -> AppThemeColor {
        var base = source.hsl
        if bright {
            base.lightness += ground.lightens ? brightLightness : -brightLightness
            base.saturation = min(1, base.saturation * brightSaturation)
        }
        var firstReadable: AppThemeColor?
        for (hue, extra) in nudges(keepingHue: ground.keepsHue) {
            var shifted = base
            shifted.hue += hue
            shifted.lightness += ground.lightens ? extra : -extra
            guard let candidate = readable(
                AppThemeColor(hsl: shifted),
                on: ground.background,
                lightens: ground.lightens
            ) else { continue }
            if !used.contains(candidate) { return candidate }
            firstReadable = firstReadable ?? candidate
        }
        return firstReadable ?? ground.foreground
    }

    private static func nudges(keepingHue: Bool) -> [(Double, Double)] {
        keepingHue
            ? hueNudges.flatMap { hue in lightnessNudges.map { (hue, $0) } }
            : lightnessNudges.flatMap { extra in hueNudges.map { ($0, extra) } }
    }

    static func harmonized(_ color: AppThemeColor, toward accent: AppThemeColor?) -> AppThemeColor {
        guard let accent else { return color }
        let target = accent.hsl
        var hsl = color.hsl
        guard hsl.saturation > minimumChroma else { return color }
        if target.saturation > minimumChroma {
            let difference = (target.hue - hsl.hue + 540).truncatingRemainder(dividingBy: 360) - 180
            hsl.hue += min(max(difference / 2, -maximumHueShift), maximumHueShift)
        }
        hsl.saturation = (hsl.saturation + min(hsl.saturation, target.saturation)) / 2
        return AppThemeColor(hsl: hsl)
    }

    static func readable(_ color: AppThemeColor, on background: AppThemeColor, lightens: Bool) -> AppThemeColor? {
        if color.contrast(background) >= readableContrast { return color }
        var hsl = color.hsl
        let step = lightens ? 0.01 : -0.01
        for _ in 0 ..< 101 {
            hsl.lightness = min(max(hsl.lightness + step, 0), 1)
            let candidate = AppThemeColor(hsl: hsl)
            if candidate.contrast(background) >= readableContrast { return candidate }
        }
        let extreme = lightens ? AppThemeColor.white : .black
        return extreme.contrast(background) >= readableContrast ? extreme : nil
    }
}
