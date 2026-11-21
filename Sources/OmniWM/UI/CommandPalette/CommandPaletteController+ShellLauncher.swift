// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension CommandPaletteController {
    static let shellGridIconPoints: CGFloat = 75
    static let shellLauncherAddTarget = "launcher-add"

    static func launcherColumnCount(for mode: CommandPaletteMode, width: CGFloat, style: LauncherViewStyle) -> Int {
        guard style == .grid else { return 1 }
        let cap = mode == .files ? 5 : 7
        let availableWidth = max(0, width - 40)
        return min(cap, max(1, Int((availableWidth + 10) / 100)))
    }

    static func launcherSelection(_ selection: CommandPaletteSelectionID) -> LauncherSelection? {
        switch selection {
        case let .launcherEntry(id):
            LauncherSelection(sectionID: .saved, itemID: id.uuidString)
        case let .executable(path):
            LauncherSelection(sectionID: .executables, itemID: path)
        case let .application(sectionID, itemID),
             let .file(sectionID, itemID):
            LauncherSelection(sectionID: sectionID, itemID: itemID)
        default:
            nil
        }
    }

    func launcherRows(into data: inout ShellCommandPaletteData, size: CGSize) {
        let style = launcherViewStyle
        let previewVisible = selectedMode == .files && isLauncherPreviewVisible
        let width = previewVisible ? (size.width * Self.shellPreviewSplit).rounded(.down) : size.width
        let columns = Self.launcherColumnCount(for: selectedMode, width: width, style: style)
        if launcherColumnCount != columns { launcherColumnCount = columns }
        data.launcher = shellLauncherToolbar(columns: columns, style: style)
        let grid = style == .grid
        let layout = CommandPaletteLauncherLayout(
            grid: grid,
            columns: columns,
            limit: Float(size.height),
            points: grid ? Self.shellGridIconPoints : Self.shellIconPoints,
            scale: presentation.panel?.backingScaleFactor ?? 1,
            showsPaths: selectedMode == .files && launcherShowsPaths,
            current: selectedItemID,
            currentKey: selectedItemID.map(shellRowKey)
        )
        if selectedMode == .files {
            fileShellRows(into: &data, layout: layout)
            if previewVisible, data.state == "results" {
                data.preview = shellFilePreview(scale: layout.scale)
            } else {
                retireShellFilePreview()
            }
        } else if launcherFilter == .cli {
            executableShellRows(into: &data, layout: layout)
        } else {
            applicationShellRows(into: &data, layout: layout)
        }
    }

    func performLauncherShellCommand(_ verb: String, _ argument: String) {
        guard isLauncherMode, !isUnifiedSearch else { return }
        switch verb {
        case "filter":
            guard selectedMode == .applications, let filter = LauncherFilter(rawValue: argument) else { return }
            selectLauncherFilter(filter)
        case "chip":
            guard let chip = launcherChips.first(where: { $0.id == argument }) else { return }
            selectLauncherChip(chip)
        case "view":
            guard selectedMode == .files || launcherFilter == .apps,
                  let style = LauncherViewStyle(rawValue: argument) else { return }
            setLauncherViewStyle(style)
        case "launcher":
            guard argument == "add", selectedMode == .applications else { return }
            addLauncherEntry(.command)
        default:
            return
        }
    }

    func syncLauncherPaths(_ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        let shows = flags.contains(.command)
        if launcherShowsPaths != shows { launcherShowsPaths = shows }
    }

    func clearShellLauncherRows() {
        shellUnifiedRowCache.removeAll(keepingCapacity: true)
        shellLauncherRowCache.removeAll(keepingCapacity: true)
    }

    private func applicationShellRows(into data: inout ShellCommandPaletteData, layout: CommandPaletteLauncherLayout) {
        let saved = launcherSavedEntries
        let sections = displayedApplicationSections
        guard !saved.isEmpty || sections.contains(where: { !$0.items.isEmpty }) else {
            let loading = isApplicationLoading && applicationSections.isEmpty
            showLauncherState(
                &data,
                loading: loading,
                text: loading ? String(localized: "Loading applications…")
                    : String(localized: "No launcher results found")
            )
            return
        }
        var keys = CommandPaletteLauncherKeys()
        if !saved.isEmpty {
            keys.ids.append(Self.shellLauncherHeadingID(.saved))
            for entry in saved {
                let selection = CommandPaletteSelectionID.launcherEntry(entry.id)
                if selection == layout.current { keys.selected = keys.ids.count }
                keys.ids.append(shellRowKey(selection))
            }
        }
        appendLauncherKeys(sections, layout: layout, selection: CommandPaletteSelectionID.application, keys: &keys)
        var cursor = CommandPaletteLauncherCursor(
            range: sliceRows(ids: keys.ids, selectedIndex: keys.selected, limit: layout.limit, into: &data)
        )
        if !saved.isEmpty {
            if cursor.range.contains(cursor.position) {
                data.rows.append(Self.shellLauncherHeading(.saved, title: Self.shellSavedTitle))
            }
            cursor.position += 1
            for entry in saved {
                defer { cursor.position += 1 }
                guard cursor.range.contains(cursor.position) else { continue }
                var row = savedShellRow(entry)
                row.selected = row.id == layout.currentKey
                data.rows.append(row)
            }
        }
        appendLauncherRows(sections, layout: layout, cursor: &cursor, row: {
            applicationShellRow($1, .application($0, $1.id), layout: layout)
        }, into: &data)
    }

    private func fileShellRows(into data: inout ShellCommandPaletteData, layout: CommandPaletteLauncherLayout) {
        defer { finishShellFileIconDemand(data.rows, points: layout.points) }
        let sections = fileSections
        guard sections.contains(where: { !$0.items.isEmpty }) else {
            let loading = isFileLoading && sections.isEmpty
            showLauncherState(
                &data,
                loading: loading,
                text: loading ? String(localized: "Loading files…") : String(localized: "No files found")
            )
            return
        }
        var keys = CommandPaletteLauncherKeys()
        appendLauncherKeys(sections, layout: layout, selection: CommandPaletteSelectionID.file, keys: &keys)
        var cursor = CommandPaletteLauncherCursor(
            range: sliceRows(ids: keys.ids, selectedIndex: keys.selected, limit: layout.limit, into: &data)
        )
        appendLauncherRows(sections, layout: layout, cursor: &cursor, row: {
            fileShellRow($1, .file($0, $1.id), layout: layout)
        }, into: &data)
    }

    private func executableShellRows(into data: inout ShellCommandPaletteData, layout: CommandPaletteLauncherLayout) {
        let executables = launcherExecutables
        guard !executables.isEmpty else {
            let catalog = LauncherExecutableCatalog.shared
            showLauncherState(
                &data,
                loading: catalog.isLoading,
                text: catalog.isLoading ? String(localized: "Loading CLI tools…")
                    : catalog.failure ?? String(localized: "No launcher results found")
            )
            return
        }
        var keys = CommandPaletteLauncherKeys()
        keys.ids.reserveCapacity(executables.count)
        for executable in executables {
            let selection = CommandPaletteSelectionID.executable(executable.path)
            if selection == layout.current { keys.selected = keys.ids.count }
            keys.ids.append(shellRowKey(selection))
        }
        for index in sliceRows(ids: keys.ids, selectedIndex: keys.selected, limit: layout.limit, into: &data) {
            var row = executableShellRow(executables[index])
            row.selected = index == keys.selected
            data.rows.append(row)
        }
    }

    private func showLauncherState(_ data: inout ShellCommandPaletteData, loading: Bool, text: String) {
        data.state = loading ? "loading" : "empty"
        data.emptyText = text
        guard !loading else { return }
        data.emptySymbol = emptyStateSymbol
        if selectedMode == .applications { data.emptyAction = Self.shellAddEntryAction }
    }

    private func appendLauncherKeys<Item: Identifiable>(
        _ sections: [LauncherSection<Item>],
        layout: CommandPaletteLauncherLayout,
        selection: (LauncherSectionID, Item.ID) -> CommandPaletteSelectionID,
        keys: inout CommandPaletteLauncherKeys
    ) {
        let step = layout.grid ? layout.columns : 1
        for section in sections where !section.items.isEmpty {
            if !section.title.isEmpty { keys.ids.append(Self.shellLauncherHeadingID(section.id)) }
            var start = 0
            while start < section.items.count {
                let end = min(start + step, section.items.count)
                if let current = layout.current, keys.selected == nil,
                   section.items[start ..< end].contains(where: { selection(section.id, $0.id) == current })
                {
                    keys.selected = keys.ids.count
                }
                let first = shellRowKey(selection(section.id, section.items[start].id))
                keys.ids.append(layout.grid ? shellGridKey(first) : first)
                start = end
            }
        }
    }

    private func appendLauncherRows<Item: Identifiable>(
        _ sections: [LauncherSection<Item>],
        layout: CommandPaletteLauncherLayout,
        cursor: inout CommandPaletteLauncherCursor,
        row: (LauncherSectionID, Item) -> ShellCommandPaletteData.Row,
        into data: inout ShellCommandPaletteData
    ) {
        let step = layout.grid ? layout.columns : 1
        for section in sections where !section.items.isEmpty {
            guard cursor.position < cursor.range.upperBound else { return }
            if !section.title.isEmpty {
                if cursor.range.contains(cursor.position) {
                    data.rows.append(Self.shellLauncherHeading(section.id, title: section.title))
                }
                cursor.position += 1
            }
            var start = 0
            while start < section.items.count, cursor.position < cursor.range.upperBound {
                let end = min(start + step, section.items.count)
                if cursor.range.contains(cursor.position) {
                    data.rows.append(launcherLine(section, start ..< end, layout: layout, row: row))
                }
                cursor.position += 1
                start = end
            }
        }
    }

    private func launcherLine<Item: Identifiable>(
        _ section: LauncherSection<Item>,
        _ items: Range<Int>,
        layout: CommandPaletteLauncherLayout,
        row: (LauncherSectionID, Item) -> ShellCommandPaletteData.Row
    ) -> ShellCommandPaletteData.Row {
        guard layout.grid else {
            var line = row(section.id, section.items[items.lowerBound])
            line.selected = line.id == layout.currentKey
            return line
        }
        var line = ShellCommandPaletteData.Row(
            id: "",
            kind: .gridRow,
            title: "",
            subtitle: "",
            icon: .init(app: nil, pid: nil, symbol: nil),
            badges: [],
            marks: [],
            hint: nil,
            hintShortcut: nil,
            selected: false,
            enabled: true
        )
        line.cells.reserveCapacity(items.count)
        for index in items {
            var cell = row(section.id, section.items[index])
            cell.selected = cell.id == layout.currentKey
            line.selected = line.selected || cell.selected
            line.cells.append(cell)
        }
        line.id = shellGridKey(line.cells[0].id)
        return line
    }

    private func applicationShellRow(
        _ item: LauncherApplicationResult,
        _ selection: CommandPaletteSelectionID,
        layout: CommandPaletteLauncherLayout
    ) -> ShellCommandPaletteData.Row {
        var row = cachedLauncherRow(selection, source: .application(item.displayName, item.categoryName)) {
            shellLauncherRow(
                selection,
                kind: .application,
                title: item.displayName,
                subtitle: item.categoryName ?? "",
                symbol: "app.fill"
            )
        }
        shellApplicationIcon(item, selection: selection, points: layout.points, scale: layout.scale, into: &row)
        return row
    }

    private func fileShellRow(
        _ item: LauncherFileResult,
        _ selection: CommandPaletteSelectionID,
        layout: CommandPaletteLauncherLayout
    ) -> ShellCommandPaletteData.Row {
        let source = CommandPaletteShellLauncherSource.file(
            item.displayName, item.modifiedAt, item.kind, item.isDirectory
        )
        var row = cachedLauncherRow(selection, source: source) {
            shellLauncherRow(
                selection,
                kind: .file,
                title: item.displayName,
                subtitle: item.modifiedAt.map {
                    String(localized: "Modified \($0.formatted(date: .abbreviated, time: .omitted))")
                } ?? item.kind ?? "",
                symbol: item.isDirectory ? "folder.fill" : "doc.fill"
            )
        }
        if layout.showsPaths { row.subtitle = item.id }
        shellFileIcon(item, selection: selection, points: layout.points, scale: layout.scale, into: &row)
        return row
    }

    private func savedShellRow(_ entry: LauncherEntry) -> ShellCommandPaletteData.Row {
        let selection = CommandPaletteSelectionID.launcherEntry(entry.id)
        return cachedLauncherRow(selection, source: .saved(entry)) {
            var row = shellLauncherRow(
                selection,
                kind: .saved,
                title: entry.name,
                subtitle: entry.kind == .command ? entry.command : entry.path,
                symbol: entry.symbol
            )
            row.badges = [.init(
                text: entry.kind == .application ? entry.kind.title : entry.terminal.title,
                tone: .neutral,
                symbol: nil
            )]
            return row
        }
    }

    private func executableShellRow(_ executable: LauncherExecutable) -> ShellCommandPaletteData.Row {
        let selection = CommandPaletteSelectionID.executable(executable.path)
        return cachedLauncherRow(selection, source: .executable(executable.name)) {
            var row = shellLauncherRow(
                selection,
                kind: .executable,
                title: executable.name,
                subtitle: executable.path,
                symbol: "terminal"
            )
            row.badges = [Self.shellCLIBadge]
            return row
        }
    }

    private func cachedLauncherRow(
        _ selection: CommandPaletteSelectionID,
        source: CommandPaletteShellLauncherSource,
        _ make: () -> ShellCommandPaletteData.Row
    ) -> ShellCommandPaletteData.Row {
        if let cached = shellLauncherRowCache[selection], cached.source == source { return cached.row }
        let row = make()
        shellLauncherRowCache[selection] = .init(source: source, row: row)
        return row
    }

    private func shellGridKey(_ first: String) -> String {
        if let key = shellGridKeys[first] { return key }
        shellUnifiedKeySequence &+= 1
        let key = "grid-" + String(shellUnifiedKeySequence)
        shellGridKeys[first] = key
        return key
    }

    private func shellLauncherToolbar(columns: Int, style: LauncherViewStyle) -> ShellCommandPaletteData.Launcher {
        let mode = selectedMode
        let filter = launcherFilter
        let chips = launcherChips
        let chip = selectedLauncherChipID
        if let cache = shellLauncherToolbarCache, cache.mode == mode, cache.filter == filter, cache.style == style,
           cache.columns == columns, cache.chip == chip, cache.chips == chips
        {
            return cache.value
        }
        var value = ShellCommandPaletteData.Launcher(columns: columns, grid: style == .grid)
        if mode == .applications {
            value.filters = LauncherFilter.allCases.map { item in
                Self.shellChip(item.rawValue, Self.shellFilterTitles[item] ?? item.title, selected: item == filter)
            }
            value.add = Self.shellAddAction
        }
        value.chips = chips.map { Self.shellChip($0.id, $0.title, selected: $0.id == chip) }
        if mode == .files || filter == .apps {
            value.views = [
                Self.shellChip(
                    LauncherViewStyle.grid.rawValue, Self.shellGridTitle,
                    symbol: "square.grid.2x2", selected: style == .grid
                ),
                Self.shellChip(
                    LauncherViewStyle.list.rawValue, Self.shellListTitle,
                    symbol: "list.bullet", selected: style == .list
                )
            ]
        }
        shellLauncherToolbarCache = .init(
            mode: mode, filter: filter, style: style, columns: columns, chips: chips, chip: chip, value: value
        )
        return value
    }

    private static func shellChip(
        _ id: String, _ title: String, symbol: String = "", selected: Bool
    ) -> ShellCommandPaletteData.Mode {
        .init(id: id, title: title, symbol: symbol, shortcut: "", selected: selected, enabled: true)
    }

    private static func shellLauncherHeadingID(_ id: LauncherSectionID) -> String {
        switch id {
        case .saved: "heading-launcher-saved"
        case .executables: "heading-launcher-executables"
        case .suggestions: "heading-launcher-suggestions"
        case .recents: "heading-launcher-recents"
        case .results: "heading-launcher-results"
        case .all: "heading-launcher-all"
        case .other: "heading-launcher-other"
        case .category: "heading-launcher-category"
        }
    }

    private static func shellLauncherHeading(_ id: LauncherSectionID, title: String) -> ShellCommandPaletteData.Row {
        .init(
            id: shellLauncherHeadingID(id),
            kind: .heading,
            title: title,
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

    private static let shellSavedTitle = String(localized: "Saved")
    private static let shellGridTitle = String(localized: "Grid")
    private static let shellListTitle = String(localized: "List")
    private static let shellCLIBadge = ShellCommandPaletteData.Badge(
        text: String(localized: "CLI"), tone: .neutral, symbol: nil
    )
    private static let shellFilterTitles = Dictionary(uniqueKeysWithValues: LauncherFilter.allCases.map {
        ($0, $0 == .cli ? String(localized: "CLI Tools") : $0.title)
    })
    private static let shellAddAction = ShellCommandPaletteData.Action(
        id: shellLauncherAddTarget, title: String(localized: "Add…"), symbol: "plus", shortcut: ""
    )
    private static let shellAddEntryAction = ShellCommandPaletteData.Action(
        id: "launcher add", title: String(localized: "Add Entry…"), symbol: "plus", shortcut: ""
    )
}
