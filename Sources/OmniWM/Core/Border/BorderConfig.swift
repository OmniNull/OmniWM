// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics

struct BorderConfig: Equatable {
    struct ResolvedGeometry {
        let targetFrame: CGRect
        let surfaceFrame: CGRect
        let width: CGFloat
        let surfacePadding: CGFloat

        func localized() -> Self {
            let localSurfaceFrame = CGRect(origin: .zero, size: surfaceFrame.size)
            let inset = width + surfacePadding
            return Self(
                targetFrame: CGRect(
                    origin: CGPoint(x: inset, y: inset),
                    size: targetFrame.size
                ),
                surfaceFrame: localSurfaceFrame,
                width: width,
                surfacePadding: surfacePadding
            )
        }
    }

    var enabled: Bool
    var width: CGFloat
    var color: SettingsColor
    var gradient: BorderGradient?
    var glow: BorderGlow?

    init(
        enabled: Bool = false,
        width: CGFloat = 4.0,
        color: SettingsColor = SettingsColor(red: 0, green: 0.478_431_372_5, blue: 1, alpha: 1),
        gradient: BorderGradient? = nil,
        glow: BorderGlow? = nil
    ) {
        self.enabled = enabled
        self.width = width
        self.color = color
        self.gradient = gradient
        self.glow = glow
    }

    @MainActor static func from(settings: SettingsStore, isDark: Bool, palette: ShellTheme? = nil) -> BorderConfig {
        let config = BorderConfig(
            enabled: settings.borders.enabled,
            width: CGFloat(settings.borders.width),
            color: resolvedColor(settings.borders.color, dark: settings.borders.darkColor, isDark: isDark),
            gradient: settings.borders.gradient.map { resolvedGradient($0, isDark: isDark) },
            glow: settings.borders.glow.map { resolvedGlow($0, isDark: isDark) }
        )
        guard settings.borders.colorSource == .palette, let palette else { return config }
        return config.following(palette, isDark: isDark)
    }

    static func keyboardModeColor(_ kind: KeyboardModeKind) -> SettingsColor? {
        switch kind {
        case .normal: nil
        case .paused: SettingsColor(red: 1, green: 0.584, blue: 0, alpha: 1)
        case .prefix,
             .window: SettingsColor(red: 0.204, green: 0.78, blue: 0.349, alpha: 1)
        }
    }

    func indicating(_ kind: KeyboardModeKind) -> BorderConfig {
        guard let color = Self.keyboardModeColor(kind) else { return self }
        var config = self
        config.color = color
        config.gradient = nil
        config.glow?.color = color
        return config
    }

    static func resolvedColor(
        _ base: SettingsColor,
        dark: SettingsColor?,
        isDark: Bool
    ) -> SettingsColor {
        isDark ? (dark ?? base) : base
    }

    static func resolvedGradient(_ gradient: BorderGradient, isDark: Bool) -> BorderGradient {
        var resolved = gradient
        resolved.start = resolvedColor(gradient.start, dark: gradient.dark?.start, isDark: isDark)
        resolved.end = resolvedColor(gradient.end, dark: gradient.dark?.end, isDark: isDark)
        resolved.dark = nil
        return resolved
    }

    static func resolvedGlow(_ glow: BorderGlow, isDark: Bool) -> BorderGlow {
        var resolved = glow
        resolved.color = resolvedOptionalColor(glow.color, dark: glow.darkColor, isDark: isDark)
        resolved.darkColor = nil
        return resolved
    }

    private static func resolvedOptionalColor(
        _ base: SettingsColor?,
        dark: SettingsColor?,
        isDark: Bool
    ) -> SettingsColor? {
        isDark ? (dark ?? base) : base
    }

    static func layoutClearance(enabled: Bool, width: CGFloat, scale: CGFloat) -> CGFloat {
        guard enabled else { return 0 }
        let effectiveScale = max(scale, 1)
        return ceil(max(0, width) * effectiveScale) / effectiveScale
    }

    static func renderPadding(glow: BorderGlow?, scale: CGFloat) -> CGFloat {
        guard glow?.enabled == true else { return 0 }
        let effectiveScale = max(scale, 1)
        let radius = min(max(glow?.radius ?? 0, 0), 32)
        return ceil(CGFloat(radius) * 1.5 * effectiveScale) / effectiveScale
    }

    func resolvedGeometry(
        for targetFrame: CGRect,
        scale: CGFloat
    ) -> ResolvedGeometry {
        let targetFrame = targetFrame.roundedToPhysicalPixels(scale: scale)
        let width = Self.layoutClearance(enabled: enabled, width: width, scale: scale)
        let surfacePadding = Self.renderPadding(glow: glow, scale: scale)
        return ResolvedGeometry(
            targetFrame: targetFrame,
            surfaceFrame: targetFrame.insetBy(dx: -(width + surfacePadding), dy: -(width + surfacePadding)),
            width: width,
            surfacePadding: surfacePadding
        )
    }
}

extension BorderConfig {
    func following(_ palette: ShellTheme, isDark: Bool) -> BorderConfig {
        guard let accent = SettingsColor(nsColor: palette.resolvedColor(.accent, dark: isDark)) else { return self }
        var config = self
        config.color = accent
        if var gradient = config.gradient {
            gradient.start = accent
            gradient.end = SettingsColor(nsColor: palette.resolvedColor(.tertiaryAccent, dark: isDark)) ?? accent
            config.gradient = gradient
        }
        config.glow?.color = accent
        return config
    }
}
