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
    var onChange: (@MainActor () -> Void)? {
        didSet { observe(onChange != nil) }
    }

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func displays() -> [WallpaperDisplay] {
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
                hasNotch: screen.safeAreaInsets.top > 0,
                current: NSWorkspace.shared.desktopImageURL(for: screen)
            )
        }
    }

    func setWallpaper(_ url: URL, on display: WallpaperDisplay, placement: WallpaperPlacement) throws {
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

    func reveal(_ folder: URL) {
        NSWorkspace.shared.open(folder)
    }

    private func observe(_ observing: Bool) {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers = []
        guard observing else { return }
        observers = [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification)
        ].map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            })
        }
    }
}
