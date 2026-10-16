// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMMaterialColor
import TOML
import XCTest

final class MaterialColorTests: XCTestCase {
    private static let tonalSpotDark: [omni_material_role: UInt32] = [
        OMNI_MATERIAL_BACKGROUND: 0x191114, OMNI_MATERIAL_ON_BACKGROUND: 0xEFDFE2, OMNI_MATERIAL_SURFACE: 0x191114,
        OMNI_MATERIAL_SURFACE_DIM: 0x191114, OMNI_MATERIAL_SURFACE_BRIGHT: 0x403739,
        OMNI_MATERIAL_SURFACE_CONTAINER_LOWEST: 0x130C0E, OMNI_MATERIAL_SURFACE_CONTAINER_LOW: 0x22191C,
        OMNI_MATERIAL_SURFACE_CONTAINER: 0x261D20, OMNI_MATERIAL_SURFACE_CONTAINER_HIGH: 0x31282A,
        OMNI_MATERIAL_SURFACE_CONTAINER_HIGHEST: 0x3C3235, OMNI_MATERIAL_ON_SURFACE: 0xEFDFE2,
        OMNI_MATERIAL_SURFACE_VARIANT: 0x514347, OMNI_MATERIAL_ON_SURFACE_VARIANT: 0xD5C2C6,
        OMNI_MATERIAL_INVERSE_SURFACE: 0xEFDFE2, OMNI_MATERIAL_INVERSE_ON_SURFACE: 0x372E30,
        OMNI_MATERIAL_OUTLINE: 0x9E8C91, OMNI_MATERIAL_OUTLINE_VARIANT: 0x514347, OMNI_MATERIAL_SHADOW: 0x000000,
        OMNI_MATERIAL_SCRIM: 0x000000, OMNI_MATERIAL_SURFACE_TINT: 0xFFB0CA, OMNI_MATERIAL_PRIMARY: 0xFFB0CA,
        OMNI_MATERIAL_ON_PRIMARY: 0x541D34, OMNI_MATERIAL_PRIMARY_CONTAINER: 0x6F334A,
        OMNI_MATERIAL_ON_PRIMARY_CONTAINER: 0xFFD9E3, OMNI_MATERIAL_INVERSE_PRIMARY: 0x8B4A62,
        OMNI_MATERIAL_SECONDARY: 0xE2BDC7, OMNI_MATERIAL_ON_SECONDARY: 0x422932,
        OMNI_MATERIAL_SECONDARY_CONTAINER: 0x5A3F48, OMNI_MATERIAL_ON_SECONDARY_CONTAINER: 0xFFD9E3,
        OMNI_MATERIAL_TERTIARY: 0xF0BC95, OMNI_MATERIAL_ON_TERTIARY: 0x48290C,
        OMNI_MATERIAL_TERTIARY_CONTAINER: 0x623F21,
        OMNI_MATERIAL_ON_TERTIARY_CONTAINER: 0xFFDCC3, OMNI_MATERIAL_ERROR: 0xFFB4AB, OMNI_MATERIAL_ON_ERROR: 0x690005,
        OMNI_MATERIAL_ERROR_CONTAINER: 0x93000A, OMNI_MATERIAL_ON_ERROR_CONTAINER: 0xFFDAD6
    ]

    private static let variants: [omni_material_variant] = [
        OMNI_MATERIAL_TONAL_SPOT, OMNI_MATERIAL_CONTENT, OMNI_MATERIAL_VIBRANT, OMNI_MATERIAL_EXPRESSIVE,
        OMNI_MATERIAL_FIDELITY, OMNI_MATERIAL_FRUIT_SALAD, OMNI_MATERIAL_RAINBOW, OMNI_MATERIAL_NEUTRAL,
        OMNI_MATERIAL_MONOCHROME
    ]

    private func scheme(_ seed: UInt32, _ variant: omni_material_variant, dark: Bool) -> [UInt32] {
        var roles = [UInt32](repeating: 0, count: Int(OMNI_MATERIAL_ROLE_COUNT.rawValue))
        roles.withUnsafeMutableBufferPointer { omni_material_scheme(seed, variant, dark, 0, $0.baseAddress) }
        return roles
    }

    private func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        func luminance(_ argb: UInt32) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let value = Double((argb >> UInt32(shift)) & 0xFF) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        let (light, dark) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (light + 0.05) / (dark + 0.05)
    }

    func testTonalSpotReproducesCaelestiasDarkScheme() {
        let roles = scheme(0xA8627B, OMNI_MATERIAL_TONAL_SPOT, dark: true)
        for (role, expected) in Self.tonalSpotDark {
            XCTAssertEqual(roles[Int(role.rawValue)] & 0xFFFFFF, expected, "role \(role.rawValue)")
            XCTAssertEqual(roles[Int(role.rawValue)] >> 24, 0xFF)
        }
        XCTAssertEqual(Self.tonalSpotDark.count, Int(OMNI_MATERIAL_ROLE_COUNT.rawValue))
        let light = scheme(0xA8627B, OMNI_MATERIAL_TONAL_SPOT, dark: false)
        XCTAssertEqual(light[Int(OMNI_MATERIAL_PRIMARY.rawValue)] & 0xFFFFFF, 0x8B4A62)
        XCTAssertEqual(light[Int(OMNI_MATERIAL_BACKGROUND.rawValue)] & 0xFFFFFF, 0xFFF8F8)
    }

    func testEverySchemeKeepsItsTextReadable() {
        let pairs: [(omni_material_role, omni_material_role)] = [
            (OMNI_MATERIAL_ON_SURFACE, OMNI_MATERIAL_SURFACE),
            (OMNI_MATERIAL_ON_PRIMARY, OMNI_MATERIAL_PRIMARY),
            (OMNI_MATERIAL_ON_PRIMARY_CONTAINER, OMNI_MATERIAL_PRIMARY_CONTAINER),
            (OMNI_MATERIAL_ON_SECONDARY_CONTAINER, OMNI_MATERIAL_SECONDARY_CONTAINER),
            (OMNI_MATERIAL_ON_TERTIARY_CONTAINER, OMNI_MATERIAL_TERTIARY_CONTAINER)
        ]
        for seed: UInt32 in [0xA8627B, 0x1E88E5, 0x4CAF50, 0x808080] {
            for variant in Self.variants {
                for dark in [false, true] {
                    let roles = scheme(seed, variant, dark: dark)
                    for (text, fill) in pairs {
                        XCTAssertGreaterThanOrEqual(
                            contrast(roles[Int(text.rawValue)], roles[Int(fill.rawValue)]),
                            4.5,
                            "seed \(String(seed, radix: 16)) variant \(variant.rawValue) dark \(dark) role \(text.rawValue)"
                        )
                    }
                }
            }
        }
        let spot = scheme(0x1E88E5, OMNI_MATERIAL_TONAL_SPOT, dark: true)
        let content = scheme(0x1E88E5, OMNI_MATERIAL_CONTENT, dark: true)
        XCTAssertNotEqual(
            spot[Int(OMNI_MATERIAL_PRIMARY_CONTAINER.rawValue)],
            content[Int(OMNI_MATERIAL_PRIMARY_CONTAINER.rawValue)]
        )
    }

    func testTheSeedComesFromTheColorfulOpaquePixels() {
        let fallback: UInt32 = 0xFF4285F4
        let blue: UInt32 = 0xFF1E88E5
        let mixed = [UInt32](repeating: blue, count: 600) + [UInt32](repeating: 0xFF777777, count: 400)
        let seed = omni_material_seed(mixed, mixed.count, fallback)
        for shift: UInt32 in [16, 8, 0] {
            XCTAssertEqual(Double((seed >> shift) & 0xFF), Double((blue >> shift) & 0xFF), accuracy: 3)
        }
        let grey = [UInt32](repeating: 0xFF777777, count: 1000)
        XCTAssertEqual(omni_material_seed(grey, grey.count, fallback), fallback)
        let clear = [UInt32](repeating: 0x001E88E5, count: 1000)
        XCTAssertEqual(omni_material_seed(clear, clear.count, fallback), fallback)
        XCTAssertEqual(omni_material_seed(nil, 0, fallback), fallback)
    }

    func testCelestialIsCaelestiasDarkSchemeAndItsGeneratedLightOne() throws {
        let url = try XCTUnwrap(ShellDefaults.bundledFile("themes/celestial.toml"))
        let toml = try TOMLDecoder().decode([String: TOMLNode].self, from: Data(contentsOf: url))
        let caelestiaOnly: [ShellRole: UInt32] = [.tertiaryContainer: 0xB58763, .tertiaryContainerForeground: 0x000000]
        for dark in [false, true] {
            guard case let .table(entries)? = toml[dark ? "dark" : "light"] else { return XCTFail("no palette") }
            let generated = ShellMaterialPalette.colors(seed: 0xA8627B, dark: dark)
            XCTAssertEqual(generated.count, ShellMaterialPalette.roles.count)
            for (role, color) in generated {
                guard case let .string(text)? = entries["\(role)"],
                      let value = UInt32(text.dropFirst(), radix: 16)
                else {
                    return XCTFail("celestial \(dark) \(role) is missing")
                }
                XCTAssertEqual(value, dark ? caelestiaOnly[role] ?? color : color, "celestial dark \(dark) \(role)")
            }
        }
    }
}
