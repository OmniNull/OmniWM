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
        unifiedSelectionFollowsFirstRow = true
        unifiedPendingSearches = []
        pendingUnifiedSelection = nil
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
        unifiedSelectionFollowsFirstRow = true
        pendingUnifiedSelection = nil
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
            keepingVisible: unifiedSelectionFollowsFirstRow ? nil : selectedItemID
        )
    }

    func openUnifiedTopHit(at index: Int) {
        if deferUntilUnifiedResultsArrive(.topHit(index)) { return }
        let topHits = unifiedQuery.isEmpty ? [] : unifiedResults.topHits
        guard topHits.indices.contains(index) else { return }
        activateUnifiedRow(topHits[index], trigger: .primary)
    }

    func deferUntilUnifiedResultsArrive(_ selection: PendingUnifiedSelection) -> Bool {
        guard unifiedSelectionFollowsFirstRow, !unifiedPendingSearches.isEmpty else { return false }
        pendingUnifiedSelection = selection
        return true
    }

    func highlightUnifiedRow(_ id: CommandPaletteSelectionID?) {
        unifiedSelectionFollowsFirstRow = false
        pendingUnifiedSelection = nil
        selectedItemID = id
    }

    func activateUnifiedRow(_ id: CommandPaletteSelectionID, trigger: CommandPaletteSelectionTrigger) {
        highlightUnifiedRow(id)
        selectCurrent(trigger: trigger)
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
        highlightUnifiedRow(sections[target].first)
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
              mode != .applications,
              mode != .files,
              let key = unifiedCandidates(for: mode).first(where: { $0.id == id })?.pickKey
        else {
            return
        }
        wmController.settings.recordUnifiedSearchPick(query: searchText, key: key)
    }

    private func startUnifiedLauncherSearches() {
        launcherRequestGeneration &+= 1
        let generation = launcherRequestGeneration
        guard let wmController, !unifiedQuery.isEmpty else {
            environment.stopApplicationSearch()
            environment.stopFileSearch()
            clearLauncherResults()
            return
        }
        if unifiedSearchedModes.contains(.applications) {
            unifiedPendingSearches.insert(.applications)
            isApplicationLoading = applicationSections.isEmpty
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
                    self.unifiedSearchDidPublish(.applications)
                }
        }
        if unifiedSearchedModes.contains(.files) {
            LauncherIconStore.shared.cancelAllFileThumbnails()
            unifiedPendingSearches.insert(.files)
            isFileLoading = fileSections.isEmpty
            environment.submitFileSearch(wmController, searchText, nil, generation) { [weak self] published, sections in
                guard let self, self.isUnifiedPublicationCurrent(published) else { return }
                self.fileSections = sections
                self.isFileLoading = false
                self.unifiedSearchDidPublish(.files)
            }
        }
    }

    private func unifiedSearchDidPublish(_ mode: CommandPaletteMode) {
        unifiedPendingSearches.remove(mode)
        filterInputDidChange()
        guard unifiedPendingSearches.isEmpty, let pending = pendingUnifiedSelection else { return }
        pendingUnifiedSelection = nil
        switch pending {
        case let .current(trigger):
            selectCurrent(trigger: trigger)
        case let .topHit(index):
            openUnifiedTopHit(at: index)
        }
    }

    private func clearLauncherResults() {
        applicationSections = []
        fileSections = []
        isApplicationLoading = false
        isFileLoading = false
        unifiedPendingSearches = []
        pendingUnifiedSelection = nil
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
                        pickKey: .launcherTarget(item.id)
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
            let launchTarget = entry.kind == .application ? LauncherPaths.expanded(entry.path) : entry.id.uuidString
            return UnifiedSearchCandidate(
                id: .launcherEntry(entry.id),
                title: entry.name,
                otherFields: [entry.keywords, entry.path, entry.command],
                pickKey: .launcherTarget(launchTarget)
            )
        }
        let applications = displayedApplicationSections.flatMap { section in
            section.items.map { item in
                UnifiedSearchCandidate(
                    id: .application(section.id, item.id),
                    title: item.displayName,
                    otherFields: [item.categoryName].compactMap(\.self),
                    pickKey: .launcherTarget(item.id)
                )
            }
        }
        return saved + applications
    }
}
