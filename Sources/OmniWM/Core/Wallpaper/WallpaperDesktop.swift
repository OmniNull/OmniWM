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

    func showing(_ shown: WallpaperShown) -> WallpaperDisplay {
        var display = self
        display.current = shown.current
        display.thumbnail = shown.thumbnail
        display.kind = shown.kind
        return display
    }
}

struct WallpaperShown: Equatable, Sendable {
    var current: URL?
    var thumbnail: URL?
    var kind = WallpaperDisplay.Kind.other

    init(current: URL? = nil, thumbnail: URL? = nil, kind: WallpaperDisplay.Kind = .other) {
        self.current = current
        self.thumbnail = thumbnail
        self.kind = kind
    }

    init(_ choice: ShellWallpaperPalette.DesktopChoice?) {
        switch choice {
        case let .file(url): self.init(current: url, kind: .file)
        case let .aerial(_, thumbnail): self.init(thumbnail: thumbnail, kind: .aerial)
        case .shuffle: self.init(kind: .shuffle)
        case .other,
             nil: self.init()
        }
    }
}

struct WallpaperDesktopFailure: Error, Equatable, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

typealias WallpaperShownLookup = @Sendable () -> Result<[WallpaperShown], WallpaperDesktopFailure>

@MainActor
protocol WallpaperDesktop: AnyObject {
    var onChange: (@MainActor () -> Void)? { get set }
    func lookup() -> (screens: [WallpaperDisplay], shown: WallpaperShownLookup)
    func setWallpaper(_ url: URL, on display: WallpaperDisplay, placement: WallpaperPlacement) throws
    func reveal(_ folder: URL)
}

@MainActor
final class LiveWallpaperDesktop: WallpaperDesktop {
    typealias Apply = @MainActor (URL, WallpaperDisplay, WallpaperPlacement) throws -> Void
    typealias Store = @Sendable () throws -> Data?
    typealias Location = (display: String, space: String)

    var onChange: (@MainActor () -> Void)? {
        didSet { observe(onChange != nil) }
    }

    private let screens: @MainActor () -> [WallpaperDisplay]
    private let store: Store
    private let location: @MainActor (CGDirectDisplayID) -> Location?
    private let aerials: URL
    private let apply: Apply
    private let events: ShellWallpaperEvents

    init(
        screens: @escaping @MainActor () -> [WallpaperDisplay] = LiveWallpaperDesktop.connectedScreens,
        store: @escaping Store = LiveWallpaperDesktop.readStore,
        location: @escaping @MainActor (CGDirectDisplayID) -> Location? = { ShellWallpaperPalette.location(of: $0) },
        aerials: URL = ShellWallpaperPalette.aerials,
        apply: @escaping Apply = LiveWallpaperDesktop.setDesktopImage,
        events: ShellWallpaperEvents = .shared
    ) {
        self.screens = screens
        self.store = store
        self.location = location
        self.aerials = aerials
        self.apply = apply
        self.events = events
    }

    isolated deinit {
        events.unsubscribe(self)
    }

    func lookup() -> (screens: [WallpaperDisplay], shown: WallpaperShownLookup) {
        let screens = screens()
        var locations: [Location?] = []
        locations.reserveCapacity(screens.count)
        for screen in screens {
            locations.append(location(screen.displayId))
        }
        let (store, aerials, located) = (store, aerials, locations)
        return (screens, { Self.shown(at: located, store: store, aerials: aerials) })
    }

    nonisolated static func shown(
        at locations: [Location?], store: Store, aerials: URL
    ) -> Result<[WallpaperShown], WallpaperDesktopFailure> {
        let index: [String: Any]?
        do {
            index = try store().map(ShellWallpaperPalette.storeIndex(from:))
        } catch {
            return .failure(WallpaperDesktopFailure(message: String(
                localized: "macOS’s wallpaper settings can’t be read: \(error.localizedDescription)"
            )))
        }
        var shown: [WallpaperShown] = []
        shown.reserveCapacity(locations.count)
        for location in locations {
            guard let location, let index else {
                shown.append(WallpaperShown())
                continue
            }
            shown.append(WallpaperShown(ShellWallpaperPalette.desktopChoice(
                in: index, location: location, aerials: aerials
            )))
        }
        return .success(shown)
    }

    nonisolated static func readStore() throws -> Data? {
        do {
            return try Data(contentsOf: ShellWallpaperPaletteWriter.store.appendingPathComponent("Index.plist"))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
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
        guard observing else {
            events.unsubscribe(self)
            return
        }
        events.subscribe(self) { [weak self] in self?.onChange?() }
    }
}

extension ShellWallpaperPalette {
    static func storeIndex(from data: Data) throws -> [String: Any] {
        guard let index = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return index
    }

    static func desktopChoice(
        in index: [String: Any],
        location: (display: String, space: String),
        aerials: URL
    ) -> DesktopChoice? {
        guard let content = desktopContent(in: index, location: location) else { return nil }
        if let path = stillImagePath(of: content) {
            return .file(URL(fileURLWithPath: path))
        }
        guard let choices = content["Choices"] as? [[String: Any]], choices.count == 1 else { return .other }
        if content["Shuffle"] as? String != "$null" {
            return .shuffle
        }
        guard choices[0]["Provider"] as? String == aerialProvider,
              let data = choices[0]["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any],
              let asset = configuration["assetID"] as? String,
              !asset.isEmpty, !asset.contains("/")
        else { return .other }
        let thumbnail = aerials.appendingPathComponent("thumbnails/\(asset).png").standardizedFileURL
        return .aerial(
            asset: asset,
            thumbnail: FileManager.default.fileExists(atPath: thumbnail.path) ? thumbnail : nil
        )
    }
}
