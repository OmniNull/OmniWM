// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellWallpaperEvents {
    static let shared = ShellWallpaperEvents()

    private let store: URL
    private var handlers: [ObjectIdentifier: @MainActor () -> Void] = [:]
    private var observation: ShellDirectoryObservation?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(store: URL = ShellWallpaperPaletteWriter.store) {
        self.store = store
    }

    var subscribers: Int {
        handlers.count
    }

    var isObserving: Bool {
        observation != nil
    }

    func subscribe(_ owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        handlers[ObjectIdentifier(owner)] = handler
        guard observation == nil else { return }
        observation = ShellDirectoryObservation { [weak self] in
            self?.watchStore()
            self?.changed()
        }
        watchStore()
        observers = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        ].map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            })
        }
    }

    func unsubscribe(_ owner: AnyObject) {
        guard handlers.removeValue(forKey: ObjectIdentifier(owner)) != nil, handlers.isEmpty else { return }
        observation?.cancel()
        observation = nil
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers = []
    }

    func changed() {
        for handler in handlers.values {
            handler()
        }
    }

    private func watchStore() {
        observation?.sync(paths: [store, store.appendingPathComponent("Index.plist")], recursivePaths: [store])
    }
}
