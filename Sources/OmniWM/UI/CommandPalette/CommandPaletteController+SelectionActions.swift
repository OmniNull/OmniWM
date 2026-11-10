// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
extension CommandPaletteController {
    func selectCurrent(trigger: CommandPaletteSelectionTrigger = .primary) {
        if isUnifiedSearch, deferUntilUnifiedResultsArrive(.current(trigger)) { return }
        if isUnifiedSearch, unifiedSelectionList.isEmpty { return }
        guard isExpanded else {
            expandResults()
            return
        }
        if isUnifiedSearch {
            selectUnifiedCurrent(trigger: trigger)
            return
        }
        if isLauncherMode, launcherPublishedGeneration != launcherRequestGeneration {
            pendingLauncherSelection = (launcherRequestGeneration, trigger)
            return
        }
        if selectedMode == .applications, case let .executable(path)? = selectedItemID,
           let executable = launcherExecutables.first(where: { $0.path == path })
        {
            if trigger == .reveal {
                dismiss(reason: .selection)
                environment.revealInFinder(URL(fileURLWithPath: path))
            } else {
                showLauncherSettings(entry: executable.entry, runOnly: true)
            }
            return
        }
        let previousSelectionID = selectedItemID
        if selectedMode == .windows {
            refreshWindowItems()
        }
        guard selectedItemID == previousSelectionID,
              let action = resolvedSelectionAction(for: trigger)
        else {
            if selectedMode == .windows {
                actionFeedbackText = windowSelectionFeedback(for: trigger, selectedItemID: previousSelectionID)
            }
            return
        }
        performSelected(action)
    }

    private func selectUnifiedCurrent(trigger: CommandPaletteSelectionTrigger) {
        if case let .showAll(mode)? = selectedItemID {
            leaveUnifiedSearch(to: mode)
            return
        }
        let previousSelectionID = selectedItemID
        if case .window? = previousSelectionID {
            refreshWindowItems()
        }
        guard selectedItemID == previousSelectionID,
              let action = resolvedSelectionAction(for: trigger)
        else {
            if case .window? = previousSelectionID {
                actionFeedbackText = windowSelectionFeedback(for: trigger, selectedItemID: previousSelectionID)
            }
            return
        }
        recordUnifiedSearchPick(for: previousSelectionID)
        performSelected(action)
    }

    private func performSelected(_ action: CommandPaletteActionExecutor.Action) {
        if case .moveWindowToWorkspace = action {
            let outcome = actionExecutor.perform(action) ?? .moveFailed
            guard outcome == .movedToWorkspace else {
                actionFeedbackText = markedSummonFeedback(for: outcome)
                return
            }
            dismiss(reason: .selection)
            return
        }

        if case .summonMarkedWindowRight = action {
            let outcome = actionExecutor.perform(action) ?? .actionFailed
            guard outcome == .summoned else {
                actionFeedbackText = markedSummonFeedback(for: outcome)
                return
            }
            dismiss(reason: .selection)
            return
        }
        if case .command(_, .openCommandPalette, _) = action {
            dismiss(reason: .cancel)
            return
        }
        if case let .command(_, .openCommandPaletteMode(mode), _) = action {
            let mode = CommandPaletteMode(ipc: mode)
            if isUnifiedSearch {
                leaveUnifiedSearch(to: mode, keepingQuery: false)
                return
            }
            guard mode != selectedMode else { return }
            searchText = ""
            selectedMode = mode
            return
        }
        dismiss(reason: .selection)
        actionExecutor.perform(action)
    }

    func pasteClipboardItem(_ id: UUID, withoutFormatting: Bool = false) {
        guard let wmController, isClipboardHistoryEnabled else { return }
        let target = focusSession.clipboardPasteTarget()
        dismiss(reason: .selection)
        actionExecutor.perform(.pasteClipboard(wmController, id, target, withoutFormatting))
    }

    func performLauncherContextAction(
        _ action: CommandPaletteLauncherResultsView.ContextAction,
        for selection: LauncherSelection
    ) {
        guard isVisible, isLauncherMode, launcherPublishedGeneration == launcherRequestGeneration else { return }
        selectLauncherItem(selection, activate: false)
        switch action {
        case .edit:
            guard let id = UUID(uuidString: selection.itemID),
                  let entry = launcherSavedEntries.first(where: { $0.id == id }) else { return }
            showLauncherSettings(entry: entry)
        case .remove:
            if let id = UUID(uuidString: selection.itemID) { removeLauncherEntry(id) }
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
        if isUnifiedSearch, unifiedSelectionList.isEmpty { return }
        if isUnifiedSearch || selectedMode == .windows, !isExpanded {
            expandResults()
            return
        }
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
        if isUnifiedSearch {
            highlightUnifiedRow(selectionList[newIndex])
        } else {
            selectedItemID = selectionList[newIndex]
        }
        selectionScrollRequest &+= 1
    }
}
