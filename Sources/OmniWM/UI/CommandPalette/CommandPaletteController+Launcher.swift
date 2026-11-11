// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
extension CommandPaletteController {
    var isLauncherMode: Bool {
        selectedMode == .applications || selectedMode == .files
    }

    var launcherViewStyle: LauncherViewStyle {
        selectedMode == .applications ? (launcherFilter == .apps ? applicationViewStyle : .list) : fileViewStyle
    }

    var launcherChips: [LauncherChip] {
        selectedMode == .applications ? (launcherFilter == .apps ? applicationChips : []) : fileChips
    }

    var selectedLauncherChipID: String? {
        if searchText == "/" {
            let chips = launcherChips
            if chips.indices.contains(launcherScopeChipIndex) {
                return chips[launcherScopeChipIndex].id
            }
        }
        return selectedMode == .applications ? selectedApplicationChip?.id : selectedFileChip?.id
    }

    var selectedLauncherItem: LauncherSelection? {
        guard let selectedItemID else { return nil }
        switch selectedItemID {
        case .application where selectedMode != .applications,
             .file where selectedMode != .files:
            return nil
        default:
            return Self.launcherSelection(selectedItemID)
        }
    }

    var selectedLauncherFileResult: LauncherFileResult? {
        guard selectedMode == .files,
              launcherPublishedGeneration == launcherRequestGeneration,
              case let .file(sectionID, itemID)? = selectedItemID
        else {
            return nil
        }
        return fileSections.first(where: { $0.id == sectionID })?.items.first(where: { $0.id == itemID })
    }

    var selectedLauncherURL: URL? {
        switch selectedItemID {
        case let .executable(path):
            return URL(fileURLWithPath: path)
        case let .launcherEntry(id):
            guard let entry = launcherSavedEntries.first(where: { $0.id == id }),
                  !entry.path.isEmpty else { return nil }
            return URL(fileURLWithPath: LauncherPaths.expanded(entry.path))
        case let .application(sectionID, itemID) where selectedMode == .applications:
            return applicationSections.first(where: { $0.id == sectionID })?
                .items.first(where: { $0.id == itemID })?.bundleURL
        case .file:
            return selectedLauncherFileResult?.fileURL
        default:
            return nil
        }
    }

    func resetLauncherState(settings: SettingsStore) {
        launcherFilter = .all
        refreshSavedApplicationIdentifiers(settings: settings)
        applicationSections = []
        fileSections = []
        applicationChips = []
        fileChips = FileSearchEngine.chips
        selectedApplicationChip = nil
        selectedFileChip = nil
        applicationViewStyle = settings.commandPaletteApplicationsViewStyle
        fileViewStyle = settings.commandPaletteFilesViewStyle
        isApplicationLoading = false
        isFileLoading = false
        launcherColumnCount = 1
        launcherScopeChipIndex = 0
        launcherResultsFocused = false
        launcherShowsPaths = false
        isLauncherPreviewVisible = false
        launcherRequestGeneration &+= 1
        launcherPublishedGeneration = -1
        pendingLauncherSelection = nil
    }

    func invalidateLauncherSearch() {
        isLauncherPreviewVisible = false
        retireShellFilePreview()
        launcherRequestGeneration &+= 1
        launcherPublishedGeneration = -1
        pendingLauncherSelection = nil
        environment.stopApplicationSearch()
        environment.stopFileSearch()
        LauncherIconStore.shared.cancelAllFileThumbnails()
    }

    func launcherSearchTextDidChange(from oldValue: String) {
        guard searchText != oldValue else { return }
        if searchText == "/" { launcherScopeChipIndex = 0 }
        launcherResultsFocused = false
        selectedItemID = nil
        selectionScrollRequest &+= 1
        startLauncherSearch()
    }

    func startLauncherSearch() {
        guard isVisible, isLauncherMode, let wmController else { return }
        let query = searchText == "/" ? "" : searchText
        launcherRequestGeneration &+= 1
        let generation = launcherRequestGeneration
        launcherPublishedGeneration = -1
        pendingLauncherSelection = nil
        selectedItemID = nil

        if selectedMode == .applications, launcherFilter == .saved || launcherFilter == .cli {
            environment.stopApplicationSearch()
            isApplicationLoading = false
            if launcherFilter == .cli {
                let catalog = LauncherExecutableCatalog.shared
                catalog.onChanged = { [weak self] in self?.publishLauncherTools() }
                catalog.refresh(configuration: wmController.settings.launcher)
                publishLauncherTools()
            } else {
                launcherPublishedGeneration = generation
                updateSelectionAfterFilterChange()
            }
            return
        }
        if selectedMode == .applications {
            isApplicationLoading = applicationSections.isEmpty
            environment.submitApplicationSearch(
                wmController,
                query,
                selectedApplicationChip,
                generation
            ) { [weak self] publishedGeneration, sections, chips in
                self?.publishApplications(sections, chips: chips, generation: publishedGeneration)
            }
        } else {
            LauncherIconStore.shared.cancelAllFileThumbnails()
            isFileLoading = fileSections.isEmpty
            environment
                .submitFileSearch(
                    wmController,
                    query,
                    selectedFileChip,
                    generation
                ) { [weak self] publishedGeneration, sections in
                    self?.publishFiles(sections, generation: publishedGeneration)
                }
        }
    }

    func selectLauncherChip(_ chip: LauncherChip) {
        guard isLauncherMode else { return }
        if selectedMode == .applications {
            selectedApplicationChip = selectedApplicationChip?.id == chip.id ? nil : chip
        } else {
            selectedFileChip = selectedFileChip?.id == chip.id ? nil : chip
        }
        launcherResultsFocused = false
        startLauncherSearch()
    }

    func clearLauncherChip() {
        guard isLauncherMode else { return }
        if selectedMode == .applications {
            selectedApplicationChip = nil
        } else {
            selectedFileChip = nil
        }
        startLauncherSearch()
    }

    func setLauncherViewStyle(_ style: LauncherViewStyle) {
        guard isLauncherMode, let wmController else { return }
        if selectedMode == .applications {
            applicationViewStyle = style
            wmController.settings.commandPaletteApplicationsViewStyle = style
        } else {
            fileViewStyle = style
            wmController.settings.commandPaletteFilesViewStyle = style
        }
    }

    func selectLauncherItem(_ selection: LauncherSelection, activate: Bool) {
        guard isLauncherMode, launcherPublishedGeneration == launcherRequestGeneration else { return }
        launcherResultsFocused = true
        if selection.sectionID == .saved, let id = UUID(uuidString: selection.itemID) {
            selectedItemID = .launcherEntry(id)
        } else if selection.sectionID == .executables {
            selectedItemID = .executable(selection.itemID)
        } else {
            selectedItemID = selectedMode == .applications
                ? .application(selection.sectionID, selection.itemID)
                : .file(selection.sectionID, selection.itemID)
        }
        if activate { selectCurrent() }
    }

    private func publishApplications(
        _ sections: [LauncherSection<LauncherApplicationResult>],
        chips: [LauncherChip],
        generation: Int
    ) {
        guard isVisible, selectedMode == .applications, generation == launcherRequestGeneration else { return }
        let priorSelection = launcherPublishedGeneration == generation ? selectedItemID : nil
        applicationSections = sections
        applicationChips = chips
        isApplicationLoading = false
        launcherPublishedGeneration = generation
        let selections = currentSelectionList()
        updateShellSelectionIndex(selections)
        if let priorSelection, selections.contains(priorSelection) {
            selectedItemID = priorSelection
        } else {
            selectFirstLauncherResult(selections.first, after: generation)
        }
    }

    private func publishFiles(_ sections: [LauncherSection<LauncherFileResult>], generation: Int) {
        guard isVisible, selectedMode == .files, generation == launcherRequestGeneration else { return }
        fileSections = sections
        isFileLoading = false
        launcherPublishedGeneration = generation
        let selections = currentSelectionList()
        updateShellSelectionIndex(selections)
        selectFirstLauncherResult(selections.first, after: generation)
    }

    private func selectFirstLauncherResult(_ first: CommandPaletteSelectionID?, after generation: Int) {
        selectedItemID = first
        selectionScrollRequest &+= 1
        guard let pending = pendingLauncherSelection, pending.generation == generation else { return }
        pendingLauncherSelection = nil
        if selectedItemID != nil {
            selectCurrent(trigger: pending.trigger)
        }
    }
}
