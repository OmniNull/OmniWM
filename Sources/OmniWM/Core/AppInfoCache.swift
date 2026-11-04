// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

@MainActor
final class AppInfoCache {
    struct AppInfo {
        let name: String?
        let bundleId: String?
        let icon: NSImage?
        let activationPolicy: NSApplication.ActivationPolicy
    }

    struct WindowPresentation {
        let name: String?
        let title: String?
        let icon: NSImage?
    }

    private var cache: [pid_t: AppInfo] = [:]
    private var insertionOrder: [pid_t] = []
    private let maxEntries = 128
    private let windowIcons = NSCache<NSString, NSImage>()

    init() {
        windowIcons.countLimit = maxEntries
    }

    func presentation(
        for entry: WindowState,
        title: @autoclosure () -> String? = nil,
        cachedProcessOnly: Bool = false
    ) -> WindowPresentation {
        if let hosted = entry.target.hostedMetadata {
            let key = hosted.icon as NSString
            let icon: NSImage?
            if let cached = windowIcons.object(forKey: key) {
                icon = cached
            } else {
                icon = NSImage(systemSymbolName: hosted.icon, accessibilityDescription: nil)
                if let icon { windowIcons.setObject(icon, forKey: key) }
            }
            return WindowPresentation(name: hosted.title, title: hosted.title, icon: icon)
        }
        let app = cachedProcessOnly ? cache[entry.pid] : info(for: entry.pid)
        return WindowPresentation(name: app?.name, title: title(), icon: app?.icon)
    }

    func evict(pid: pid_t) {
        guard cache.removeValue(forKey: pid) != nil else { return }
        insertionOrder.removeAll { $0 == pid }
    }

    func info(
        for pid: pid_t,
        load: @MainActor (pid_t) -> AppInfo? = { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return AppInfo(
                name: app.localizedName,
                bundleId: app.bundleIdentifier,
                icon: app.icon,
                activationPolicy: app.activationPolicy
            )
        }
    ) -> AppInfo? {
        if let cached = cache[pid] { return cached }
        guard let info = load(pid) else { return nil }
        if cache.count >= maxEntries, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cache[pid] = info
        insertionOrder.append(pid)
        return info
    }

    func name(for pid: pid_t) -> String? {
        info(for: pid)?.name
    }

    func bundleId(for pid: pid_t) -> String? {
        info(for: pid)?.bundleId
    }

    func hasCachedInfo(for pid: pid_t) -> Bool {
        cache[pid] != nil
    }
}
