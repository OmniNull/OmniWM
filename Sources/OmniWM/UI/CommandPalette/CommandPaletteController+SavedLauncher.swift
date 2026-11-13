// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
extension CommandPaletteController {
    var launcherSavedEntries: [LauncherEntry] {
        guard launcherFilter == .all || launcherFilter == .saved,
              let settings = wmController?.settings else { return [] }
        let query = searchText == "/" ? "" : searchText
        return settings.launcher.entries.filter { $0.matches(query) }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var launcherExecutables: [LauncherExecutable] {
        guard launcherFilter == .cli else { return [] }
        return LauncherExecutableCatalog.shared.matching(searchText)
    }

    var displayedApplicationSections: [LauncherSection<LauncherApplicationResult>] {
        guard launcherFilter == .all || launcherFilter == .apps else { return [] }
        let shown = Set(launcherSavedEntries.compactMap { savedApplicationIdentifiers[$0.id] })
        guard launcherFilter == .all, !shown.isEmpty else { return applicationSections }
        return applicationSections.compactMap { section in
            let items = section.items.filter { !shown.contains($0.bundleIdentifier ?? "") }
            return items.isEmpty ? nil : LauncherSection(id: section.id, title: section.title, items: items)
        }
    }

    func selectLauncherFilter(_ filter: LauncherFilter) {
        guard filter != launcherFilter else { return }
        launcherFilter = filter
        selectedApplicationChip = nil
        startLauncherSearch()
    }

    func refreshLauncher() {
        guard let wmController else { return }
        ApplicationCatalogService.shared.refreshIfNeeded(
            refreshMetadata: true, extraFolders: wmController.settings.launcher.appFolders
        )
        LauncherExecutableCatalog.shared.refresh(configuration: wmController.settings.launcher, force: true)
        startLauncherSearch()
    }

    func showLauncherSettings(entry: LauncherEntry? = nil, runOnly: Bool = false) {
        guard let wmController else { return }
        dismiss(reason: .selection)
        SettingsWindowController.shared.show(
            settings: wmController.settings, controller: wmController,
            section: entry == nil ? .launcher : nil,
            launcherRequest: entry.map { .init(entry: $0, runOnly: runOnly) }
        )
    }

    func addLauncherEntry(_ kind: LauncherEntry.Kind) {
        var entry = LauncherEntry()
        entry.kind = kind
        showLauncherSettings(entry: entry)
    }

    func removeLauncherEntry(_ id: UUID, settings: SettingsStore? = nil) {
        guard !isPresentingModalPrompt, let settings = settings ?? wmController?.settings,
              let entry = settings.launcher.entries.first(where: { $0.id == id }) else { return }
        let fromPalette = isVisible
        if fromPalette { isPresentingModalPrompt = true }
        let warnsAboutShortcut = Self.shortcutCleared(byRemoving: entry, from: settings) != nil
        environment
            .confirmLauncherEntryRemoval(
                entry,
                warnsAboutShortcut,
                fromPalette ? presentation.panel : NSApp.keyWindow
            ) { [weak self] confirmed in
                guard let self else { return }
                if fromPalette {
                    self.restoreKeyWindowAfterModalPrompt()
                    self.isPresentingModalPrompt = false
                }
                guard confirmed, settings.launcher.entries.contains(entry) else { return }
                if warnsAboutShortcut, let actionID = Self.shortcutCleared(byRemoving: entry, from: settings) {
                    settings.clearBinding(for: actionID)
                    settings.updateModeKey(for: actionID, newModeKey: nil)
                }
                settings.launcher.entries.removeAll { $0.id == id }
                if self.isVisible {
                    self.refreshSavedApplicationIdentifiers(settings: settings)
                    self.updateSelectionAfterFilterChange()
                }
            }
    }

    private static func shortcutCleared(byRemoving entry: LauncherEntry, from settings: SettingsStore) -> String? {
        guard let bundleID = entry.bundleIdentifier,
              !settings.launcher.entries.contains(where: { $0.id != entry.id && $0.bundleIdentifier == bundleID })
        else {
            return nil
        }
        let actionID = ActionCatalog.openAppPrefix + bundleID
        let isAssigned = settings.hotkeyBindings.contains {
            $0.id == actionID && (!$0.binding.isUnassigned || $0.modeKey != nil)
        }
        return isAssigned ? actionID : nil
    }

    func refreshSavedApplicationIdentifiers(settings: SettingsStore) {
        savedApplicationIdentifiers = settings.launcher.entries.filter { $0.kind == .application }
            .reduce(into: [:]) { identifiers, entry in
                identifiers[entry.id] = ApplicationCatalogFilter.resolvedBundleURL(LauncherPaths.expanded(entry.path))
                    .flatMap { Bundle(url: $0)?.bundleIdentifier }
            }
    }

    func publishLauncherTools() {
        guard isVisible, selectedMode == .applications, launcherFilter == .cli,
              !LauncherExecutableCatalog.shared.isLoading else { return }
        launcherPublishedGeneration = launcherRequestGeneration
        updateSelectionAfterFilterChange()
        if let pending = pendingLauncherSelection, pending.generation == launcherRequestGeneration {
            pendingLauncherSelection = nil
            selectCurrent(trigger: pending.trigger)
        }
    }
}
