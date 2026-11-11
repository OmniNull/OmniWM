// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation

@MainActor
final class CommandPaletteMenuSession {
    enum Publication {
        case loading
        case loaded([MenuItemModel])
    }

    private let environment: CommandPaletteEnvironment
    private var sessionMenuCache: [pid_t: [MenuItemModel]] = [:]
    private var hasLoadedMenuItems = false
    private var menuLoadGeneration = 0

    init(environment: CommandPaletteEnvironment) {
        self.environment = environment
    }

    func resetCache() {
        hasLoadedMenuItems = false
        sessionMenuCache.removeAll()
    }

    func invalidate() {
        menuLoadGeneration &+= 1
    }

    func load(
        target: CommandPaletteFocusTarget?,
        canStart: @escaping () -> Bool,
        canPublish: @escaping () -> Bool,
        publish: @escaping (Publication) -> Void
    ) {
        guard !hasLoadedMenuItems, let target else { return }
        let pid = target.app.processIdentifier
        if let cached = sessionMenuCache[pid] {
            hasLoadedMenuItems = true
            publish(.loaded(cached))
            return
        }
        hasLoadedMenuItems = true
        publish(.loading)
        let generation = menuLoadGeneration &+ 1
        menuLoadGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.menuLoadGeneration == generation, canStart() else { return }
            let items = self.environment.fetchMenuItems(pid)
            guard self.menuLoadGeneration == generation, canPublish() else { return }
            self.sessionMenuCache[pid] = items
            publish(.loaded(items))
        }
    }
}
