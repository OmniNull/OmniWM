// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Observation

extension CommandPaletteController {
    var drawsWithShell: Bool {
        guard presentation.shell != nil, !isUnifiedSearch else { return false }
        switch selectedMode {
        case .windows,
             .commands:
            return true
        case .menu,
             .clipboard,
             .applications,
             .files:
            return false
        }
    }

    var emptyStateSymbol: String {
        switch selectedMode {
        case .windows: "macwindow.on.rectangle"
        case .menu: isMenuModeAvailable ? "text.magnifyingglass" : "menubar.rectangle"
        case .clipboard: "clipboard"
        case .commands: "command"
        case .applications: "app.fill"
        case .files: "folder"
        }
    }

    var emptyStateText: String {
        switch selectedMode {
        case .windows:
            return searchText.isEmpty
                ? String(localized: "No windows available")
                : String(localized: "No windows found. Check the mark name or try a title, app, or workspace.")
        case .menu:
            if !isMenuModeAvailable {
                return menuStatusText
            }
            return searchText.isEmpty
                ? String(localized: "No menu items available") : String(localized: "No menu items found")
        case .clipboard:
            return searchText.isEmpty
                ? String(localized: "No clipboard items available") : String(localized: "No clipboard items found")
        case .commands:
            return searchText.isEmpty
                ? String(localized: "No commands available") : String(localized: "No commands found")
        case .applications:
            return String(localized: "No applications found")
        case .files:
            return String(localized: "No files found")
        }
    }

    func prewarmShell(host: ShellWidgetHost?) {
        guard !isVisible else {
            deferredShellHost = host
            return
        }
        deferredShellHost = nil
        if presentation.panel == nil {
            presentation.create(controller: self)
        }
        presentation.prepareShell(host: host, controller: self, checksFiles: true)
    }

    func syncShellContent() {
        presentation.showContent(shell: drawsWithShell, controller: self)
        publishShellData()
    }

    static func shellRowID(_ token: WindowToken) -> String {
        "window-\(token.pid)-\(token.windowId)"
    }

    func shellData(size: CGSize) -> ShellCommandPaletteData {
        var data = ShellCommandPaletteData()
        data.open = isVisible
        data.expanded = isExpanded
        data.width = Double(size.width)
        data.height = Double(size.height)
        data.mode = selectedMode.rawValue
        let header = shellHeader()
        data.modes = header.modes
        data.placeholder = header.placeholder
        data.query = searchText
        data.feedback = actionFeedbackText
        guard isVisible else { return data }
        data.actions = header.actions
        switch selectedMode {
        case .windows:
            windowRows(into: &data, limit: Float(size.height))
        case .commands:
            commandRows(into: &data, limit: Float(size.height))
        case .menu,
             .clipboard,
             .applications,
             .files:
            return data
        }
        if data.rows.isEmpty {
            data.state = "empty"
            data.emptyText = emptyStateText
            data.emptySymbol = emptyStateSymbol
        }
        return data
    }

    private func shellHeader() -> CommandPaletteShellHeader {
        let menuAvailable = isMenuModeAvailable
        if let cached = shellHeaderCache, cached.mode == selectedMode, cached.menuAvailable == menuAvailable {
            return cached
        }
        let header = CommandPaletteShellHeader(
            mode: selectedMode,
            menuAvailable: menuAvailable,
            modes: CommandPaletteMode.allCases.map { mode in
                ShellCommandPaletteData.Mode(
                    id: mode.rawValue,
                    title: mode.localizedDisplayName,
                    symbol: mode.symbolName,
                    shortcut: CommandPalettePresentation.modeHint(for: mode).shortcut,
                    selected: mode == selectedMode,
                    enabled: mode != .menu || menuAvailable
                )
            },
            placeholder: CommandPalettePresentation.searchPlaceholder(for: selectedMode),
            actions: selectedMode == .windows ? Self.windowActions : []
        )
        shellHeaderCache = header
        return header
    }

    private func windowRows(into data: inout ShellCommandPaletteData, limit: Float) {
        let items = filteredWindowItems
        let selectedToken: WindowToken? = if case let .window(token)? = selectedItemID { token } else { nil }
        var ids: [String] = []
        ids.reserveCapacity(items.count)
        var selectedIndex: Int?
        for (index, item) in items.enumerated() {
            ids.append(cachedShellRow(item).id)
            if item.id == selectedToken { selectedIndex = index }
        }
        let range = sliceRows(ids: ids, selectedIndex: selectedIndex, limit: limit, into: &data)
        let summonAvailable = isSummonRightAvailable
        for index in range {
            let item = items[index]
            var row = cachedShellRow(item)
            if index == selectedIndex {
                row.selected = true
                if summonAvailable, allowsWindowAlternateAction(item) {
                    let hint = CommandPalettePresentation.selectedWindowHint(isSummonRightAvailable: true)
                    row.hint = hint?.title
                    row.hintShortcut = hint?.shortcut
                }
            }
            data.rows.append(row)
        }
    }

    private func commandRows(into data: inout ShellCommandPaletteData, limit: Float) {
        let items = filteredCommandItems
        let grouped = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let selectedID: String? = if case let .command(id)? = selectedItemID { id } else { nil }
        var ids: [String] = []
        ids.reserveCapacity(items.count + (grouped ? Self.shellHeadings.count : 0))
        var selectedIndex: Int?
        for index in items.indices {
            if grouped, Self.startsCategory(items, at: index) {
                ids.append(Self.shellHeading(items[index].spec.category).id)
            }
            if items[index].isLayoutCompatible, items[index].id == selectedID { selectedIndex = ids.count }
            ids.append(items[index].id)
        }
        let range = sliceRows(ids: ids, selectedIndex: selectedIndex, limit: limit, into: &data)
        var position = 0
        for index in items.indices {
            guard position < range.upperBound else { break }
            if grouped, Self.startsCategory(items, at: index) {
                if range.contains(position) { data.rows.append(Self.shellHeading(items[index].spec.category)) }
                position += 1
            }
            if range.contains(position) {
                var row = cachedShellRow(items[index])
                if grouped { row.subtitle = "" }
                row.selected = position == selectedIndex
                data.rows.append(row)
            }
            position += 1
        }
    }

    private func sliceRows(
        ids: [String],
        selectedIndex: Int?,
        limit: Float,
        into data: inout ShellCommandPaletteData
    ) -> Range<Int> {
        let follows = presentation.shell?.revealPending(for: selectionScrollRequest) == true
        let slice = presentation.shell?.slice(ids: ids, selected: follows ? selectedIndex : nil, limit: limit)
            ?? CommandPaletteRowWindow.Slice(range: ids.indices, before: 0, after: 0)
        data.selected = selectedIndex.map { ids[$0] } ?? ""
        data.first = slice.range.lowerBound
        data.total = ids.count
        data.before = Double(slice.before)
        data.after = Double(slice.after)
        data.rows.reserveCapacity(slice.range.count)
        return slice.range
    }

    private func cachedShellRow(_ item: CommandPaletteWindowItem) -> ShellCommandPaletteData.Row {
        if let row = shellRowCache[item.id] { return row }
        let row = Self.shellRow(item)
        shellRowCache[item.id] = row
        return row
    }

    private func cachedShellRow(_ item: CommandPaletteCommandItem) -> ShellCommandPaletteData.Row {
        if let row = shellCommandRowCache[item.id] { return row }
        let row = Self.shellRow(item)
        shellCommandRowCache[item.id] = row
        return row
    }

    private static func startsCategory(_ items: [CommandPaletteCommandItem], at index: Int) -> Bool {
        index == items.startIndex || items[index].spec.category != items[index - 1].spec.category
    }

    private static let shellHeadings = Dictionary(
        uniqueKeysWithValues: HotkeyCategory.allCases.map { ($0, makeShellHeading($0)) }
    )

    private static func shellHeading(_ category: HotkeyCategory) -> ShellCommandPaletteData.Row {
        shellHeadings[category] ?? makeShellHeading(category)
    }

    private static func makeShellHeading(_ category: HotkeyCategory) -> ShellCommandPaletteData.Row {
        ShellCommandPaletteData.Row(
            id: "heading-" + category.rawValue,
            kind: .heading,
            title: category.localizedDisplayName,
            subtitle: "",
            icon: .init(app: nil, pid: nil, symbol: nil),
            badges: [],
            marks: [],
            hint: nil,
            hintShortcut: nil,
            selected: false,
            enabled: false
        )
    }

    private static func shellRow(_ item: CommandPaletteCommandItem) -> ShellCommandPaletteData.Row {
        ShellCommandPaletteData.Row(
            id: item.id,
            kind: .command,
            title: item.spec.localizedTitle,
            subtitle: item.spec.category.localizedDisplayName,
            icon: .init(app: nil, pid: nil, symbol: CommandPaletteMode.commands.symbolName),
            badges: [
                .init(
                    text: item.spec.layoutCompatibility.localizedDisplayName,
                    tone: item.isLayoutCompatible ? .neutral : .warning,
                    symbol: nil
                ),
                .init(text: item.shortcut, tone: item.hasShortcut ? .shortcut : .shortcutMuted, symbol: nil)
            ],
            marks: [],
            hint: nil,
            hintShortcut: nil,
            selected: false,
            enabled: item.isLayoutCompatible
        )
    }

    private static var windowActions: [ShellCommandPaletteData.Action] {
        [
            ShellCommandPaletteData.Action(
                id: "mark set",
                title: String(localized: "Mark selected window…"),
                symbol: "tag",
                shortcut: CommandPalettePresentation.setMarkShortcut
            ),
            ShellCommandPaletteData.Action(
                id: "mark remove",
                title: String(localized: "Remove mark…"),
                symbol: "tag.slash",
                shortcut: CommandPalettePresentation.removeMarkShortcut
            )
        ]
    }

    private static func shellRow(_ item: CommandPaletteWindowItem) -> ShellCommandPaletteData.Row {
        var badges: [ShellCommandPaletteData.Badge] = []
        if item.isAppHidden {
            badges.append(.init(text: String(localized: "App hidden"), tone: .danger, symbol: "eye.slash.fill"))
        }
        badges.append(.init(text: item.workspaceName, tone: .neutral, symbol: nil))
        return ShellCommandPaletteData.Row(
            id: shellRowID(item.id),
            kind: .window,
            title: item.title.isEmpty ? item.appName : item.title,
            subtitle: item.appName,
            icon: .init(
                app: item.bundleIdentifier,
                pid: item.hostedSymbol == nil ? item.id.pid : nil,
                symbol: item.hostedSymbol
            ),
            badges: badges,
            marks: item.markNames.map { .init(text: String(localized: "Mark: \($0)"), tone: .accent, symbol: nil) },
            hint: nil,
            hintShortcut: nil,
            selected: false,
            enabled: true
        )
    }

    func publishShellData() {
        guard let shell = presentation.shell else { return }
        guard isVisible, drawsWithShell else {
            shellObservationArmed = false
            return
        }
        let size = presentation.shellLayoutSize(expanded: isExpanded)
        guard !shellObservationArmed else {
            shell.publish(shellData(size: size), reveal: selectionScrollRequest)
            return
        }
        shellObservationArmed = true
        let data = withObservationTracking {
            shellData(size: size)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                shellObservationArmed = false
                publishShellData()
            }
        }
        shell.publish(data, reveal: selectionScrollRequest)
    }

    func performShellCommand(_ command: String) {
        guard isVisible else { return }
        let words = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = words.first else { return }
        let argument = words.count > 1 ? words[1] : ""
        switch verb {
        case "activate":
            activateShellRow(argument)
        case "mode":
            guard let mode = CommandPaletteMode(rawValue: argument), isModeAvailable(mode) else { return }
            selectMode(mode)
        case "mark":
            guard selectedMode == .windows else { return }
            if argument == "set" { setMarkOnSelectedWindow() } else if argument == "remove" {
                removeMarkFromSelectedWindow()
            }
        case "clear":
            searchText = ""
        default:
            return
        }
    }

    private func activateShellRow(_ id: String) {
        switch selectedMode {
        case .windows:
            guard let item = filteredWindowItems.first(where: { cachedShellRow($0).id == id }) else { return }
            selectedItemID = .window(item.id)
        case .commands:
            guard let item = filteredCommandItems.first(where: { $0.id == id }), item.isLayoutCompatible else {
                return
            }
            selectedItemID = .command(item.id)
        case .menu,
             .clipboard,
             .applications,
             .files:
            return
        }
        selectCurrent()
    }
}

extension CommandPaletteMode {
    var symbolName: String {
        switch self {
        case .windows: "macwindow.on.rectangle"
        case .menu: "menubar.rectangle"
        case .clipboard: "clipboard"
        case .commands: "command"
        case .applications: "square.grid.3x3"
        case .files: "folder"
        }
    }
}

struct CommandPaletteShellHeader {
    let mode: CommandPaletteMode
    let menuAvailable: Bool
    let modes: [ShellCommandPaletteData.Mode]
    let placeholder: String
    let actions: [ShellCommandPaletteData.Action]
}
