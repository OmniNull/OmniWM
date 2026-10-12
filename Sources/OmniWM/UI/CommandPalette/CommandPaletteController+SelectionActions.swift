// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
extension CommandPaletteController {
    func selectCurrent(trigger: CommandPaletteSelectionTrigger = .primary) {
        guard isExpanded else {
            expandResults()
            return
        }
        if isLauncherMode, launcherPublishedGeneration != launcherRequestGeneration {
            pendingLauncherSelection = (launcherRequestGeneration, trigger)
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
        if selectedMode == .windows, !isExpanded {
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
        selectedItemID = selectionList[newIndex]
        selectionScrollRequest &+= 1
    }
}
