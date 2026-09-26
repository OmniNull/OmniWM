// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension CommandPaletteController {
    func setMarkOnSelectedWindow() {
        guard let wmController else { return }
        guard let item = selectedWindowItemForMarkAction() else {
            actionFeedbackText = markActionFeedback(for: .noSelectedWindow)
            return
        }
        isPresentingMarkPrompt = true
        defer { isPresentingMarkPrompt = false }
        let outcome = makeMarkInteraction(for: wmController, selectedItem: item).setSelectedWindowMark()
        guard outcome != .cancelled else { return }
        refreshWindowItems()
        actionFeedbackText = markActionFeedback(for: outcome)
    }

    func removeMarkFromSelectedWindow() {
        guard let wmController else { return }
        guard let item = selectedWindowItemForMarkAction() else {
            actionFeedbackText = markActionFeedback(for: .noSelectedWindow)
            return
        }
        isPresentingMarkPrompt = true
        defer { isPresentingMarkPrompt = false }
        let outcome = makeMarkInteraction(for: wmController, selectedItem: item)
            .removeMarkFromSelectedWindow(item.id)
        guard outcome != .cancelled else { return }
        refreshWindowItems()
        actionFeedbackText = markActionFeedback(for: outcome)
    }

    private func selectedWindowItemForMarkAction() -> CommandPaletteWindowItem? {
        guard case let .window(token)? = selectedItemID else { return nil }
        let selection = selectedItemID
        refreshWindowItems()
        guard selection == selectedItemID else {
            selectedItemID = nil
            return nil
        }
        return filteredWindowItems.first { $0.id == token }
    }

    private func makeMarkInteraction(
        for wmController: WMController,
        selectedItem: CommandPaletteWindowItem
    ) -> CommandPaletteMarkInteraction {
        CommandPaletteMarkInteraction(
            selectedWindowToken: selectedItem.id,
            isEligibleWindow: { token in
                guard let entry = wmController.workspaceManager.entry(for: token),
                      entry.layoutReason == .standard,
                      wmController.workspaceManager.handle(for: token) === selectedItem.handle
                else {
                    return false
                }
                return true
            },
            requestName: environment.requestWindowMarkName,
            chooseRemovalName: environment.chooseWindowMarkNameToRemove,
            namesForWindow: { wmController.windowMarkRegistry.names(for: $0) },
            lookupMark: { wmController.windowMarkRegistry.lookup($0) },
            setMark: { token, name in wmController.windowMarkRegistry.set(name, for: token) },
            removeMark: { wmController.windowMarkRegistry.remove($0) }
        )
    }

    func refreshWindowItems() {
        guard let wmController else {
            windows = []
            return
        }
        windows = CommandPaletteSearch.buildWindowItems(from: wmController)
    }

    private func markActionFeedback(for outcome: CommandPaletteMarkInteraction.Outcome) -> String {
        switch outcome {
        case let .marked(name):
            "Marked the selected window as ‘\(name)’."
        case let .alreadyMarked(name):
            "The selected window is already marked ‘\(name)’."
        case let .duplicateName(name):
            "‘\(name)’ is already used by another window. Choose a different mark name."
        case .invalidName:
            "Mark names must be non-empty and contain no control characters. Try another name."
        case .staleWindow:
            "The window is no longer eligible. Reopen the Palette and choose a current managed window."
        case .cancelled:
            "No mark was changed."
        case let .removed(name):
            "Removed mark ‘\(name)’ from the selected window."
        case .noSelectedWindow:
            "Select a current window row before changing its marks."
        case .noMarks:
            "The selected window has no marks to remove. Select a marked window."
        case .staleMark:
            "That mark changed while the chooser was open. Choose a current mark and try again."
        }
    }

    func markedSummonFeedback(for outcome: WindowSummonRightOutcome) -> String {
        switch outcome {
        case .summoned:
            "Window summoned right."
        case .movedToWorkspace:
            "Window moved to the empty workspace."
        case .moveFailed:
            "Could not move this window into the empty workspace. Press Enter to focus it instead."
        case .noAnchor:
            "This workspace is not empty. Focus a managed window here before using Shift-Enter."
        case .selfSummon:
            "A window cannot be summoned beside itself. Choose a different marked window."
        case .hiddenTarget:
            "This app is hidden. Press Enter to unhide and focus it; Shift-Enter cannot summon it."
        case .staleTarget:
            "This marked window is no longer available. Search again for a current result."
        case .unsupportedLayout:
            "Summon right is not supported by the current layout. Press Enter to focus this window instead."
        case .actionFailed:
            "Could not summon this window right now. Press Enter to focus it instead."
        }
    }

    func windowSelectionFeedback(
        for trigger: CommandPaletteSelectionTrigger,
        selectedItemID: CommandPaletteSelectionID?
    ) -> String {
        guard case let .window(token)? = selectedItemID else {
            return "Select a current window result first."
        }

        guard let wmController,
              let entry = wmController.workspaceManager.entry(for: token),
              entry.layoutReason == .standard,
              wmController.workspaceManager.handle(for: token) != nil
        else {
            return "This window or mark is no longer available. Search again for a current result."
        }

        switch trigger {
        case .primary,
             .reveal:
            return "This window is no longer in the current results. Search again before focusing it."
        case .alternate:
            break
        }

        if wmController.workspaceManager.isAppHidden(pid: token.pid) {
            return "This app is hidden. Press Enter to unhide and focus it; Shift-Enter cannot summon it."
        }
        guard let anchor = focusSession.summonAnchor,
              wmController.workspaceManager.entry(for: anchor.token) != nil
        else {
            return "Summon right is unavailable. Focus a managed window in the active workspace first."
        }
        return "This window cannot be summoned right now. Press Enter to focus it instead."
    }
}
