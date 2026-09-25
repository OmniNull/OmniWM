// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
extension CommandPaletteController {
    func performLauncherContextAction(
        _ action: CommandPaletteLauncherResultsView.ContextAction,
        for selection: LauncherSelection
    ) {
        guard isVisible, isLauncherMode, launcherPublishedGeneration == launcherRequestGeneration else { return }
        selectLauncherItem(selection, activate: false)
        switch action {
        case .open:
            selectCurrent()
        case .reveal:
            selectCurrent(trigger: .reveal)
        case .quickLook:
            if selectedMode == .files { isLauncherPreviewVisible = true }
        case .dontSuggest:
            guard selectedMode == .applications,
                  selection.sectionID == .suggestions,
                  let wmController
            else {
                return
            }
            wmController.settings.launcherHiddenSuggestions.insert(selection.itemID)
            startLauncherSearch()
        case .copy,
             .copyPath:
            guard let selectedLauncherURL else { return }
            dismissForLauncherSelection()
            if action == .copy {
                environment.copyFiles([selectedLauncherURL])
            } else {
                environment.copyPath(selectedLauncherURL.path)
            }
        }
    }

    func moveSelection(by delta: Int) {
        expandResults()
        let selectionList = currentSelectionList()
        guard !selectionList.isEmpty else { return }

        let currentIndex: Int = if let selectedItemID,
                                   let idx = selectionList.firstIndex(of: selectedItemID)
        {
            idx
        } else {
            0
        }

        let newIndex = (currentIndex + delta + selectionList.count) % selectionList.count
        selectedItemID = selectionList[newIndex]
        selectionScrollRequest &+= 1
    }
}
