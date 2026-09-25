// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

@MainActor
@Observable
final class CommandPaletteController: NSObject, NSWindowDelegate {
    private(set) var isVisible = false
    private(set) var isExpanded = false
    var actionFeedbackText: String?
    var searchText = "" {
        didSet {
            if searchText != oldValue { actionFeedbackText = nil }
            if isVisible, isLauncherMode {
                launcherSearchTextDidChange(from: oldValue)
            } else {
                updateSelectionAfterFilterChange()
            }
            if !searchText.isEmpty {
                expandResults()
            }
        }
    }

    var selectedMode: CommandPaletteMode = .windows {
        didSet { handleModeChange(from: oldValue) }
    }

    var selectedItemID: CommandPaletteSelectionID? {
        didSet {
            if selectedItemID != oldValue {
                actionFeedbackText = nil
                loadSelectedClipboardPreview()
            }
        }
    }

    var windows: [CommandPaletteWindowItem] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    private(set) var menuItems: [MenuItemModel] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    private(set) var isMenuLoading = false
    private(set) var clipboardItems: [ClipboardPaletteItem] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    private(set) var commandItems: [CommandPaletteCommandItem] = [] {
        didSet { updateSelectionAfterFilterChange() }
    }

    private(set) var isClipboardHistoryEnabled = false
    private(set) var clipboardPreview: ClipboardPalettePreview?
    private(set) var clipboardPreviewImage: NSImage?
    private(set) var isClipboardPreviewLoading = false
    private(set) var clipboardErrorText: String?
    var selectionScrollRequest = 0

    var applicationSections: [LauncherSection<LauncherApplicationResult>] = []
    var fileSections: [LauncherSection<LauncherFileResult>] = []
    var applicationChips: [LauncherChip] = []
    var fileChips: [LauncherChip] = []
    var selectedApplicationChip: LauncherChip?
    var selectedFileChip: LauncherChip?
    var applicationViewStyle: LauncherViewStyle = .grid
    var fileViewStyle: LauncherViewStyle = .grid
    var isApplicationLoading = false
    var isFileLoading = false
    var launcherColumnCount = 1
    var launcherScopeChipIndex = 0
    var launcherResultsFocused = false
    var launcherShowsPaths = false
    var isLauncherPreviewVisible = false
    var launcherRequestGeneration = 0
    var launcherPublishedGeneration = -1
    var pendingLauncherSelection: (generation: Int, trigger: CommandPaletteSelectionTrigger)?

    let environment: CommandPaletteEnvironment
    private let presentation: CommandPalettePanel
    private var eventMonitor: Any?

    weak var wmController: WMController?
    let focusSession: CommandPaletteFocusSession
    private let actionExecutor: CommandPaletteActionExecutor
    private let menuSession: CommandPaletteMenuSession
    private var isProgrammaticDismiss = false
    private var isConfirmingClipboardClear = false
    private var clipboardPreviewGeneration = 0

    private enum DismissReason {
        case cancel
        case selection
        case deactivation
        case superseded
    }

    init(
        motionPolicy: MotionPolicy,
        environment: CommandPaletteEnvironment = .init(),
        ownedWindowRegistry: OwnedWindowRegistry = .shared
    ) {
        self.environment = environment
        menuSession = CommandPaletteMenuSession(environment: environment)
        let focusSession = CommandPaletteFocusSession(environment: environment)
        self.focusSession = focusSession
        actionExecutor = CommandPaletteActionExecutor(environment: environment, focusSession: focusSession)
        presentation = CommandPalettePanel(motionPolicy: motionPolicy, ownedWindowRegistry: ownedWindowRegistry)
        super.init()
    }

    func toggle(wmController: WMController) {
        if isVisible {
            dismiss(reason: .cancel)
        } else {
            show(wmController: wmController)
        }
    }

    func show(wmController: WMController) {
        actionExecutor.cancelPendingCommand()
        if isVisible {
            dismiss(reason: .superseded)
        }

        self.wmController = wmController

        focusSession.begin(wmController: wmController)
        windows = CommandPaletteSearch.buildWindowItems(from: wmController)
        menuItems = []
        isClipboardHistoryEnabled = environment.isClipboardHistoryEnabled(wmController)
        clipboardItems = isClipboardHistoryEnabled ? environment.clipboardItems(wmController) : []
        clipboardErrorText = nil
        commandItems = CommandPaletteSearch.buildCommandItems(from: wmController)
        menuSession.resetCache()
        isMenuLoading = false
        resetLauncherState(settings: wmController.settings)
        searchText = ""
        selectedItemID = nil
        menuSession.invalidate()

        if presentation.panel == nil {
            presentation.create(controller: self)
        }

        guard let panel = presentation.panel else { return }

        presentation.position(panel)
        isExpanded = false

        let preferredMode = wmController.settings.commandPaletteLastMode
        selectedMode = resolvedInitialMode(preferredMode)

        installEventMonitor()

        isVisible = true
        wmController.focusPolicyEngine.beginLease(owner: .commandPalette, reason: "command_palette", duration: nil)
        environment.observeClipboardItems(wmController) { [weak self] items in
            guard let self, self.isVisible else { return }
            self.clipboardItems = self.isClipboardHistoryEnabled ? items : []
        }
        updateSelectionAfterFilterChange()
        loadSelectedClipboardPreview()
        panel.orderFrontRegardless()
        panel.makeKey()
        presentation.reveal(panel)

        if selectedMode == .menu {
            loadMenuItemsIfNeeded()
        } else if isLauncherMode {
            expandResults()
            startLauncherSearch()
        }
    }

    func windowDidResignKey(_: Notification) {
        guard isVisible, !isProgrammaticDismiss, !isConfirmingClipboardClear else { return }
        dismiss(reason: .deactivation)
    }

    private func handleModeChange(from oldValue: CommandPaletteMode) {
        guard selectedMode != oldValue else { return }
        guard isModeAvailable(selectedMode) else {
            selectedMode = .windows
            return
        }
        invalidateLauncherSearch()
        launcherResultsFocused = false
        selectedItemID = nil
        expandResults()
        wmController?.settings.commandPaletteLastMode = selectedMode
        if selectedMode == .menu {
            loadMenuItemsIfNeeded()
        } else if selectedMode == .clipboard {
            refreshClipboardItems()
        } else if isLauncherMode {
            startLauncherSearch()
        }
        updateSelectionAfterFilterChange()
    }

    private func loadMenuItemsIfNeeded() {
        guard isVisible, selectedMode == .menu else { return }
        guard isMenuModeAvailable else {
            menuItems = []
            isMenuLoading = false
            return
        }
        menuSession.load(target: focusSession.menuFocusTarget, canStart: { [weak self] in
            self?.isVisible == true && self?.selectedMode == .menu
        }, canPublish: { [weak self] in
            self?.isVisible == true
        }, publish: { [weak self] publication in
            guard let self else { return }
            switch publication {
            case .loading:
                self.isMenuLoading = true
                self.menuItems = []
            case let .loaded(items):
                self.menuItems = items
                self.isMenuLoading = false
            }
        })
    }

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

    func dismissForLauncherSelection() {
        dismiss(reason: .selection)
    }

    func selectMode(_ mode: CommandPaletteMode) {
        selectedMode = mode
        expandResults()
    }

    func expandResults() {
        guard isVisible, !isExpanded, let panel = presentation.panel else { return }
        if presentation.animatesPresentation {
            withAnimation(.easeOut(duration: CommandPalettePanel.expansionDuration)) {
                isExpanded = true
            }
        } else {
            isExpanded = true
        }
        presentation.expand(panel)
    }

    func pasteClipboardItem(_ id: UUID, withoutFormatting: Bool = false) {
        guard let wmController, isClipboardHistoryEnabled else { return }
        let target = focusSession.clipboardPasteTarget()
        dismiss(reason: .selection)
        actionExecutor.perform(.pasteClipboard(wmController, id, target, withoutFormatting))
    }

    func setClipboardItemPinned(_ pinned: Bool, id: UUID) {
        guard let wmController else { return }
        Task { @MainActor [weak self, environment, wmController] in
            let items = await environment.setClipboardItemPinned(wmController, id, pinned)
            self?.clipboardErrorText = nil
            self?.clipboardItems = items
        }
    }

    func deleteClipboardItem(_ id: UUID) {
        guard let wmController else { return }
        Task { @MainActor [weak self, environment, wmController] in
            self?.clipboardItems = await environment.deleteClipboardItem(wmController, id)
            self?.clipboardErrorText = nil
        }
    }

    func clearClipboardHistory() {
        guard let wmController else { return }
        isConfirmingClipboardClear = true
        defer { isConfirmingClipboardClear = false }
        guard environment.confirmClearClipboardHistory() else { return }
        Task { @MainActor [weak self, environment, wmController] in
            do {
                self?.clipboardItems = try await environment.clearClipboardHistory(wmController)
                self?.clipboardErrorText = nil
            } catch {
                self?.clipboardErrorText = String(localized: "Could not clear clipboard history.")
            }
        }
    }

    private func loadSelectedClipboardPreview() {
        clipboardPreviewGeneration &+= 1
        let generation = clipboardPreviewGeneration
        clipboardPreview = nil
        clipboardPreviewImage = nil
        isClipboardPreviewLoading = false
        guard isVisible,
              selectedMode == .clipboard,
              let wmController,
              case let .clipboard(id)? = selectedItemID
        else {
            return
        }
        isClipboardPreviewLoading = true
        Task { @MainActor [weak self, environment, wmController] in
            let preview = await environment.clipboardItemPreview(wmController, id)
            guard let self,
                  self.isVisible,
                  self.clipboardPreviewGeneration == generation,
                  self.selectedItemID == .clipboard(id)
            else {
                return
            }
            self.clipboardPreview = preview
            if case let .image(data)? = preview {
                self.clipboardPreviewImage = NSImage(data: data)
            }
            self.isClipboardPreviewLoading = false
        }
    }
}

extension CommandPaletteController {
    private func dismiss(reason: DismissReason) {
        removeEventMonitor()
        invalidateLauncherSearch()
        isVisible = false
        clipboardPreviewGeneration &+= 1
        clipboardPreview = nil
        clipboardPreviewImage = nil
        isClipboardPreviewLoading = false
        isMenuLoading = false
        menuSession.invalidate()
        if let wmController {
            environment.observeClipboardItems(wmController, nil)
            wmController.focusPolicyEngine.endLease(owner: .commandPalette)
        }

        var defersContentClear = false
        if let panel = presentation.panel {
            presentation.rememberPlacement(panel, expanded: isExpanded)
            isProgrammaticDismiss = true
            if case .cancel = reason, presentation.animatesPresentation {
                defersContentClear = true
                withAnimation(.easeOut(duration: CommandPalettePanel.dismissalDuration)) {
                    isExpanded = false
                }
                presentation.dismiss(panel) { [weak self] in
                    self?.clearPresentedContent()
                }
            } else {
                panel.orderOut(nil)
                isExpanded = false
            }
            isProgrammaticDismiss = false
        }

        let restoreTarget = reason == .cancel ? focusSession.restoreFocusTarget : nil

        focusSession.clear()
        wmController = nil
        if !defersContentClear {
            clearPresentedContent()
        }

        if let restoreTarget {
            _ = focusSession.focus(target: restoreTarget)
        }
    }

    private func clearPresentedContent() {
        menuSession.resetCache()
        actionFeedbackText = nil
        searchText = ""
        selectedItemID = nil
        windows = []
        menuItems = []
        clipboardItems = []
        commandItems = []
        isClipboardHistoryEnabled = false
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isVisible else { return event }
            return handleKeyDown(event) ? nil : event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if [UInt16(36), 48, 49, 51, 53, 76, 123, 124, 125, 126].contains(event.keyCode),
           let inputClient = presentation.panel?.firstResponder as? NSTextInputClient,
           inputClient.hasMarkedText()
        {
            return false
        }
        let relevantModifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])

        if selectedMode == .windows,
           let markAction = CommandPalettePresentation.markAction(
               forKeyCode: event.keyCode,
               relevantModifiers: relevantModifiers
           )
        {
            switch markAction {
            case .set:
                setMarkOnFocusedWindow()
            case .remove:
                removeMarkFromSelectedWindow()
            }
            return true
        }

        if handleLauncherKeyDown(event, relevantModifiers: relevantModifiers) {
            return true
        }

        if let targetMode = CommandPalettePresentation.modeNavigationTarget(
            currentMode: selectedMode,
            isMenuModeAvailable: isMenuModeAvailable,
            keyCode: event.keyCode,
            relevantModifiers: relevantModifiers,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) {
            selectedMode = targetMode
            return true
        }

        switch event.keyCode {
        case 53:
            dismiss(reason: .cancel)
            return true
        case 126:
            guard !isLauncherMode else { return false }
            moveSelection(by: -1)
            return true
        case 125:
            guard !isLauncherMode else { return false }
            moveSelection(by: 1)
            return true
        default:
            guard let trigger = Self.selectionTrigger(
                forKeyCode: event.keyCode,
                modifierFlags: relevantModifiers
            ) else {
                return false
            }
            selectCurrent(trigger: trigger)
            return true
        }
    }

    private static func selectionTrigger(
        forKeyCode keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> CommandPaletteSelectionTrigger? {
        switch keyCode {
        case 36,
             76:
            return modifierFlags == .shift ? .alternate : .primary
        default:
            return nil
        }
    }
}

extension CommandPaletteController {
    func enableClipboardHistory() {
        guard let wmController else { return }
        environment.setClipboardHistoryEnabled(wmController, true)
        isClipboardHistoryEnabled = true
        refreshClipboardItems()
    }

    func refreshClipboardItems() {
        guard let wmController else {
            clipboardItems = []
            return
        }
        isClipboardHistoryEnabled = environment.isClipboardHistoryEnabled(wmController)
        clipboardItems = isClipboardHistoryEnabled ? environment.clipboardItems(wmController) : []
    }
}
