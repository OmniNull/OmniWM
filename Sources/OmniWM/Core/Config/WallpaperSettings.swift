// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import Observation

struct MonitorWallpaperSettings: MonitorSettingsType {
    let id: UUID
    var monitorName: String
    var monitorDisplayUUID: String?
    var monitorDisplayId: CGDirectDisplayID?
    var folder: String

    init(
        id: UUID = UUID(),
        monitorName: String,
        monitorDisplayUUID: String? = nil,
        monitorDisplayId: CGDirectDisplayID? = nil,
        folder: String
    ) {
        self.id = id
        self.monitorName = monitorName
        self.monitorDisplayUUID = DisplayUUID.canonical(monitorDisplayUUID)
        self.monitorDisplayId = monitorDisplayId
        self.folder = folder
    }

    private enum CodingKeys: String, CodingKey {
        case id, monitorName, monitorDisplayUUID, monitorDisplayId, folder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        monitorName = try container.decode(String.self, forKey: .monitorName)
        monitorDisplayUUID = try DisplayUUID.decode(from: container, forKey: .monitorDisplayUUID)
        monitorDisplayId = try container.decodeIfPresent(CGDirectDisplayID.self, forKey: .monitorDisplayId)
        folder = try container.decode(String.self, forKey: .folder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(monitorName, forKey: .monitorName)
        try DisplayUUID.encode(
            monitorDisplayUUID,
            displayId: monitorDisplayId,
            to: &container,
            uuidKey: .monitorDisplayUUID,
            displayIdKey: .monitorDisplayId
        )
        try container.encode(folder, forKey: .folder)
    }
}

extension SettingsExport {
    struct Wallpaper: Codable, Equatable {
        static let rotationLimit = 1440

        var enabled = false
        var folder = WallpaperLibrary.defaultFolder
        var rotationMinutes = 30
        var placement = WallpaperPlacement.fill
        var displays: [MonitorWallpaperSettings] = []

        static func defaults() -> Self {
            Self()
        }

        static func normalizedRotation(_ minutes: Int) -> Int {
            min(max(minutes, 0), rotationLimit)
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: WallpaperCodingKey.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            let folder = try container.decodeIfPresent(String.self, forKey: .folder)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.folder = folder.flatMap { $0.isEmpty ? nil : $0 } ?? WallpaperLibrary.defaultFolder
            rotationMinutes = Self.normalizedRotation(
                try container.decodeIfPresent(Int.self, forKey: .rotationMinutes) ?? 30
            )
            placement = try container.decodeIfPresent(WallpaperPlacement.self, forKey: .placement) ?? .fill
            displays = try container.decodeIfPresent([MonitorWallpaperSettings].self, forKey: .displays) ?? []
        }
    }
}

private enum WallpaperCodingKey: String, CodingKey {
    case enabled, folder, rotationMinutes, placement, displays
}

extension SettingsExport.Wallpaper {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WallpaperCodingKey.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(folder, forKey: .folder)
        try container.encode(rotationMinutes, forKey: .rotationMinutes)
        try container.encode(placement, forKey: .placement)
        if !displays.isEmpty { try container.encode(displays, forKey: .displays) }
    }
}

extension SettingsStore {
    func wallpaperSettingsDidChange() {
        scheduleSave()
        onWallpaperSettingsChanged?()
    }

    var wallpaperState: WallpaperRuntimeState {
        get { runtimeState.wallpaper }
        set { runtimeState.wallpaper = newValue }
    }
}

extension WallpaperManager {
    convenience init(store: SettingsStore) {
        self.init(
            settings: store.wallpaper,
            loadState: { [weak store] in store?.wallpaperState ?? WallpaperRuntimeState() },
            saveState: { [weak store] in store?.wallpaperState = $0 }
        )
    }
}

@MainActor @Observable
final class WallpaperSettings {
    @ObservationIgnored var onChange: (() -> Void)?

    var enabled = false {
        didSet { if enabled != oldValue { onChange?() } }
    }

    var folder = WallpaperLibrary.defaultFolder {
        didSet { if folder != oldValue { onChange?() } }
    }

    var rotationMinutes = 30 {
        didSet {
            let normalized = SettingsExport.Wallpaper.normalizedRotation(rotationMinutes)
            guard normalized == rotationMinutes else {
                rotationMinutes = normalized
                return
            }
            if rotationMinutes != oldValue { onChange?() }
        }
    }

    var placement = WallpaperPlacement.fill {
        didSet { if placement != oldValue { onChange?() } }
    }

    var displays: [MonitorWallpaperSettings] = [] {
        didSet { if displays != oldValue { onChange?() } }
    }

    func folder(for monitor: Monitor) -> MonitorWallpaperSettings? {
        MonitorSettingsStore.get(for: monitor, in: displays)
    }

    func setFolder(_ folder: String?, for monitor: Monitor) {
        var next = displays
        if let folder {
            let existing = MonitorSettingsStore.get(for: monitor, in: next)
            var entry = existing ?? MonitorWallpaperSettings(monitorName: monitor.name, folder: folder)
            entry.folder = folder
            MonitorSettingsStore.update(entry, for: monitor, in: &next)
        } else {
            MonitorSettingsStore.remove(for: monitor, from: &next)
        }
        displays = next
    }

    func export() -> SettingsExport.Wallpaper {
        var values = SettingsExport.Wallpaper()
        values.enabled = enabled
        values.folder = folder
        values.rotationMinutes = rotationMinutes
        values.placement = placement
        values.displays = displays
        return values
    }

    func apply(_ values: SettingsExport.Wallpaper) {
        enabled = values.enabled
        folder = values.folder
        rotationMinutes = values.rotationMinutes
        placement = values.placement
        displays = values.displays
    }
}
