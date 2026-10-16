// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

struct ShellRGBA: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    private static let space = CGColorSpace(name: CGColorSpace.extendedSRGB)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: CGColor) {
        let converted = Self.space.flatMap { color.converted(to: $0, intent: .defaultIntent, options: nil) } ?? color
        let components = (converted.components ?? []).map(Double.init)
        switch components.count {
        case 4: self.init(red: components[0], green: components[1], blue: components[2], alpha: components[3])
        case 2: self.init(red: components[0], green: components[0], blue: components[0], alpha: components[1])
        default: self.init(red: 0, green: 0, blue: 0, alpha: 0)
        }
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var luminance: Double {
        func linear(_ value: Double) -> Double {
            let value = min(max(value, 0), 1)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(_ other: ShellRGBA) -> Double {
        let (light, dark) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (light + 0.05) / (dark + 0.05)
    }

    func mixed(with other: ShellRGBA, _ amount: Double) -> ShellRGBA {
        ShellRGBA(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount,
            alpha: alpha
        )
    }

    func shifted(hue degrees: Double, saturation factor: Double) -> ShellRGBA {
        let (top, bottom) = (max(red, green, blue), min(red, green, blue))
        let chroma = top - bottom
        var hue = 0.0
        if chroma > 0 {
            hue = switch top {
            case red: ((green - blue) / chroma).truncatingRemainder(dividingBy: 6)
            case green: (blue - red) / chroma + 2
            default: (red - green) / chroma + 4
            }
        }
        hue = ((hue * 60 + degrees).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let saturation = top > 0 ? chroma / top * factor : 0
        let shifted = top * saturation
        let sector = hue / 60
        let second = shifted * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base = top - shifted
        let channels: [Double] = switch Int(sector) {
        case 0: [shifted, second, 0]
        case 1: [second, shifted, 0]
        case 2: [0, shifted, second]
        case 3: [0, second, shifted]
        case 4: [second, 0, shifted]
        default: [shifted, 0, second]
        }
        return ShellRGBA(red: channels[0] + base, green: channels[1] + base, blue: channels[2] + base, alpha: alpha)
    }
}

extension ShellTheme {
    static let derivedRoles: Set<ShellRole> = [
        .highestSurface, .accentContainer, .accentContainerForeground, .secondaryAccent, .secondaryContainer,
        .secondaryContainerForeground, .tertiaryAccent, .tertiaryContainer, .tertiaryContainerForeground
    ]

    private struct Family {
        let base: ShellRGBA
        let accent: ShellRole
        let container: ShellRole
        let text: ShellRole
    }

    func deriveRoles(_ colors: inout [CGColor], dark: Bool) {
        let derived = dark ? derivedDark : derivedLight
        guard !derived.isEmpty else { return }
        var values = colors.map(ShellRGBA.init)
        let foreground = values[ShellRole.foreground.rawValue]
        if derived.contains(.highestSurface) {
            values[ShellRole.highestSurface.rawValue] = Self.readable(
                values[ShellRole.elevatedSurface.rawValue].mixed(with: foreground, 0.08),
                under: foreground,
                toward: values[ShellRole.background.rawValue]
            )
        }
        for family in Self.families(of: values[ShellRole.accent.rawValue]) {
            Self.derive(family, derived, in: &values)
        }
        for role in derived {
            colors[role.rawValue] = values[role.rawValue].cgColor
        }
    }

    private static func families(of accent: ShellRGBA) -> [Family] {
        [
            Family(base: accent, accent: .accent, container: .accentContainer, text: .accentContainerForeground),
            Family(
                base: accent.shifted(hue: 0, saturation: 0.45),
                accent: .secondaryAccent,
                container: .secondaryContainer,
                text: .secondaryContainerForeground
            ),
            Family(
                base: accent.shifted(hue: 60, saturation: 1),
                accent: .tertiaryAccent,
                container: .tertiaryContainer,
                text: .tertiaryContainerForeground
            )
        ]
    }

    private static func derive(_ family: Family, _ derived: Set<ShellRole>, in values: inout [ShellRGBA]) {
        let foreground = values[ShellRole.foreground.rawValue]
        let background = values[ShellRole.background.rawValue]
        let surface = values[ShellRole.surface.rawValue]
        if derived.contains(family.accent) {
            let grounds = [ShellRole.background, .surface, .elevatedSurface, .highestSurface]
                .map { values[$0.rawValue] }
            values[family.accent.rawValue] = lift(family.base, above: grounds, toward: foreground)
        }
        if derived.contains(family.container) {
            let text = derived.contains(family.text) ? foreground : values[family.text.rawValue]
            values[family.container.rawValue] = readable(
                surface.mixed(with: values[family.accent.rawValue], 0.35),
                under: text,
                toward: surface
            )
        }
        if derived.contains(family.text) {
            let container = values[family.container.rawValue]
            values[family.text.rawValue] = foreground.contrast(container) >= background.contrast(container)
                ? foreground : background
        }
    }

    func resolvedColor(_ role: ShellRole, dark: Bool) -> NSColor {
        let source = dark ? self.dark : light
        guard (dark ? derivedDark : derivedLight).contains(role),
              let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        else {
            return source[role.rawValue]
        }
        var colors: [CGColor] = []
        appearance.performAsCurrentDrawingAppearance {
            colors = source.map(\.cgColor)
        }
        deriveRoles(&colors, dark: dark)
        return NSColor(cgColor: colors[role.rawValue]) ?? source[role.rawValue]
    }

    private static func readable(_ color: ShellRGBA, under text: ShellRGBA, toward target: ShellRGBA) -> ShellRGBA {
        (0 ... 10).lazy.map { color.mixed(with: target, Double($0) / 10) }.first { $0.contrast(text) >= 4.5 } ?? target
    }

    private static func lift(_ color: ShellRGBA, above grounds: [ShellRGBA], toward target: ShellRGBA) -> ShellRGBA {
        (0 ... 10).lazy.map { color.mixed(with: target, Double($0) / 10) }
            .first { candidate in grounds.allSatisfy { candidate.contrast($0) >= 3 } } ?? target
    }
}
