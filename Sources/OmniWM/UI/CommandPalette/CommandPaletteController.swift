// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation

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
        didSet {
            shellRowCache.removeAll(keepingCapacity: true)
            filterInputDidChange()
        }
    }

    private(set) var menuItems: [MenuItemModel] = [] {
        didSet {
            shellMenuRowCache.removeAll(keepingCapacity: true)
            filterInputDidChange()
        }
    }

    private(set) var isMenuLoading = false
    var clipboardItems: [ClipboardPaletteItem] = [] {
        didSet {
            shellClipboardRowCache.removeAll(keepingCapacity: true)
            filterInputDidChange()
        }
    }

    private(set) var commandItems: [CommandPaletteCommandItem] = [] {
        didSet {
            shellCommandRowCache.removeAll(keepingCapacity: true)
            filterInputDidChange()
        }
    }

    private(set) var filteredItems = CommandPaletteFilteredItems.windows([])

    var isClipboardHistoryEnabled = false
    var clipboardPreview: ClipboardPalettePreview?
    var clipboardPreviewImage: NSImage?
    var isClipboardPreviewLoading = false
    var clipboardErrorText: String?
    var selectionScrollRequest = 0

    var applicationSections: [LauncherSection<LauncherApplicationResult>] = [] {
        didSet { shellUnifiedRowCache.removeAll(keepingCapacity: true) }
    }

    var launcherFilter: LauncherFilter = .all
    var savedApplicationIdentifiers: [UUID: String] = [:]
    var fileSections: [LauncherSection<LauncherFileResult>] = [] {
        didSet { shellUnifiedRowCache.removeAll(keepingCapacity: true) }
    }

    var applicationChips: [LauncherChip] = []
    var fileChips: [LauncherChip] = []
    var selectedApplicationChip: LauncherChip?
    var selectedFileChip: LauncherChip?
    var applicationViewStyle: LauncherViewStyle = .grid
    var fileViewStyle: LauncherViewStyle = .grid
    var isApplicationLoading = false
    var isFileLoading = false
    @ObservationIgnored var launcherColumnCount = 1
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
    @ObservationIgnored var shellObservationGeneration = 0
    @ObservationIgnored var shellRowCache: [WindowToken: ShellCommandPaletteData.Row] = [:]
    @ObservationIgnored var shellCommandRowCache: [String: ShellCommandPaletteData.Row] = [:]
    @ObservationIgnored var shellMenuRowCache: [UUID: ShellCommandPaletteData.Row] = [:]
    @ObservationIgnored var shellClipboardRowCache: [UUID: ShellCommandPaletteData.Row] = [:]
    @ObservationIgnored let nativeMenu = CommandPaletteNativeMenu()
    @ObservationIgnored var shellPreviewCache: CommandPaletteShellPreviewCache?
    @ObservationIgnored var shellUnifiedRowCache: [CommandPaletteSelectionID: ShellCommandPaletteData.Row] = [:]
    @ObservationIgnored var shellRowKeys: [CommandPaletteSelectionID: String] = [:]
    @ObservationIgnored var shellUnifiedKeySequence = 0
    @ObservationIgnored var shellSelectionIndex: [String: CommandPaletteSelectionID] = [:]
    @ObservationIgnored var shellImageCache: [CommandPaletteSelectionID: CommandPaletteShellImage] = [:]
    @ObservationIgnored var shellImageSequence = 0
    @ObservationIgnored var shellFileIconRequests: [CommandPaletteShellFileIconRequest] = []
    @ObservationIgnored var shellHeaderCache: CommandPaletteShellHeader?
    @ObservationIgnored var shellLauncherRowCache: [CommandPaletteSelectionID: CommandPaletteShellLauncherRow] = [:]
    @ObservationIgnored var shellGridKeys: [String: String] = [:]
    @ObservationIgnored var shellLauncherToolbarCache: CommandPaletteShellLauncherToolbar?
    @ObservationIgnored var shellFilePreviewCache: CommandPaletteShellFilePreviewCache?
    @ObservationIgnored var launcherQuickLook: ShellDesktopPlatform.Presentation?
    @ObservationIgnored weak var deferredShellSource: WorkspaceBarManager?

    enum DismissReason {
        case cancel
        case selection
        case deactivation
        case superseded
        case failure
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

        guard let panel = preparePresentation(wmController) else { return }
        presentation.shell?.beginSession()

        presentation.position(panel)
        isExpanded = false

        if !isUnifiedSearch {
            selectInitialMode(mode, settings: wmController.settings)
        }

        installEventMonitor()
        syncLauncherPaths()

        isVisible = true
        claimPaletteInput(wmController)
        environment.observeClipboardItems(wmController) { [weak self] items in
            guard let self, self.isVisible else { return }
            self.isClipboardHistoryEnabled = self.environment.isClipboardHistoryEnabled(wmController)
            self.clipboardItems = self.isClipboardHistoryEnabled ? items : []
        }
        updateSelectionAfterFilterChange()
        loadSelectedClipboardPreview()
        syncShellContent()
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

    private func preparePresentation(_ wmController: WMController) -> NSPanel? {
        if presentation.panel == nil {
            presentation.create(controller: self)
        }
        guard presentation.prepareShell(from: wmController.workspaceBarManager, controller: self, checksFiles: false)
        else {
            dismiss(reason: .failure)
            return nil
        }
        return presentation.panel
    }

    func activateSelectedMode() {
        guard isModeAvailable(selectedMode) else {
            selectedMode = .windows
            return
        }
        closeLauncherQuickLook()
        presentation.shell?.beginSession()
        finishShellFileIconDemand([])
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
        if isVisible { syncShellContent() }
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
}

extension CommandPaletteController {
    func dismissForLauncherSelection() {
        dismiss(reason: .selection)
    }

    func selectMode(_ mode: CommandPaletteMode) {
        selectedMode = mode
        expandResults()
    }

    func expandResults() {
        guard isVisible, !isExpanded, let panel = presentation.panel else { return }
        isExpanded = true
        presentation.expand(panel)
    }

    func dismiss(reason: DismissReason) {
        let wasVisible = isVisible
        if reason == .failure { deferredShellSource = nil }
        nativeMenu.cancel()
        shellPreviewCache = nil
        shellImageCache.removeAll(keepingCapacity: true)
        finishShellFileIconDemand([])
        removeEventMonitor()
        invalidateLauncherSearch()
        isVisible = false
        closeLauncherQuickLook()
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
        if let shell = presentation.shell {
            shell.publish(shellData(size: presentation.shellLayoutSize(expanded: false)))
            shell.setVisible(false)
        }

        var defersContentClear = false
        if let panel = presentation.panel {
            presentation.rememberPlacement(panel, expanded: isExpanded)
            isProgrammaticDismiss = true
            if case .cancel = reason, presentation.animatesPresentation {
                defersContentClear = true
                isExpanded = false
                presentation.dismiss(panel) { [weak self] in
                    self?.clearPresentedContent()
                }
            } else {
                panel.orderOut(nil)
                isExpanded = false
            }
            isProgrammaticDismiss = false
        }

        let restoresFocus = reason == .cancel || (reason == .failure && wasVisible)
        let restoreTarget = restoresFocus ? focusSession.restoreFocusTarget : nil

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
        shellRowKeys.removeAll(keepingCapacity: true)
        shellGridKeys.removeAll(keepingCapacity: true)
        clearShellLauncherRows()
        isClipboardHistoryEnabled = false
        if let source = deferredShellSource {
            prewarmShell(from: source)
        }
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, isVisible else { return event }
            if event.type == .flagsChanged {
                syncLauncherPaths(event.modifierFlags)
                return event
            }
            guard !isPresentingModalPrompt, !nativeMenu.isTracking,
                  launcherQuickLook == nil || event.window === presentation.panel
            else { return event }
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

extension CommandPaletteController {
    func windowDidChangeBackingProperties(_: Notification) {
        guard let panel = presentation.panel else { return }
        presentation.backingPropertiesChanged(panel)
        if isVisible { publishShellData() }
    }

    func windowDidResize(_: Notification) {
        guard isVisible, let panel = presentation.panel else { return }
        presentation.liveResized(panel, expanded: isExpanded)
        publishShellData()
    }

    func windowDidResignKey(_: Notification) {
        guard isVisible, !isProgrammaticDismiss, !isConfirmingClipboardClear, !isPresentingModalPrompt,
              !nativeMenu.isTracking, launcherQuickLook == nil
        else {
            return
        }
        dismiss(reason: .deactivation)
    }
}
