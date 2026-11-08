// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var menuHost: StatusMenuHost?

    private let hiddenBarController: HiddenBarController
    private let settings: SettingsStore
    private let cliManager: AppCLIManager?
    private let updateCoordinator: (any AppUpdateCoordinating)?
    private let openWelcome: ((SettingsStore, WMController) -> Void)?
    private let statusItemDefaults: UserDefaults
    private let recordingPulseKey = "omniwm.recordingPulse"
    private weak var controller: WMController?

    var settingsMenuModel: StatusMenuModel? {
        menuHost?.model
    }

    var statusButton: NSStatusBarButton? {
        statusItem?.button
    }

    init(
        settings: SettingsStore,
        controller: WMController,
        hiddenBarController: HiddenBarController,
        cliManager: AppCLIManager? = nil,
        updateCoordinator: (any AppUpdateCoordinating)? = nil,
        openWelcome: ((SettingsStore, WMController) -> Void)? = nil,
        statusItemDefaults: UserDefaults = .standard
    ) {
        self.hiddenBarController = hiddenBarController
        self.settings = settings
        self.cliManager = cliManager
        self.updateCoordinator = updateCoordinator
        self.openWelcome = openWelcome
        self.statusItemDefaults = statusItemDefaults
        self.controller = controller
        super.init()
    }

    func setup() {
        guard statusItem == nil else { return }
        installOwnedStatusItems()
    }

    static let maxStatusBarAppNameLength = 15

    private func installOwnedStatusItems() {
        guard statusItem == nil, let controller else { return }

        StatusItemPersistence.repairOwnedRestoreState(
            defaults: statusItemDefaults,
            screenFrames: NSScreen.screens.map(\.frame)
        )

        let ownedStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        StatusItemPersistence.configureMandatoryItem(ownedStatusItem, as: .main)
        statusItem = ownedStatusItem

        guard let button = statusButton else { return }
        button.image = OmniWMBrandMark.statusItemImage(pointSize: Self.statusIconPointSize)
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityElement(true)

        let model = StatusMenuModel(settings: settings, controller: controller)
        model.ipcMenuEnabled = cliManager != nil
        model.cliManager = cliManager
        model.updateCoordinator = updateCoordinator
        model.checkForUpdatesAction = { [weak self] in
            self?.updateCoordinator?.checkForUpdatesManually()
        }
        model.openWelcomeAction = openWelcome
        let host = StatusMenuHost(model: model, controller: controller)
        host.isExemptWindow = { [weak hiddenBarController] in
            hiddenBarController?.statusItems.ownsStatusItemWindow($0) == true
                || WorkspaceBarMenuButton.contains(NSApp.currentEvent, in: $0)
        }
        menuHost = host

        hiddenBarController.statusItems.bind(omniButton: button)
        hiddenBarController.setup()
        refreshWorkspaces()
    }

    enum StatusItemClickRoute {
        case hiddenIconsBar
        case menu
    }

    nonisolated static func clickRoute(isRightClick: Bool, optionHeld: Bool) -> StatusItemClickRoute {
        isRightClick || optionHeld ? .hiddenIconsBar : .menu
    }

    nonisolated static func labeledImagePosition(
        showIcon: Bool,
        hasStateIcon: Bool,
        showLayout: Bool = false
    ) -> NSControl.ImagePosition {
        showIcon || hasStateIcon || showLayout ? .imageLeft : .noImage
    }

    @objc private func handleClick(_ button: NSStatusBarButton) {
        routeClick(event: NSApp.currentEvent, anchor: button)
    }

    func routeClick(
        event: NSEvent?,
        anchor: NSView,
        edge: PopupAttachment.Edge = .below,
        monitorId: Monitor.ID? = nil
    ) {
        guard let window = anchor.window else { return }
        routeClick(
            route: Self.clickRoute(
                isRightClick: event?.type == .rightMouseUp,
                optionHeld: event?.modifierFlags.contains(.option) == true
            ),
            anchorFrame: window.convertToScreen(anchor.convert(anchor.bounds, to: nil)),
            screen: window.screen,
            edge: edge,
            monitorId: monitorId
        )
    }

    func routeClick(
        route: StatusItemClickRoute,
        anchorFrame: CGRect,
        screen: NSScreen?,
        edge: PopupAttachment.Edge,
        monitorId: Monitor.ID?
    ) {
        switch route {
        case .hiddenIconsBar:
            controller?.toggleHiddenBarPanel(
                on: monitorId,
                attachment: PopupAttachment(sourceFrame: anchorFrame, edge: edge)
            )
        case .menu:
            hiddenBarController.dismissPanel()
            menuHost?.toggle(anchorFrame: anchorFrame, screen: screen, edge: edge)
        }
    }

    func dismissPanel() {
        menuHost?.dismiss()
    }

    func openSettings(section: SettingsSection, anchor: String? = nil) {
        guard let controller else { return }
        SettingsWindowController.shared.show(
            settings: settings,
            controller: controller,
            updateCoordinator: updateCoordinator,
            section: section,
            anchor: anchor
        )
    }

    func handleTraceCaptureStateChange() {
        refreshWorkspaces()
    }

    private func updateButtonAppearance(
        _ button: NSStatusBarButton,
        controller: WMController?,
        summary: WMController.StatusBarWorkspaceSummary?,
        hasStateIcon: Bool
    ) {
        button.wantsLayer = true
        button.contentTintColor = nil
        let profile = controller?.traceCaptureStatus.profile
        if profile == .problem {
            applyRecordingPulse(to: button, animationsEnabled: controller?.motionPolicy.animationsEnabled != false)
        } else {
            button.layer?.removeAnimation(forKey: recordingPulseKey)
            button.layer?.opacity = 1
        }
        let layout = settings.statusBar.showLayout ? summary?.layout : nil
        if profile == .problem {
            button.image = NSImage(
                systemSymbolName: "record.circle.fill",
                accessibilityDescription: String(localized: "OmniWM, recording diagnostics")
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            button.image?.isTemplate = false
            button.toolTip = String(localized: "OmniWM — recording diagnostics (auto-stops in 10 min)")
        } else if profile == .performance {
            button.image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.67percent",
                accessibilityDescription: String(localized: "OmniWM, measuring performance")
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
            button.image?.isTemplate = false
            button.toolTip = String(localized: "OmniWM — measuring performance (auto-stops in 10 min)")
        } else if controller?.isSecureInputIndicated == true {
            button.image = OmniWMBrandMark.secureInputStatusImage(
                pointSize: Self.statusIconPointSize,
                tint: .labelColor
            )
            button.image?.accessibilityDescription = String(localized: "OmniWM, Secure Input is on")
            button.toolTip = String(localized: "Secure Input is on: Option shortcuts are paused")
        } else if let kind = controller?.keyboardModeKind, kind != .normal {
            button.image = Self.keyboardModeStatusImage(kind)
            button.toolTip = Self.keyboardModeToolTip(kind)
        } else if let layout {
            button.image = settings.statusBar.showIcon ? Self.brandedLayoutImage(layout) : Self.layoutGlyph(layout)
            button.toolTip = Self.layoutDisplayName(layout)
        } else {
            button.image = OmniWMBrandMark.statusItemImage(pointSize: Self.statusIconPointSize)
            button.toolTip = nil
        }
        if hasStateIcon, let layout {
            button.image = Self.statusButtonImage(icon: button.image, layout: layout)
        }
        updateButtonAccessibility(button, controller: controller, summary: summary)
    }

    private func applyRecordingPulse(to button: NSStatusBarButton, animationsEnabled: Bool) {
        guard animationsEnabled else {
            button.layer?.removeAnimation(forKey: recordingPulseKey)
            button.layer?.opacity = 1
            return
        }
        guard button.layer?.animation(forKey: recordingPulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(pulse, forKey: recordingPulseKey)
    }

    static func truncatedStatusBarAppName(_ appName: String) -> String {
        guard appName.count > maxStatusBarAppNameLength else { return appName }
        return String(appName.prefix(maxStatusBarAppNameLength)) + "\u{2026}"
    }

    private func updateButtonAccessibility(
        _ button: NSStatusBarButton,
        controller: WMController?,
        summary: WMController.StatusBarWorkspaceSummary?
    ) {
        let workspaceLabel = settings.statusBar.showWorkspaceName ? summary.map {
            settings.statusBar.useWorkspaceId ? $0.workspaceRawName : $0.workspaceLabel
        } : nil
        let focusedAppName = settings.statusBar.showWorkspaceName && settings.statusBar.showAppNames
            ? summary?.focusedAppName : nil
        button.setAccessibilityLabel("OmniWM")
        button.setAccessibilityValue(
            Self.statusButtonAccessibilityValue(
                workspaceLabel: workspaceLabel,
                focusedAppName: focusedAppName,
                isRecording: controller?.isTraceCaptureActive == true,
                isSecureInputActive: controller?.isSecureInputIndicated == true,
                layout: settings.statusBar.showLayout ? summary?.layout : nil
            )
        )
        button.setAccessibilityHelp(String(localized: "Press to open OmniWM controls."))
    }

    func refreshWorkspaces() {
        guard let button = statusButton else { return }

        let controller = controller
        let summary = settings.statusBar.showWorkspaceName || settings.statusBar.showLayout
            ? controller?.activeStatusBarWorkspaceSummary()
            : nil
        let modeTitle = Self.keyboardModeTitle(controller?.keyboardModeKind ?? .normal)
        let hasStateIcon = controller?.traceCaptureStatus.profile != nil || controller?.isSecureInputIndicated == true
            || modeTitle != nil
        updateButtonAppearance(button, controller: controller, summary: summary, hasStateIcon: hasStateIcon)

        guard let summary else {
            button.title = modeTitle.map { " \($0)" } ?? ""
            button.imagePosition = modeTitle == nil ? .imageOnly : .imageLeft
            return
        }

        let workspaceLabel = settings.statusBar.showWorkspaceName
            ? (settings.statusBar.useWorkspaceId ? summary.workspaceRawName : summary.workspaceLabel) : nil
        let focusedAppName = settings.statusBar.showWorkspaceName && settings.statusBar.showAppNames
            ? summary.focusedAppName : nil
        let title = Self.statusButtonTitle(
            workspaceLabel: workspaceLabel,
            focusedAppName: focusedAppName,
            modeTitle: modeTitle
        )
        button.title = title
        button.imagePosition = Self.labeledImagePosition(
            showIcon: settings.statusBar.showIcon,
            hasStateIcon: hasStateIcon,
            showLayout: settings.statusBar.showLayout
        )
    }

    func cleanup() {
        cleanupOwnedStatusItems()
    }

    private func cleanupOwnedStatusItems() {
        dismissPanel()
        menuHost = nil
        hiddenBarController.cleanup()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
}
