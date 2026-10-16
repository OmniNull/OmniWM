// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

enum ShellRole: Int, CaseIterable {
    case background
    case surface
    case elevatedSurface
    case foreground
    case secondaryForeground
    case mutedForeground
    case border
    case accent
    case accentForeground
    case success
    case warning
    case error
    case focus
    case shadow
    case scrim
    case badge
    case red
    case orange
    case yellow
    case green
    case mint
    case teal
    case cyan
    case blue
    case indigo
    case purple
    case pink
    case brown
    case gray
    case highestSurface
    case accentContainer
    case accentContainerForeground
    case secondaryAccent
    case secondaryContainer
    case secondaryContainerForeground
    case tertiaryAccent
    case tertiaryContainer
    case tertiaryContainerForeground

    init?(name: some StringProtocol) {
        guard let role = Self.allCases.first(where: { "\($0)" == name }) else { return nil }
        self = role
    }
}

struct ShellTheme: Equatable {
    var light: [NSColor]
    var dark: [NSColor]
    var derivedLight = ShellTheme.derivedRoles
    var derivedDark = ShellTheme.derivedRoles

    static var native: ShellTheme {
        let colors: [NSColor] = [
            .windowBackgroundColor,
            .controlBackgroundColor,
            .underPageBackgroundColor,
            .labelColor,
            .secondaryLabelColor,
            .tertiaryLabelColor,
            .separatorColor,
            .controlAccentColor,
            .alternateSelectedControlTextColor,
            .systemGreen,
            .systemOrange,
            .systemRed,
            .keyboardFocusIndicatorColor,
            .shadowColor,
            NSColor.black.withAlphaComponent(0.4),
            .systemRed,
            .systemRed,
            .systemOrange,
            .systemYellow,
            .systemGreen,
            .systemMint,
            .systemTeal,
            .systemCyan,
            .systemBlue,
            .systemIndigo,
            .systemPurple,
            .systemPink,
            .systemBrown,
            .systemGray
        ] + Array(repeating: NSColor.clear, count: derivedRoles.count)
        return ShellTheme(light: colors, dark: colors)
    }

    init(light: [NSColor], dark: [NSColor]) {
        self.light = light
        self.dark = dark
    }

    init(toml: [String: TOMLNode], name: String, problems: inout [String]) {
        self = .native
        for (appearance, colors, derived) in [
            ("light", \ShellTheme.light, \ShellTheme.derivedLight),
            ("dark", \ShellTheme.dark, \ShellTheme.derivedDark)
        ] {
            guard case let .table(entries)? = toml[appearance] else { continue }
            for (key, value) in entries {
                guard let role = ShellRole(name: key),
                      case let .string(text) = value,
                      let color = NSColor(shellHex: text)
                else {
                    ShellConfig.report(
                        "Theme \(name): [\(appearance)] \(key) must be a role name set to \"#RRGGBB\" or \"#RRGGBBAA\"",
                        &problems
                    )
                    continue
                }
                self[keyPath: colors][role.rawValue] = color
                self[keyPath: derived].remove(role)
            }
        }
    }
}

struct ShellThemeColor: Equatable {
    let light: NSColor
    let dark: NSColor

    init?(_ text: String, theme: ShellTheme) {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let role = ShellRole(name: parts[0]),
              let alpha = parts.count == 2 ? Double(parts[1]) : 1, (0 ... 1).contains(alpha)
        else {
            return nil
        }
        let faded = { (color: NSColor) in color.withAlphaComponent(color.alphaComponent * alpha) }
        light = faded(theme.resolvedColor(role, dark: false))
        dark = faded(theme.resolvedColor(role, dark: true))
    }

    func color(dark isDark: Bool) -> NSColor {
        isDark ? dark : light
    }
}

@MainActor
final class ShellPalette {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
    private var colors: [CGColor] = []
    private(set) var shaderColors = ShellShaderInput.Colors(repeating: .zero)

    init(theme: ShellTheme = .native, appearance: NSAppearance = NSApplication.shared.effectiveAppearance) {
        refresh(theme: theme, appearance: appearance)
    }

    func refresh(theme: ShellTheme, appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let source = dark ? theme.dark : theme.light
        var resolved: [CGColor] = []
        appearance.performAsCurrentDrawingAppearance {
            resolved = source.map(\.cgColor)
        }
        theme.deriveRoles(&resolved, dark: dark)
        colors = resolved
        for (index, color) in resolved.enumerated() where index < shaderColors.count {
            let converted = Self.sRGB.flatMap { color.converted(to: $0, intent: .defaultIntent, options: nil) } ?? color
            let components = converted.components ?? []
            shaderColors[index] = switch components.count {
            case 4: SIMD4(Float(components[0]), Float(components[1]), Float(components[2]), Float(components[3]))
            case 2: SIMD4(Float(components[0]), Float(components[0]), Float(components[0]), Float(components[1]))
            default: .zero
            }
        }
    }

    func color(_ value: Color, default role: ShellRole) -> CGColor {
        color(value) ?? colors[role.rawValue]
    }

    func color(_ value: Color) -> CGColor? {
        guard value.role != 0 else { return value.alpha > 0 ? value.cgColor : nil }
        let index = Int(value.role & 0xFF) - 1
        guard colors.indices.contains(index) else { return nil }
        let base = colors[index]
        return base.copy(alpha: base.alpha * CGFloat(value.role >> 8) / 255) ?? base
    }
}

extension NSColor {
    convenience init?(shellHex text: String) {
        let digits = text.dropFirst()
        guard text.hasPrefix("#"), digits.count == 6 || digits.count == 8,
              let value = UInt32(digits, radix: 16)
        else {
            return nil
        }
        let rgba = digits.count == 6 ? (value << 8) | 0xFF : value
        self.init(
            srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255
        )
    }
}
