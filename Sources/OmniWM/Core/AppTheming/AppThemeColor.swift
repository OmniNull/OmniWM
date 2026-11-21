// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct AppThemeHSL: Equatable {
    var hue: Double
    var saturation: Double
    var lightness: Double
}

struct AppThemeColor: Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: Double

    static let black = AppThemeColor(red: 0, green: 0, blue: 0)
    static let white = AppThemeColor(red: 255, green: 255, blue: 255)

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = min(max(alpha, 0), 1)
    }

    init(_ color: ShellRGBA) {
        func channel(_ value: Double) -> UInt8 {
            UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        self.init(red: channel(color.red), green: channel(color.green), blue: channel(color.blue), alpha: color.alpha)
    }

    init?(hex text: String) {
        let digits = text.dropFirst()
        guard text.hasPrefix("#"), digits.count == 6 || digits.count == 8,
              digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16)
        else {
            return nil
        }
        let rgba = digits.count == 6 ? (value << 8) | 0xFF : value
        self.init(
            red: UInt8((rgba >> 24) & 0xFF),
            green: UInt8((rgba >> 16) & 0xFF),
            blue: UInt8((rgba >> 8) & 0xFF),
            alpha: Double(rgba & 0xFF) / 255
        )
    }

    init(hsl: AppThemeHSL, alpha: Double = 1) {
        let saturation = min(max(hsl.saturation, 0), 1)
        let lightness = min(max(hsl.lightness, 0), 1)
        let hue = (hsl.hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let amount = saturation * min(lightness, 1 - lightness)
        func channel(_ offset: Double) -> Double {
            let position = (offset + hue / 30).truncatingRemainder(dividingBy: 12)
            return lightness - amount * max(-1, min(position - 3, 9 - position, 1))
        }
        self.init(ShellRGBA(red: channel(0), green: channel(8), blue: channel(4), alpha: alpha))
    }

    var rgba: ShellRGBA {
        ShellRGBA(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: alpha)
    }

    var opaque: AppThemeColor {
        AppThemeColor(red: red, green: green, blue: blue)
    }

    var hex: String {
        "#" + hexStripped
    }

    var hexStripped: String {
        String(format: "%02x%02x%02x", red, green, blue)
    }

    var alphaText: String {
        let rounded = (alpha * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    var hsl: AppThemeHSL {
        let channels = [Double(red), Double(green), Double(blue)].map { $0 / 255 }
        let (top, bottom) = (channels.max() ?? 0, channels.min() ?? 0)
        let lightness = (top + bottom) / 2
        let chroma = top - bottom
        guard chroma > 0 else { return AppThemeHSL(hue: 0, saturation: 0, lightness: lightness) }
        let saturation = chroma / (1 - abs(2 * lightness - 1))
        let sector = switch top {
        case channels[0]: ((channels[1] - channels[2]) / chroma).truncatingRemainder(dividingBy: 6)
        case channels[1]: (channels[2] - channels[0]) / chroma + 2
        default: (channels[0] - channels[1]) / chroma + 4
        }
        return AppThemeHSL(
            hue: (sector * 60 + 360).truncatingRemainder(dividingBy: 360),
            saturation: saturation,
            lightness: lightness
        )
    }

    func contrast(_ other: AppThemeColor) -> Double {
        rgba.contrast(other.rgba)
    }
}
