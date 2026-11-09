// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
extension CommandPaletteController {
    func beginUnifiedSearchSession(requestedMode: CommandPaletteMode?, settings: SettingsStore) {
        isUnifiedSearch = requestedMode == nil && settings.commandPalette.unifiedSearch
        unifiedSearchedModes = settings.commandPalette.searchedModes
        unifiedResults = UnifiedSearchResults()
        unifiedLearnedPicks = []
    }

    var isMenuSearched: Bool {
        isUnifiedSearch ? unifiedSearchedModes.contains(.menu) : selectedMode == .menu
    }

    var unifiedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var showsUnifiedWindowList: Bool {
        unifiedQuery.isEmpty && unifiedSearchedModes.contains(.windows)
    }

    var unifiedSelectionList: [CommandPaletteSelectionID] {
        if unifiedQuery.isEmpty {
            return showsUnifiedWindowList ? windows.map { .window($0.id) } : []
        }
        return unifiedResults.selectionOrder
    }

    var isUnifiedSearchLoading: Bool {
        (isMenuLoading && unifiedSearchedModes.contains(.menu)) || isApplicationLoading || isFileLoading
    }

    func unifiedSearchTextDidChange(from oldValue: String) {
        guard searchText != oldValue else { return }
        selectedItemID = nil
        unifiedLearnedPicks = wmController?.settings.unifiedSearchLearnedPicks(for: searchText) ?? []
        startUnifiedLauncherSearches()
        filterInputDidChange()
        selectionScrollRequest &+= 1
    }

    func refreshUnifiedResults() {
        guard !unifiedQuery.isEmpty else {
            unifiedResults = UnifiedSearchResults()
            return
        }
        unifiedResults = UnifiedSearch.compose(
            query: searchText,
            searchedModes: unifiedSearchedModes,
            results: Dictionary(uniqueKeysWithValues: unifiedSearchedModes.map { ($0, unifiedCandidates(for: $0)) }),
            learnedPicks: unifiedLearnedPicks,
            keepingVisible: selectedItemID
        )
    }

    func openUnifiedTopHit(at index: Int) {
        let topHits = unifiedQuery.isEmpty ? [] : unifiedResults.topHits
        guard topHits.indices.contains(index) else { return }
        selectedItemID = topHits[index]
        selectCurrent()
    }

    func jumpUnifiedSection(by delta: Int) {
        let sections = unifiedQuery.isEmpty ? [] : unifiedResults.sections
        guard !sections.isEmpty else { return }
        expandResults()
        let current = selectedItemID.flatMap { id in sections.firstIndex { $0.contains(id) } }
        let target = if let current {
            (current + delta + sections.count) % sections.count
        } else {
            delta > 0 ? 0 : sections.count - 1
        }
        selectedItemID = sections[target].first
        selectionScrollRequest &+= 1
    }

    func leaveUnifiedSearch(to mode: CommandPaletteMode, keepingQuery: Bool = true) {
        guard isUnifiedSearch else { return }
        if !keepingQuery {
            searchText = ""
        }
        clearLauncherResults()
        unifiedResults = UnifiedSearchResults()
        isUnifiedSearch = false
        if let wmController {
            reservePaletteShortcuts(wmController)
        }
        let target = isModeAvailable(mode) ? mode : .windows
        if selectedMode == target {
            activateSelectedMode()
        } else {
            selectedMode = target
        }
    }

    func recordUnifiedSearchPick(for id: CommandPaletteSelectionID?) {
        guard let id,
              let wmController,
              !unifiedQuery.isEmpty,
              let mode = id.mode,
              let key = unifiedCandidates(for: mode).first(where: { $0.id == id })?.pickKey
        else {
            return
        }
        wmController.settings.recordUnifiedSearchPick(query: searchText, key: key)
    }

    private func startUnifiedLauncherSearches() {
        launcherRequestGeneration &+= 1
        let generation = launcherRequestGeneration
        clearLauncherResults()
        guard let wmController, !unifiedQuery.isEmpty else {
            environment.stopApplicationSearch()
            environment.stopFileSearch()
            return
        }
        if unifiedSearchedModes.contains(.applications) {
            isApplicationLoading = true
            environment
                .submitApplicationSearch(
                    wmController,
                    searchText,
                    nil,
                    generation
                ) { [weak self] published, sections, _ in
                    guard let self, self.isUnifiedPublicationCurrent(published) else { return }
                    self.applicationSections = sections
                    self.isApplicationLoading = false
                    self.filterInputDidChange()
                }
        }
        if unifiedSearchedModes.contains(.files) {
            LauncherIconStore.shared.cancelAllFileThumbnails()
            isFileLoading = true
            environment.submitFileSearch(wmController, searchText, nil, generation) { [weak self] published, sections in
                guard let self, self.isUnifiedPublicationCurrent(published) else { return }
                self.fileSections = sections
                self.isFileLoading = false
                self.filterInputDidChange()
            }
        }
    }

    private func clearLauncherResults() {
        applicationSections = []
        fileSections = []
        isApplicationLoading = false
        isFileLoading = false
    }

    private func isUnifiedPublicationCurrent(_ generation: Int) -> Bool {
        isVisible && isUnifiedSearch && generation == launcherRequestGeneration
    }

    private func unifiedCandidates(for mode: CommandPaletteMode) -> [UnifiedSearchCandidate] {
        switch mode {
        case .windows:
            windowCandidates()
        case .menu:
            menuCandidates()
        case .clipboard:
            clipboardCandidates()
        case .commands:
            CommandPaletteSearch.filterCommandItems(commandItems, query: searchText)
                .filter(\.isLayoutCompatible)
                .map { item in
                    UnifiedSearchCandidate(
                        id: .command(item.id),
                        title: item.spec.localizedTitle,
                        otherFields: [item.spec.category.localizedDisplayName],
                        pickKey: .command(actionID: item.id)
                    )
                }
        case .applications:
            launcherCandidates()
        case .files:
            fileSections.flatMap { section in
                section.items.map { item in
                    UnifiedSearchCandidate(
                        id: .file(section.id, item.id),
                        title: item.displayName,
                        otherFields: [item.fileURL.path],
                        pickKey: .file(path: item.fileURL.path)
                    )
                }
            }
        }
    }

    private func windowCandidates() -> [UnifiedSearchCandidate] {
        let recency = Dictionary(
            windows.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return CommandPaletteSearch.filterWindowItems(windows, query: searchText).map { item in
            UnifiedSearchCandidate(
                id: .window(item.id),
                title: item.title.isEmpty ? item.appName : item.title,
                otherFields: [item.appName, item.workspaceName] + item.markNames,
                pickKey: item.bundleIdentifier.map { .window(bundleID: $0) },
                focusRecency: recency[item.id]
            )
        }
    }

    private func menuCandidates() -> [UnifiedSearchCandidate] {
        guard isMenuModeAvailable else { return [] }
        let bundleID = focusSession.menuFocusTarget?.app.bundleIdentifier
        return CommandPaletteSearch.filterMenuItems(menuItems, query: searchText).map { item in
            UnifiedSearchCandidate(
                id: .menu(item.id),
                title: item.title,
                otherFields: [item.fullPath],
                pickKey: bundleID.map { .menuItem(bundleID: $0, path: item.fullPath) }
            )
        }
    }

    private func clipboardCandidates() -> [UnifiedSearchCandidate] {
        guard isClipboardHistoryEnabled else { return [] }
        return CommandPaletteSearch.filterClipboardItems(clipboardItems, query: searchText).map { item in
            UnifiedSearchCandidate(
                id: .clipboard(item.id),
                title: item.title,
                otherFields: [item.searchText, item.subtitle]
            )
        }
    }

    private func launcherCandidates() -> [UnifiedSearchCandidate] {
        let saved = launcherSavedEntries.map { entry in
            UnifiedSearchCandidate(
                id: .launcherEntry(entry.id),
                title: entry.name,
                otherFields: [entry.keywords, entry.path, entry.command],
                pickKey: .launcherEntry(entry.id)
            )
        }
        let applications = displayedApplicationSections.flatMap { section in
            section.items.map { item in
                UnifiedSearchCandidate(
                    id: .application(section.id, item.id),
                    title: item.displayName,
                    otherFields: [item.categoryName].compactMap(\.self),
                    pickKey: .application(bundleID: item.bundleIdentifier ?? item.id)
                )
            }
        }
        return saved + applications
    }
}
