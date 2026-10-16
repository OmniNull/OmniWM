// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

@MainActor
final class ShellResources {
    let palette = ShellPalette()
    let shaders = ShellShaderLibrary()
    let images = ShellImageLibrary()
    let motion: MotionPolicy
    let appVolumes: AppVolumeMixer?
    let media: MediaController?
    let calendar: CalendarController?
    let devices = ShellDevices()
    var resourceImages: ShellResourceImages?
    private let iconOverride: @MainActor (String) -> NSImage?
    private let windowIcon: @MainActor (String) -> NSImage?
    private var icons: [String: NSImage?] = [:]
    private var bitmaps: [String: CGImage] = [:]

    init(
        motion: MotionPolicy,
        appVolumes: AppVolumeMixer? = nil,
        media: MediaController? = nil,
        calendar: CalendarController? = nil,
        windowIcon: @escaping @MainActor (String) -> NSImage? = { _ in nil },
        iconOverride: @escaping @MainActor (String) -> NSImage? = { _ in nil }
    ) {
        self.motion = motion
        self.appVolumes = appVolumes
        self.media = media
        self.calendar = calendar
        self.windowIcon = windowIcon
        self.iconOverride = iconOverride
    }

    func setBitmap(_ image: CGImage?, for id: String) {
        bitmaps[id] = image
    }

    func bitmap(_ id: String) -> CGImage? {
        bitmaps[id] ?? media?.bitmap(id) ?? devices.user.bitmap(id)
    }

    func icon(_ source: IconSource, _ reference: String) -> NSImage? {
        switch source {
        case .bundle: icon(for: reference)
        case .window: windowIcon(reference)
        case .pid: pid_t(reference).flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
        }
    }

    func icon(for bundleId: String) -> NSImage? {
        if let override = iconOverride(bundleId) {
            return override
        }
        if let cached = icons[bundleId] {
            return cached
        }
        let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleId] = .some(icon)
        return icon
    }
}
