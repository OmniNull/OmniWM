// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
import Foundation
import OmniWMIPC

enum HotkeyVisibility: String {
    case normal
    case advanced
    case unassignable
}

struct ActionSpec: Equatable {
    let id: String
    let command: HotkeyCommand
    let title: String
    let localizedTitle: String
    let keywords: [String]
    let category: HotkeyCategory
    let visibility: HotkeyVisibility
    let layoutCompatibility: LayoutCompatibility
    let defaultBinding: KeyBinding
    let ipcCommandName: IPCCommandName?

    var ipcDescriptor: IPCCommandDescriptor? {
        ipcCommandName.flatMap(IPCAutomationManifest.commandDescriptor(for:))
    }

    var searchTerms: [String] {
        ActionCatalog.uniqueTerms(
            [
                localizedTitle,
                title,
                id,
                layoutCompatibility.localizedDisplayName,
                layoutCompatibility.rawValue,
                category.localizedDisplayName,
                category.rawValue
            ]
                + keywords
                + (ipcDescriptor.map { [$0.path] + $0.commandWords } ?? [])
        )
    }
}

enum ActionCatalog {
    private static let searchLocale = Locale(identifier: Bundle.module.preferredLocalizations.first ?? Locale.current
        .identifier)
    static let workspaceSlotRange = 1 ... 9

    static let digitCodes: [UInt32] = [
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
        UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
    ]

    private static let specs: [ActionSpec] = buildSpecs()
    private static let specsByID = Dictionary(
        uniqueKeysWithValues: specs.map { ($0.id, $0) }
    )
    private static let specsByCommand = Dictionary(
        specs.map { ($0.command, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    private static let normalizedSearchTermsByID = Dictionary(
        uniqueKeysWithValues: specs.map { ($0.id, $0.searchTerms.map(normalizedSearchTerm)) }
    )

    static func allSpecs() -> [ActionSpec] {
        specs
    }

    static func spec(for id: String) -> ActionSpec? {
        specsByID[id] ?? dynamicSpec(for: id)
    }

    static func spec(for command: HotkeyCommand) -> ActionSpec? {
        switch command {
        case let .shellToggle(name): shellToggleSpec(name: name)
        case let .openApp(bundleID): openAppSpec(bundleID: bundleID)
        case let .shellAppOpen(id): shellAppSpec(appID: id)
        case let .shellAppNewWindow(id): shellAppSpec(appID: id, newWindow: true)
        default: specsByCommand[command] ?? workspaceNumberSpec(for: command)
        }
    }

    static func dynamicSpec(for id: String) -> ActionSpec? {
        workspaceNumberSpec(for: id) ?? shellToggleSpec(for: id) ?? openAppSpec(for: id) ?? shellAppSpec(for: id)
    }

    static func normalizedSearchTerms(for id: String) -> [String]? {
        normalizedSearchTermsByID[id] ?? dynamicSpec(for: id)?.searchTerms.map(normalizedSearchTerm)
    }

    static func title(for command: HotkeyCommand) -> String? {
        spec(for: command)?.title
    }

    static func localizedTitle(for command: HotkeyCommand) -> String? {
        spec(for: command)?.localizedTitle
    }

    static func layoutCompatibility(for command: HotkeyCommand) -> LayoutCompatibility? {
        if case .openApp = command { return compatibility(for: command) }
        return spec(for: command)?.layoutCompatibility
    }

    static func category(for id: String) -> HotkeyCategory? {
        spec(for: id)?.category
    }

    static func visibility(for id: String) -> HotkeyVisibility? {
        spec(for: id)?.visibility
    }

    static func defaultHotkeyBindings() -> [HotkeyBinding] {
        specs.filter { $0.visibility != .unassignable }.map { spec in
            HotkeyBinding(
                id: spec.id,
                command: spec.command,
                binding: spec.defaultBinding
            )
        }
    }

    static func uniqueTerms(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { raw in
            let normalized = normalizedSearchTerm(raw)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return raw
        }
    }

    static func normalizedSearchTerm(_ value: String) -> String {
        value
            .lowercased(with: searchLocale)
            .folding(options: .diacriticInsensitive, locale: searchLocale)
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func canonicalSourceTitle(for resource: LocalizedStringResource) -> String {
        String(
            localized: resource.defaultValue,
            table: "CanonicalCommandSource",
            bundle: .module,
            locale: Locale(identifier: "en")
        )
    }

    private static func buildSpecs() -> [ActionSpec] {
        var specs: [ActionSpec] = []

        appendScratchpadBindings(&specs)
        appendWorkspaceNumberBindings(&specs)
        appendWorkspaceSlotBindings(&specs)
        appendWorkspaceHistoryBinding(&specs)
        appendWorkspaceCycleBindings(&specs)
        appendDirectionalFocusBindings(&specs)
        appendFocusHistoryBinding(&specs)
        appendTraversalFocusBindings(&specs)
        appendWindowFocusBindings(&specs)
        appendWorkspaceEdgeFocusBindings(&specs)
        appendCenteringBindings(&specs)
        appendWorkspaceTransferBindings(&specs)
        appendColumnWorkspaceBindings(&specs)
        appendDirectionalMoveBindings(&specs)
        appendWindowReorderBindings(&specs)
        appendColumnMembershipBindings(&specs)
        appendMonitorFocusBindings(&specs)
        appendWorkspaceMonitorBindings(&specs)
        appendWindowMonitorBindings(&specs)
        appendFullscreenBindings(&specs)
        appendDirectionalColumnBindings(&specs)
        appendColumnOrderBindings(&specs)
        appendColumnEdgeFocusBindings(&specs)
        appendColumnIndexFocusBindings(&specs)
        appendWindowIndexFocusBindings(&specs)
        appendColumnIndexMoveBindings(&specs)
        appendSizeCycleBindings(&specs)
        appendWindowSpanCycleBindings(&specs)
        appendContainerSpanBindings(&specs)
        appendSpanAdjustmentBindings(&specs)
        appendSplitStructureBindings(&specs)
        appendAxisResizeBindings(&specs)
        appendFocusedResizeBindings(&specs)
        appendPreselectionBindings(&specs)
        specs.append(contentsOf: IPCMediaCommand.allCases.map { $0.actionSpec() })
        specs.append(contentsOf: IPCKeyboardModeCommand.allCases.map { $0.actionSpec() })
        appendShellAppBindings(&specs)
        appendPresentationBindings(&specs)

        return specs
    }

    static func action(
        id: String,
        command: HotkeyCommand,
        category: HotkeyCategory,
        binding: KeyBinding,
        visibility: HotkeyVisibility = .normal,
        keywords: [String] = [],
        title: LocalizedStringResource? = nil
    ) -> ActionSpec {
        let resource = title ?? titleResource(for: command)
        let localizedTitle = String(localized: resource)
        let title = canonicalSourceTitle(for: resource)
        return ActionSpec(
            id: id,
            command: command,
            title: title,
            localizedTitle: localizedTitle,
            keywords: uniqueTerms(keywords + [title, id]),
            category: category,
            visibility: visibility,
            layoutCompatibility: compatibility(for: command),
            defaultBinding: binding,
            ipcCommandName: ipcCommandName(for: command)
        )
    }

    private static func compatibility(for command: HotkeyCommand) -> LayoutCompatibility {
        switch command {
        case .moveColumn(.up),
             .moveColumn(.down):
            .dwindle
        case .focus,
             .move,
             .moveColumn(.left),
             .moveColumn(.right),
             .monitorFocus,
             .fullscreen,
             .openCommandPalette,
             .openCommandPaletteMode,
             .raiseAllFloatingWindows,
             .toggleFloatingFocus,
             .rescueOffscreenWindows,
             .windowState,
             .openMenuAnywhere,
             .windowMark,
             .presentation,
             .media,
             .keyboardMode,
             .shellToggle,
             .shellAppOpen,
             .shellAppNewWindow,
             .openApp:
            .shared
        case let .focusNavigation(action):
            action.compatibility
        case let .windowMovement(action):
            action.compatibility
        case let .column(action):
            action.compatibility
        case let .workspace(action):
            action.compatibility
        case let .sizing(action):
            action.compatibility
        case let .dwindle(action):
            action.compatibility
        case let .scratchpad(action):
            action.compatibility
        }
    }

    private static func titleResource(for command: HotkeyCommand) -> LocalizedStringResource {
        switch command {
        case let .focus(direction): focusTitle(direction)
        case let .move(direction): moveTitle(direction)
        case let .monitorFocus(command): command.actionDisplayName()
        case let .fullscreen(command): command.actionDisplayName()
        case let .moveColumn(direction): moveContainerTitle(direction)
        case .openCommandPalette: LocalizedStringResource(
                "command.palette.toggle", defaultValue: "Toggle Command Palette", table: "Commands", bundle: .omniWM
            )
        case let .openCommandPaletteMode(mode): mode.actionDisplayName()
        case .raiseAllFloatingWindows: LocalizedStringResource(
                "command.floating.raiseAll", defaultValue: "Raise All Floating Windows", table: "Commands",
                bundle: .omniWM
            )
        case .toggleFloatingFocus: LocalizedStringResource(
                "command.floating.toggleFocus", defaultValue: "Toggle Floating/Tiled Focus", table: "Commands",
                bundle: .omniWM
            )
        case .rescueOffscreenWindows: LocalizedStringResource(
                "command.floating.rescueOffscreen", defaultValue: "Rescue Off-Screen Floating Windows",
                table: "Commands", bundle: .omniWM
            )
        case let .windowState(command): command.actionDisplayName()
        case .openMenuAnywhere: LocalizedStringResource(
                "command.menu.openAnywhere", defaultValue: "Open Menu Anywhere", table: "Commands", bundle: .omniWM
            )
        case let .windowMark(action): action.actionDisplayName()
        case let .presentation(command): command.actionDisplayName()
        case let .media(command): command.actionDisplayName()
        case let .keyboardMode(command): command.actionDisplayName()
        case let .shellToggle(name): LocalizedStringResource(
                "command.shell.toggle", defaultValue: "Toggle \(name)", table: "Commands", bundle: .omniWM
            )
        case .shellAppOpen: shellAppExampleTitle
        case .shellAppNewWindow: shellAppNewWindowExampleTitle
        case let .openApp(bundleID): LocalizedStringResource(
                "command.app.open", defaultValue: "Open \(appDisplayName(bundleID: bundleID))", table: "Commands",
                bundle: .omniWM
            )
        case let .focusNavigation(action): action.actionDisplayName()
        case let .windowMovement(action): action.actionDisplayName()
        case let .column(action): action.actionDisplayName()
        case let .workspace(action): action.actionDisplayName()
        case let .sizing(action): action.actionDisplayName()
        case let .dwindle(action): action.actionDisplayName()
        case let .scratchpad(action): action.actionDisplayName()
        }
    }
}

struct ActionSearchKeys {
    let localizedTitle: String
    let category: HotkeyCategory
    let layoutCompatibility: LayoutCompatibility
    let title: String
    let terms: [String]
    let categoryTerms: [String]
    let layoutTerms: [String]

    init(spec: ActionSpec, normalizedTerms: [String]) {
        localizedTitle = spec.localizedTitle
        category = spec.category
        layoutCompatibility = spec.layoutCompatibility
        title = ActionCatalog.normalizedSearchTerm(spec.localizedTitle)
        categoryTerms = [spec.category.rawValue, spec.category.localizedDisplayName]
            .map(ActionCatalog.normalizedSearchTerm)
        layoutTerms = [spec.layoutCompatibility.rawValue, spec.layoutCompatibility.localizedDisplayName]
            .map(ActionCatalog.normalizedSearchTerm)
        let excludedTerms = [title] + categoryTerms + layoutTerms
        terms = normalizedTerms.filter { !excludedTerms.contains($0) }
    }

    func matches(_ spec: ActionSpec) -> Bool {
        spec.localizedTitle == localizedTitle && spec.category == category
            && spec.layoutCompatibility == layoutCompatibility
    }
}

extension ActionCatalog {
    private static let searchKeysByID = Dictionary(
        uniqueKeysWithValues: specs.map { spec in
            (spec.id, ActionSearchKeys(spec: spec, normalizedTerms: normalizedSearchTermsByID[spec.id] ?? []))
        }
    )

    static func searchKeys(for spec: ActionSpec) -> ActionSearchKeys {
        if let keys = searchKeysByID[spec.id], keys.matches(spec) {
            return keys
        }
        return ActionSearchKeys(
            spec: spec,
            normalizedTerms: normalizedSearchTerms(for: spec.id) ?? spec.searchTerms.map(normalizedSearchTerm)
        )
    }
}

extension ActionCatalog {
    private static func focusTitle(_ direction: Direction) -> LocalizedStringResource {
        switch direction {
        case .left: LocalizedStringResource(
                "command.focus.left", defaultValue: "Focus Left", table: "Commands", bundle: .omniWM
            )
        case .right: LocalizedStringResource(
                "command.focus.right", defaultValue: "Focus Right", table: "Commands", bundle: .omniWM
            )
        case .up: LocalizedStringResource(
                "command.focus.up", defaultValue: "Focus Up", table: "Commands", bundle: .omniWM
            )
        case .down: LocalizedStringResource(
                "command.focus.down", defaultValue: "Focus Down", table: "Commands", bundle: .omniWM
            )
        }
    }

    private static func moveTitle(_ direction: Direction) -> LocalizedStringResource {
        switch direction {
        case .left: LocalizedStringResource(
                "command.move.left", defaultValue: "Move Left", table: "Commands", bundle: .omniWM
            )
        case .right: LocalizedStringResource(
                "command.move.right", defaultValue: "Move Right", table: "Commands", bundle: .omniWM
            )
        case .up: LocalizedStringResource(
                "command.move.up", defaultValue: "Move Up", table: "Commands", bundle: .omniWM
            )
        case .down: LocalizedStringResource(
                "command.move.down", defaultValue: "Move Down", table: "Commands", bundle: .omniWM
            )
        }
    }

    private static func moveContainerTitle(_ direction: Direction) -> LocalizedStringResource {
        switch direction {
        case .left: LocalizedStringResource(
                "command.moveContainer.left", defaultValue: "Move Container Left", table: "Commands", bundle: .omniWM
            )
        case .right: LocalizedStringResource(
                "command.moveContainer.right", defaultValue: "Move Container Right", table: "Commands", bundle: .omniWM
            )
        case .up: LocalizedStringResource(
                "command.moveContainer.up", defaultValue: "Move Container Up", table: "Commands", bundle: .omniWM
            )
        case .down: LocalizedStringResource(
                "command.moveContainer.down", defaultValue: "Move Container Down", table: "Commands", bundle: .omniWM
            )
        }
    }
}

extension LocalizedStringResource.BundleDescription {
    static var omniWM: Self {
        .atURL(Bundle.module.bundleURL)
    }
}
