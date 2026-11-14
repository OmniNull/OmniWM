// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import TOML
import XCTest

extension ShellBundledWidgetTests {
    static func wallpaperGradient(_ width: Int, _ height: Int, _ colors: [CGColor]) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors as CFArray,
            locations: nil
        )!
        context.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: width, y: height), options: [
                .drawsBeforeStartLocation,
                .drawsAfterEndLocation
            ]
        )
        context.setFillColor(CGColor(gray: 1, alpha: 0.18))
        context.fillEllipse(in: CGRect(x: width / 2, y: height / 3, width: height / 2, height: height / 2))
        return context.makeImage()!
    }

    static let wallpaperPalettes: [[CGColor]] = [
        [
            CGColor(srgbRed: 0.98, green: 0.62, blue: 0.27, alpha: 1),
            CGColor(srgbRed: 0.42, green: 0.16, blue: 0.36, alpha: 1)
        ],
        [
            CGColor(srgbRed: 0.11, green: 0.33, blue: 0.55, alpha: 1),
            CGColor(srgbRed: 0.55, green: 0.85, blue: 0.86, alpha: 1)
        ],
        [
            CGColor(srgbRed: 0.18, green: 0.42, blue: 0.24, alpha: 1),
            CGColor(srgbRed: 0.93, green: 0.88, blue: 0.62, alpha: 1)
        ],
        [
            CGColor(srgbRed: 0.35, green: 0.2, blue: 0.62, alpha: 1),
            CGColor(srgbRed: 0.95, green: 0.45, blue: 0.62, alpha: 1)
        ]
    ]

    static let wallpaperNames = [
        "Amber Dunes.jpg",
        "Harbour Fog.heic",
        "Moss Hollow.jpg",
        "Violet Hour.png",
        "Salt Flats.jpg",
        "Night Ferry.jpg",
        "Cedar Ridge.webp",
        "Low Tide.jpg",
        "Glass Lake.jpg"
    ]

    static let wallpaperScreens: [(id: String, name: String, size: CGSize, current: Int)] = [
        ("display:1", "MPG491CX OLED", CGSize(width: 5120, height: 1440), 0),
        ("display:2", "Built-in Retina Display", CGSize(width: 1512, height: 982), 3)
    ]

    func wallpaperPreviews(resources: ShellResources?) -> ShellWallpaperPreviews {
        var previews = ShellWallpaperPreviews()
        for screen in Self.wallpaperScreens {
            var shown = ShellWallpaperPreviews.Display()
            for (index, file) in Self.wallpaperNames.enumerated() {
                let key = "wallpaper/\(screen.id)-\(index)"
                resources?.setBitmap(
                    Self.wallpaperGradient(
                        Int(screen.size.width / 8), Int(screen.size.height / 8),
                        Self.wallpaperPalettes[index % Self.wallpaperPalettes.count]
                    ),
                    for: key
                )
                shown.items[file] = key
                if index == screen.current { shown.card = key }
            }
            previews.displays[screen.id] = shown
        }
        return previews
    }

    func wallpaperSample(enabled: Bool = true) -> ShellWallpaper {
        var value = ShellWallpaper()
        value.enabled = enabled
        value.rotation = SettingsExport.Wallpaper.rotationPresets[1]
        value.next = 1_800_003_720
        value.palette = true
        value.scheme = "tonalSpot"
        let sample = Self.wallpaperGradient(64, 36, Self.wallpaperPalettes[0])
        value.swatches = ShellWallpaperPalette.swatches(pixels: ShellWallpaperPalette.pixels(of: sample))
        let names = Self.wallpaperNames
        value.displays = Self.wallpaperScreens.enumerated().map { index, screen in
            let main = index == 0
            return ShellWallpaper.Display(
                id: screen.id, name: screen.name, main: main, builtin: !main, notch: !main,
                width: screen.size.width, height: screen.size.height,
                folder: main ? "~/Pictures/Wallpapers/ultrawide" : "~/Pictures/Wallpapers", custom: main,
                count: names.count, current: names[screen.current], offset: 0, page: WallpaperPreviews.defaultWindow,
                items: Array(names.prefix(WallpaperPreviews.defaultWindow)), truncated: false
            )
        }
        return value
    }

    func testWallpaperWidgetIsAPlainGlyphAndItsPopoutFollowsTheApprovedLayout() throws {
        var data = try fullData()
        data.append((ShellDataKey.wallpaper.rawValue, value { wallpaperSample().write(into: &$0) }))
        data.append((
            ShellDataKey.wallpaperPreviews.rawValue,
            value { wallpaperPreviews(resources: nil).write(into: &$0) }
        ))
        data.append(("appearance", value { ShellAppearance(dark: true).write(into: &$0) }))
        try renderStyle("default", widget: "wallpaper", data: data, inspect: { view, nodes, text in
            let strings = nodes.map { text.string($0.text) }
            if view == OMNI_VIEW_BAR {
                XCTAssertTrue(strings.contains("photo.on.rectangle"))
                XCTAssertFalse(strings.contains { $0.hasPrefix("wallpaper/") }, "no wallpaper previews in the bar")
                XCTAssertTrue(nodes.contains { text.string($0.help) == "Wallpaper" })
                return
            }
            for caption in [
                "MPG491CX OLED",
                "Built-in Retina Display",
                "Next both",
                "Now",
                "Show all",
                "Open folder",
                "Change folder",
                "Tonal Spot",
                "Fruit Salad",
                "Monochrome",
                "Amber Dunes.jpg"
            ] {
                XCTAssertTrue(strings.contains(caption), "missing \(caption) in \(strings)")
            }
            XCTAssertTrue(strings.contains {
                $0.hasPrefix("Every \(SettingsExport.Wallpaper.rotationPresets[1]) min")
            })
            XCTAssertTrue(strings.contains("wallpaper/display:1-0"), "cards show the current wallpaper")
            XCTAssertTrue(nodes.contains { text.string($0.help) == "Show the next wallpaper on every display" })
        })
    }

    func testWallpaperPopoutExplainsWhenTheFeatureIsOffOrUnavailable() throws {
        let base = try fullData()
        for sample in [wallpaperSample(enabled: false), nil] {
            var data = base
            if let sample { data.append((ShellDataKey.wallpaper.rawValue, value { sample.write(into: &$0) })) }
            try renderStyle("default", widget: "wallpaper", data: data, inspect: { view, nodes, text in
                guard view == OMNI_VIEW_POPOUT else { return }
                let strings = nodes.map { text.string($0.text) }
                XCTAssertTrue(strings.contains("Wallpaper Settings…"), "\(strings)")
            })
        }
    }

    func testWallpaperPopoutRendersInBothAppearances() throws {
        let directory = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"]
        let defaults = try XCTUnwrap(ShellDefaults.bundled)
        let sample = Self.wallpaperGradient(64, 36, Self.wallpaperPalettes[0])
        let themeText = ShellWallpaperPalette.theme(
            pixels: ShellWallpaperPalette.pixels(of: sample),
            scheme: .tonalSpot
        )
        var problems: [String] = []
        let theme = ShellTheme(
            toml: try TOMLDecoder().decode([String: TOMLNode].self, from: Data(themeText.utf8)),
            name: ShellWallpaperPalette.themeName,
            problems: &problems
        )
        for dark in [false, true] {
            let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
            resources.palette.refresh(
                theme: theme,
                appearance: try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            )
            var data = try fullData { $0.style.height = 32 }
            data.append((ShellDataKey.wallpaper.rawValue, value { wallpaperSample().write(into: &$0) }))
            data.append((
                ShellDataKey.wallpaperPreviews.rawValue,
                value { wallpaperPreviews(resources: resources).write(into: &$0) }
            ))
            data.append(("appearance", value { ShellAppearance(dark: dark).write(into: &$0) }))
            try renderStyle("default", widget: "wallpaper", data: data, capture: { view, bytes, text in
                let surface = ShellWidgetSurface(scale: 2, resources: resources, directories: [defaults])
                XCTAssertTrue(surface.apply(bytes, text: text))
                guard let directory else { return }
                let kind = view == OMNI_VIEW_BAR ? "bar" : "popout"
                try Self.writeSnapshot(
                    surface, name: "wallpaper-\(kind)-\(dark ? "dark" : "light")", dark: dark, directory: directory,
                    background: dark ? CGColor(srgbRed: 0.1, green: 0.08, blue: 0.07, alpha: 1)
                        : CGColor(srgbRed: 0.94, green: 0.91, blue: 0.87, alpha: 1)
                )
            })
        }
    }

    func testThePickerShowsThePageTheManagerListsDeepInALargeFolder() throws {
        var sample = wallpaperSample()
        let total = 2 * WallpaperPreviews.pageLimit + 1
        let offset = total - total % WallpaperPreviews.defaultWindow
        let names = (offset ..< total).map { String(format: "w%04d.jpg", $0) }
        sample.displays[0].count = total
        sample.displays[0].offset = offset
        sample.displays[0].page = WallpaperPreviews.defaultWindow
        sample.displays[0].current = nil
        sample.displays[0].items = names
        var data = try fullData()
        data.append((ShellDataKey.wallpaper.rawValue, value { sample.write(into: &$0) }))
        data.append(("appearance", value { ShellAppearance(dark: true).write(into: &$0) }))
        try renderStyle("default", widget: "wallpaper", data: data, inspect: { view, nodes, text in
            guard view == OMNI_VIEW_POPOUT else { return }
            let strings = nodes.map { text.string($0.text) }
            for name in names {
                XCTAssertTrue(strings.contains(name), "missing \(name) in \(strings)")
            }
        })
    }

    func testShowAllFollowsThePageTheManagerKeepsSoReopeningThePopoutAgrees() throws {
        for (page, caption, other) in [
            (WallpaperPreviews.defaultWindow, "Show all", "Show fewer"),
            (WallpaperPreviews.pageLimit, "Show fewer", "Show all")
        ] {
            var sample = wallpaperSample()
            sample.displays[0].page = page
            var data = try fullData()
            data.append((ShellDataKey.wallpaper.rawValue, value { sample.write(into: &$0) }))
            try renderStyle("default", widget: "wallpaper", data: data, inspect: { view, nodes, text in
                guard view == OMNI_VIEW_POPOUT else { return }
                let strings = nodes.map { text.string($0.text) }
                XCTAssertTrue(strings.contains(caption), "page \(page): \(strings)")
                XCTAssertFalse(strings.contains(other), "page \(page): \(strings)")
            })
        }
    }

    func testAFolderProblemIsShownInsteadOfAnEmptyPicker() throws {
        var sample = wallpaperSample()
        let problem = "~/Pictures/Wallpapers can’t be read: Permission denied"
        sample.displays[0].count = 0
        sample.displays[0].items = []
        sample.displays[0].problem = problem
        var data = try fullData()
        data.append((ShellDataKey.wallpaper.rawValue, value { sample.write(into: &$0) }))
        try renderStyle("default", widget: "wallpaper", data: data, inspect: { view, nodes, text in
            guard view == OMNI_VIEW_POPOUT else { return }
            XCTAssertTrue(nodes.map { text.string($0.text) }.contains(problem))
        })
    }
}
