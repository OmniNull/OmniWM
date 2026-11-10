// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
            if isVisible, isUnifiedSearch {
                unifiedSearchTextDidChange(from: oldValue)
            } else if isVisible, isLauncherMode {
                launcherSearchTextDidChange(from: oldValue)
            } else {
                if selectedMode == .windows, searchText != oldValue {
                    selectedItemID = nil
                }
                filterInputDidChange()
            }
            if !searchText.isEmpty {
                expandResults()
            }
        }
    }

    var isUnifiedSearch = false
    var unifiedSearchedModes: [CommandPaletteMode] = []
    var unifiedResults = UnifiedSearchResults()
    var unifiedLearnedPicks: [UnifiedSearchPickKey] = []
    var unifiedSelectionFollowsFirstRow = true
    var unifiedPendingSearches: Set<CommandPaletteMode> = []
    var pendingUnifiedSelection: PendingUnifiedSelection?

    var selectedMode: CommandPaletteMode = .windows {
        didSet { if selectedMode != oldValue { activateSelectedMode() } }
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
        didSet { filterInputDidChange() }
    }

    private(set) var menuItems: [MenuItemModel] = [] {
        didSet { filterInputDidChange() }
    }

    private(set) var isMenuLoading = false
    var clipboardItems: [ClipboardPaletteItem] = [] {
        didSet { filterInputDidChange() }
    }

    private(set) var commandItems: [CommandPaletteCommandItem] = [] {
        didSet { filterInputDidChange() }
    }

    private(set) var filteredItems = CommandPaletteFilteredItems.windows([])

    var isClipboardHistoryEnabled = false
    var clipboardPreview: ClipboardPalettePreview?
    var clipboardPreviewImage: NSImage?
    var isClipboardPreviewLoading = false
    var clipboardErrorText: String?
    var selectionScrollRequest = 0

    var applicationSections: [LauncherSection<LauncherApplicationResult>] = []
    var launcherFilter: LauncherFilter = .all
    var savedApplicationIdentifiers: [UUID: String] = [:]
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
    let presentation: CommandPalettePanel
    private var eventMonitor: Any?

    weak var wmController: WMController?
    let focusSession: CommandPaletteFocusSession
    let actionExecutor: CommandPaletteActionExecutor
    private let menuSession: CommandPaletteMenuSession
    private var isProgrammaticDismiss = false
    var isConfirmingClipboardClear = false
    var isPresentingModalPrompt = false
    var clipboardPreviewGeneration = 0

    enum DismissReason {
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

    var isCurrentWorkspaceEmpty: Bool {
        guard let wmController, let workspaceId = focusSession.workspaceId else { return false }
        return wmController.workspaceManager.windowCount(in: workspaceId) == 0
    }

    func toggle(wmController: WMController, mode: CommandPaletteMode? = nil) {
        guard isVisible else {
            show(wmController: wmController, mode: mode)
            return
        }
        if let mode, isUnifiedSearch {
            leaveUnifiedSearch(to: mode)
        } else if let mode, mode != selectedMode {
            selectedMode = mode
        } else {
            dismiss(reason: .cancel)
        }
    }

    func show(wmController: WMController, mode: CommandPaletteMode? = nil) {
        actionExecutor.cancelPendingCommand()
        if isVisible {
            dismiss(reason: .superseded)
        }

        self.wmController = wmController

        focusSession.begin(wmController: wmController)
        windows = CommandPaletteSearch.buildWindowItems(
            from: wmController, focusedWindow: focusSession.restoreFocusTarget
        )
        menuItems = []
        isClipboardHistoryEnabled = environment.isClipboardHistoryEnabled(wmController)
        clipboardItems = isClipboardHistoryEnabled ? environment.clipboardItems(wmController) : []
        clipboardErrorText = nil
        commandItems = CommandPaletteSearch.buildCommandItems(from: wmController)
        menuSession.resetCache()
        isMenuLoading = false
        resetLauncherState(settings: wmController.settings)
        beginUnifiedSearchSession(requestedMode: mode, settings: wmController.settings)
        searchText = ""
        selectedItemID = nil
        menuSession.invalidate()

        if presentation.panel == nil {
            presentation.create(controller: self)
        }

        guard let panel = presentation.panel else { return }

        presentation.position(panel)
        isExpanded = false

        if !isUnifiedSearch {
            selectInitialMode(mode, settings: wmController.settings)
        }

        installEventMonitor()

        isVisible = true
        claimPaletteInput(wmController)
        environment.observeClipboardItems(wmController) { [weak self] items in
            guard let self, self.isVisible else { return }
            self.isClipboardHistoryEnabled = self.environment.isClipboardHistoryEnabled(wmController)
            self.clipboardItems = self.isClipboardHistoryEnabled ? items : []
        }
        updateSelectionAfterFilterChange()
        loadSelectedClipboardPreview()
        panel.orderFrontRegardless()
        panel.makeKey()
        presentation.reveal(panel)

        if isUnifiedSearch || selectedMode == .menu {
            loadMenuItemsIfNeeded()
        } else if isLauncherMode {
            expandResults()
            startLauncherSearch()
        }
    }

    func windowDidResignKey(_: Notification) {
        guard isVisible, !isProgrammaticDismiss, !isConfirmingClipboardClear, !isPresentingModalPrompt else {
            return
        }
        dismiss(reason: .deactivation)
    }

    func activateSelectedMode() {
        guard isModeAvailable(selectedMode) else {
            selectedMode = .windows
            return
        }
        refreshFilteredItems()
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

    func filterInputDidChange() {
        if isUnifiedSearch {
            refreshUnifiedResults()
        } else {
            refreshFilteredItems()
        }
        updateSelectionAfterFilterChange()
    }

    private func refreshFilteredItems() {
        filteredItems = switch selectedMode {
        case .windows:
            .windows(CommandPaletteSearch.filterWindowItems(windows, query: searchText))
        case .menu:
            .menu(CommandPaletteSearch.filterMenuItems(menuItems, query: searchText))
        case .clipboard:
            .clipboard(CommandPaletteSearch.filterClipboardItems(clipboardItems, query: searchText))
        case .commands:
            .commands(CommandPaletteSearch.filterCommandItems(commandItems, query: searchText))
        case .applications,
             .files:
            .launcher
        }
    }

    private func loadMenuItemsIfNeeded() {
        guard isVisible, isMenuSearched else { return }
        guard isMenuModeAvailable else {
            menuItems = []
            isMenuLoading = false
            return
        }
        menuSession.load(target: focusSession.menuFocusTarget, canStart: { [weak self] in
            self?.isVisible == true && self?.isMenuSearched == true
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
}

extension CommandPaletteController {
    func dismiss(reason: DismissReason) {
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
            releasePaletteInput(wmController)
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

    private func claimPaletteInput(_ wmController: WMController) {
        wmController.focusPolicyEngine.beginLease(owner: .commandPalette, reason: "command_palette", duration: nil)
        reservePaletteShortcuts(wmController)
        environment.observeKeyboardLayout { [weak self] in
            guard let self, self.isVisible, let wmController = self.wmController else { return }
            self.reservePaletteShortcuts(wmController)
        }
    }

    private func reservePaletteShortcuts(_ wmController: WMController) {
        wmController.hotkeys.setPaletteShortcutChords(environment.paletteShortcuts().chords.map(\.binding))
    }

    private func releasePaletteInput(_ wmController: WMController) {
        environment.observeKeyboardLayout(nil)
        wmController.focusPolicyEngine.endLease(owner: .commandPalette)
        wmController.hotkeys.setPaletteShortcutChords([])
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
            guard let self, isVisible, !isPresentingModalPrompt else { return event }
            return handleKeyDown(event) ? nil : event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func restoreKeyWindowAfterModalPrompt() {
        if isVisible {
            presentation.panel?.makeKey()
        }
    }
}
