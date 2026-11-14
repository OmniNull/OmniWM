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
        value.swatches = paletteSwatches
        value.displays.reserveCapacity(entries.count)
        for entry in entries {
            value.displays.append(shellDisplay(entry))
        }
        return value
    }

    func shellPreviews() -> ShellWallpaperPreviews {
        var value = ShellWallpaperPreviews()
        for entry in entries {
            let display = entry.display
            var shown = ShellWallpaperPreviews.Display()
            shown.card = (display.current ?? display.thumbnail).flatMap {
                previews.ready($0, width: WallpaperPreviews.cardWidth, display: display, placement: placement)
            }
            for name in previews.visible(entry) {
                guard let id = previews.ready(
                    entry.folder.appendingPathComponent(name), width: WallpaperPreviews.gridWidth, display: display,
                    placement: placement
                ) else { continue }
                shown.items[name] = id
            }
            value.displays[display.monitorId] = shown
        }
        return value
    }

    private func shellDisplay(_ entry: Entry) -> ShellWallpaper.Display {
        let display = entry.display
        let window = previews.window(for: entry)
        let listed = ShellWallpaper.items(WallpaperPreviews.visible(entry, in: window))
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
            problem: entry.failure == nil && !entry.files.isEmpty ? nil : folderProblem(entry),
            offset: window.offset,
            page: window.count,
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
            showPage(.init(offset: offset, count: count), for: display)
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
final class WallpaperFeedSource {
    let manager: WallpaperManager
    private(set) var value: ShellWallpaper?
    private(set) var previews: ShellWallpaperPreviews?
    var onChange: (() -> Void)?

    init(manager: WallpaperManager) {
        self.manager = manager
    }

    func listen(data: Bool, previews shown: Bool) {
        guard data != (value != nil) || shown != (previews != nil) else { return }
        let wasListening = value != nil
        let previewsStarted = manager.showPreviews(shown, refreshing: false)
        manager.showSwatches(data, for: .widget)
        guard data || shown else {
            manager.onChange = nil
            value = nil
            previews = nil
            return
        }
        manager.onChange = { [weak self] in self?.update() }
        value = data ? manager.shellValue() : nil
        previews = shown ? manager.shellPreviews() : nil
        let dataStarted = data && !wasListening
        if dataStarted || previewsStarted { manager.refresh(rescan: dataStarted) }
    }

    func update() {
        let next = value.map { _ in manager.shellValue() }
        let shown = previews.map { _ in manager.shellPreviews() }
        guard next != value || shown != previews else { return }
        value = next
        previews = shown
        onChange?()
    }
}
