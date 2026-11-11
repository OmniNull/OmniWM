// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension WallpaperManager {
    func shellValue() -> ShellWallpaper {
        let state = palette?.wallpaperPaletteState ?? WallpaperPaletteState()
        var value = ShellWallpaper()
        value.enabled = settings.enabled
        value.rotation = settings.enabled ? settings.rotationMinutes : 0
        value.next = nextChange.map { $0.timeIntervalSince1970.rounded() }
        value.palette = state.active
        value.scheme = state.scheme.rawValue
        value.problem = problem
        value.swatches = paletteSample.map(ShellWallpaperPalette.swatches(pixels:)) ?? []
        value.displays = entries.map(shellDisplay)
        return value
    }

    private func shellDisplay(_ entry: Entry) -> ShellWallpaper.Display {
        let display = entry.display
        let listed = ShellWallpaper.items(entry.files) { name in
            previews.ready(
                entry.folder.appendingPathComponent(name), width: WallpaperPreviews.gridWidth, display: display,
                placement: placement
            )
        }
        let offset = previews.window(for: display.key)?.offset
            ?? (entry.currentName.flatMap { entry.files.firstIndex(of: $0) }.map {
                $0 / WallpaperPreviews.defaultWindow * WallpaperPreviews.defaultWindow
            } ?? 0)
        return ShellWallpaper.Display(
            id: display.monitorId,
            name: display.name,
            main: display.isMain,
            builtin: display.isBuiltin,
            notch: display.hasNotch,
            width: display.size.width,
            height: display.size.height,
            folder: WallpaperLibrary.abbreviate(entry.folder.path, home: environment.home),
            custom: entry.custom,
            count: entry.files.count,
            current: entry.currentName,
            kind: display.kind.rawValue,
            shown: display.current?.lastPathComponent,
            preview: (display.current ?? display.thumbnail).flatMap {
                previews.ready($0, width: WallpaperPreviews.cardWidth, display: display, placement: placement)
            },
            offset: offset,
            items: listed.items,
            truncated: listed.truncated
        )
    }

    func perform(_ command: ShellWallpaperCommand, chooseFolder: @MainActor (URL?) -> URL?) {
        switch command {
        case let .next(target):
            Task { await next(target) }
        case let .set(display, name):
            Task { await set(name, on: display) }
        case let .page(display, offset, count):
            guard let entry = entry(for: display) else { return }
            previews.setWindow(.init(offset: offset, count: count), for: entry, placement: placement)
            onChange?()
        case let .rotation(minutes):
            setRotation(minutes)
        case let .reveal(display):
            reveal(display)
        case let .chooseFolder(display):
            guard let entry = entry(for: display), let folder = chooseFolder(entry.folder) else { return }
            setFolder(folder, for: display)
        case let .resetFolder(display):
            setFolder(nil, for: display)
        case .scheme,
             .settings:
            break
        }
    }

    static func chooseFolder(startingAt folder: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Use Folder")
        panel.message = String(localized: "Choose the folder of wallpapers for this display.")
        panel.directoryURL = folder
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
final class WallpaperFeedSource: ShellDeviceSource {
    private let manager: WallpaperManager
    private(set) var value: ShellWallpaper?
    var onChange: ((ShellWallpaper?) -> Void)?
    private var listening = false

    init(manager: WallpaperManager) {
        self.manager = manager
    }

    func setListening(_ listening: Bool) {
        guard listening != self.listening else { return }
        self.listening = listening
        manager.previews.demanded = listening
        guard listening else {
            manager.onChange = nil
            value = nil
            return
        }
        manager.onChange = { [weak self] in self?.update() }
        value = manager.shellValue()
        Task { await manager.sampleMainWallpaper() }
    }

    func update() {
        guard listening else { return }
        let next = manager.shellValue()
        guard next != value else { return }
        value = next
        onChange?(value)
    }
}
