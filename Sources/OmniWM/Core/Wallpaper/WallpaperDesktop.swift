// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

struct WallpaperDisplay: Equatable, Sendable {
    let displayId: CGDirectDisplayID
    let uuid: String?
    let name: String
    let size: CGSize
    let isMain: Bool
    var isBuiltin = false
    var hasNotch = false
    var current: URL?
    var thumbnail: URL?
    var kind = Kind.file

    enum Kind: String, Sendable {
        case file
        case aerial
        case shuffle
        case other
    }

    var key: String {
        uuid ?? "\(name)#\(displayId)"
    }

    var monitorId: String {
        "display:\(displayId)"
    }

    var monitor: Monitor {
        let frame = CGRect(origin: .zero, size: size)
        return Monitor(
            id: Monitor.ID(displayId: displayId), displayId: displayId, frame: frame, visibleFrame: frame,
            hasNotch: hasNotch, name: name, displayUUID: uuid, isMain: isMain
        )
    }
}

struct WallpaperDesktopFailure: Error, Equatable, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
protocol WallpaperDesktop: AnyObject {
    var onChange: (@MainActor () -> Void)? { get set }
    func displays() -> [WallpaperDisplay]
    func setWallpaper(_ url: URL, on display: WallpaperDisplay, placement: WallpaperPlacement) throws
    func reveal(_ folder: URL)
}

@MainActor
final class LiveWallpaperDesktop: WallpaperDesktop {
    typealias Apply = @MainActor (URL, WallpaperDisplay, WallpaperPlacement) throws -> Void

    var onChange: (@MainActor () -> Void)? {
        didSet { observe(onChange != nil) }
    }

    private let screens: @MainActor () -> [WallpaperDisplay]
    private let store: @MainActor () -> Data?
    private let location: @MainActor (CGDirectDisplayID) -> (display: String, space: String)?
    private let aerials: URL
    private let apply: Apply
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var storeObservation: ShellDirectoryObservation?

    init(
        screens: @escaping @MainActor () -> [WallpaperDisplay] = LiveWallpaperDesktop.connectedScreens,
        store: @escaping @MainActor () -> Data? = {
            try? Data(contentsOf: ShellWallpaperPaletteWriter.store.appendingPathComponent("Index.plist"))
        },
        location: @escaping @MainActor (CGDirectDisplayID) -> (display: String, space: String)? = {
            ShellWallpaperPalette.location(of: $0)
        },
        aerials: URL = ShellWallpaperPalette.aerials,
        apply: @escaping Apply = LiveWallpaperDesktop.setDesktopImage
    ) {
        self.screens = screens
        self.store = store
        self.location = location
        self.aerials = aerials
        self.apply = apply
    }

    func displays() -> [WallpaperDisplay] {
        let index = store()
        return screens().map { screen in
            var display = screen
            let choice = location(screen.displayId).flatMap {
                ShellWallpaperPalette.desktopChoice(store: index, location: $0, aerials: aerials)
            }
            switch choice {
            case let .file(url):
                display.current = url
                display.kind = .file
            case let .aerial(_, thumbnail):
                display.current = nil
                display.thumbnail = thumbnail
                display.kind = .aerial
            case .shuffle:
                display.current = nil
                display.kind = .shuffle
            case .other,
                 nil:
                display.current = nil
                display.kind = .other
            }
            return display
        }
    }

    func storeDidChange() {
        onChange?()
    }

    func setWallpaper(_ url: URL, on display: WallpaperDisplay, placement: WallpaperPlacement) throws {
        try apply(url, display, placement)
    }

    func reveal(_ folder: URL) {
        NSWorkspace.shared.open(folder)
    }

    static func connectedScreens() -> [WallpaperDisplay] {
        let main = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            guard let displayId = screen.displayId else { return nil }
            return WallpaperDisplay(
                displayId: displayId,
                uuid: SkyLight.displayUUID(for: displayId),
                name: screen.localizedName,
                size: screen.frame.size,
                isMain: displayId == main,
                isBuiltin: CGDisplayIsBuiltin(displayId) != 0,
                hasNotch: screen.safeAreaInsets.top > 0
            )
        }
    }

    static func setDesktopImage(_ url: URL, on display: WallpaperDisplay, placement: WallpaperPlacement) throws {
        let screens = NSScreen.screens.filter { screen in
            guard let displayId = screen.displayId else { return false }
            if let uuid = display.uuid {
                return SkyLight.displayUUID(for: displayId) == uuid
            }
            return displayId == display.displayId
        }
        guard screens.count == 1, let screen = screens.first else {
            throw WallpaperDesktopFailure(message: String(
                localized: "\(display.name) is no longer connected"
            ))
        }
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: placement == .fill
        ])
    }

    private func observe(_ observing: Bool) {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers = []
        storeObservation?.cancel()
        storeObservation = nil
        guard observing else { return }
        observers = [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification)
        ].map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }
        let observation = ShellDirectoryObservation { [weak self] in self?.storeDidChange() }
        let storeFolder = ShellWallpaperPaletteWriter.store
        observation.sync(
            paths: [storeFolder, storeFolder.appendingPathComponent("Index.plist")], recursivePaths: [storeFolder]
        )
        storeObservation = observation
    }
}
