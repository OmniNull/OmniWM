// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM

@MainActor
final class FakeWallpaperDesktop: WallpaperDesktop {
    var onChange: (@MainActor () -> Void)?
    var screens: [WallpaperDisplay]
    var events: [String] = []
    var revealed: [URL] = []

    init(_ screens: [WallpaperDisplay]) {
        self.screens = screens
    }

    func displays() -> [WallpaperDisplay] {
        screens
    }

    func setWallpaper(_ url: URL, on display: WallpaperDisplay, placement: WallpaperPlacement) throws {
        let matches = screens.indices.filter { index in
            if let uuid = display.uuid { return screens[index].uuid == uuid }
            return screens[index].displayId == display.displayId
        }
        guard matches.count == 1, let index = matches.first else {
            events.append("missing \(display.name)")
            throw WallpaperDesktopFailure(message: "\(display.name) is no longer connected")
        }
        screens[index].current = url
        events.append("set \(screens[index].key) \(url.lastPathComponent)")
    }

    func reveal(_ folder: URL) {
        revealed.append(folder)
    }

    func plug(_ display: WallpaperDisplay) {
        screens.append(display)
        onChange?()
    }

    func unplug(_ key: String) {
        screens.removeAll { $0.key == key }
        onChange?()
    }
}

@MainActor
final class FakeWallpaperPalette: WallpaperPaletteTarget {
    var wallpaperPaletteState = WallpaperPaletteState(active: true, scheme: .tonalSpot)
    weak var desktop: FakeWallpaperDesktop?
    var published: [[UInt32]] = []

    func publishWallpaperPalette(_ pixels: [UInt32]) -> Bool {
        published.append(pixels)
        desktop?.events.append("palette \(pixels.first ?? 0)")
        return true
    }
}

@MainActor
final class ManualWallpaperClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var timers: [(due: Date, action: @MainActor () -> Void, cancelled: Bool)] = []

    func schedule(_ due: Date, _ action: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let index = timers.count
        timers.append((due, action, false))
        return { [weak self] in self?.timers[index].cancelled = true }
    }

    var pending: [Date] {
        timers.filter { !$0.cancelled }.map(\.due)
    }

    func advance(to date: Date) {
        now = date
        for index in timers.indices where !timers[index].cancelled && timers[index].due <= date {
            timers[index].cancelled = true
            timers[index].action()
        }
    }
}

enum WallpaperFixtures {
    static let macBook = WallpaperDisplay(
        displayId: 1, uuid: "11111111-1111-1111-1111-111111111111", name: "Built-in Retina Display",
        size: CGSize(width: 1512, height: 982), isMain: true, isBuiltin: true, hasNotch: true
    )
    static let studio = WallpaperDisplay(
        displayId: 2, uuid: "22222222-2222-2222-2222-222222222222", name: "Studio Display",
        size: CGSize(width: 2560, height: 1440), isMain: true
    )
    static let twinLeft = WallpaperDisplay(
        displayId: 3, uuid: "33333333-3333-3333-3333-333333333333", name: "DELL U2723QE",
        size: CGSize(width: 2560, height: 1440), isMain: true
    )
    static let twinRight = WallpaperDisplay(
        displayId: 4, uuid: "44444444-4444-4444-4444-444444444444", name: "DELL U2723QE",
        size: CGSize(width: 2560, height: 1440), isMain: false
    )

    static func secondary(_ display: WallpaperDisplay) -> WallpaperDisplay {
        WallpaperDisplay(
            displayId: display.displayId, uuid: display.uuid, name: display.name, size: display.size, isMain: false,
            isBuiltin: display.isBuiltin, hasNotch: display.hasNotch, current: display.current
        )
    }

    static func makeFolder(_ root: URL, _ name: String, files: [String]) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data(file.utf8).write(to: folder.appendingPathComponent(file))
        }
        return folder
    }

    static func writeImage(_ url: URL, width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat)) throws {
        let context = try XCTUnwrapContext(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private static func XCTUnwrapContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        return context
    }
}
