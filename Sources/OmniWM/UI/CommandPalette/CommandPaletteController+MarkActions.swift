// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension CommandPaletteController {
    func setMarkOnSelectedWindow() {
        guard let wmController else { return }
        guard let item = selectedWindowItemForMarkAction() else {
            actionFeedbackText = markActionFeedback(for: .noSelectedWindow)
            return
        }
        isPresentingModalPrompt = true
        defer {
            restoreKeyWindowAfterModalPrompt()
            isPresentingModalPrompt = false
        }
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
        isPresentingModalPrompt = true
        defer {
            restoreKeyWindowAfterModalPrompt()
            isPresentingModalPrompt = false
        }
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
        return selectableWindowItems.first { $0.id == token }
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
        windows = CommandPaletteSearch.buildWindowItems(
            from: wmController, focusedWindow: focusSession.restoreFocusTarget
        )
    }

    private func markActionFeedback(for outcome: CommandPaletteMarkInteraction.Outcome) -> String {
        switch outcome {
        case let .marked(name):
            String(localized: "Marked the selected window as ‘\(name)’.")
        case let .alreadyMarked(name):
            String(localized: "The selected window is already marked ‘\(name)’.")
        case let .duplicateName(name):
            String(localized: "‘\(name)’ is already used by another window. Choose a different mark name.")
        case .invalidName:
            String(localized: "Mark names must be non-empty and contain no control characters. Try another name.")
        case .staleWindow:
            String(
                localized: "The window is no longer eligible. Reopen the Palette and choose a current managed window."
            )
        case .cancelled:
            String(localized: "No mark was changed.")
        case let .removed(name):
            String(localized: "Removed mark ‘\(name)’ from the selected window.")
        case .noSelectedWindow:
            String(localized: "Select a current window row before changing its marks.")
        case .noMarks:
            String(localized: "The selected window has no marks to remove. Select a marked window.")
        case .staleMark:
            String(localized: "That mark changed while the chooser was open. Choose a current mark and try again.")
        }
    }

    func markedSummonFeedback(for outcome: WindowSummonRightOutcome) -> String {
        switch outcome {
        case .summoned:
            String(localized: "Window summoned right.")
        case .movedToWorkspace:
            String(localized: "Window moved to the empty workspace.")
        case .moveFailed:
            String(localized: "Could not move this window into the empty workspace. Press Enter to focus it instead.")
        case .noAnchor:
            String(localized: "This workspace is not empty. Focus a managed window here before using Shift-Enter.")
        case .selfSummon:
            String(localized: "A window cannot be summoned beside itself. Choose a different marked window.")
        case .hiddenTarget:
            String(localized: "This app is hidden. Press Enter to unhide and focus it; Shift-Enter cannot summon it.")
        case .staleTarget:
            String(localized: "This marked window is no longer available. Search again for a current result.")
        case .unsupportedLayout:
            String(
                localized: "Summon right is not supported by the current layout. Press Enter to focus this window instead."
            )
        case .actionFailed:
            String(localized: "Could not summon this window right now. Press Enter to focus it instead.")
        }
    }

    func windowSelectionFeedback(
        for trigger: CommandPaletteSelectionTrigger,
        selectedItemID: CommandPaletteSelectionID?
    ) -> String {
        guard case let .window(token)? = selectedItemID else {
            return String(localized: "Select a current window result first.")
        }

        guard let wmController,
              let entry = wmController.workspaceManager.entry(for: token),
              entry.layoutReason == .standard,
              wmController.workspaceManager.handle(for: token) != nil
        else {
            return String(localized: "This window or mark is no longer available. Search again for a current result.")
        }

        switch trigger {
        case .primary,
             .reveal:
            return String(
                localized: "This window is no longer in the current results. Search again before focusing it."
            )
        case .alternate:
            break
        }

        if wmController.workspaceManager.isAppHidden(pid: token.pid) {
            return String(
                localized: "This app is hidden. Press Enter to unhide and focus it; Shift-Enter cannot summon it."
            )
        }
        guard let anchor = focusSession.summonAnchor,
              wmController.workspaceManager.entry(for: anchor.token) != nil
        else {
            return String(
                localized: "Summon right is unavailable. Focus a managed window in the active workspace first."
            )
        }
        return String(localized: "This window cannot be summoned right now. Press Enter to focus it instead.")
    }
}
