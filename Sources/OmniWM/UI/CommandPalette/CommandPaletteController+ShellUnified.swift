// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension CommandPaletteController {
    static let shellIconPoints: CGFloat = 28
    func unifiedRows(into data: inout ShellCommandPaletteData, limit: Float) {
        defer { finishShellFileIconDemand(data.rows) }
        if showsUnifiedWindowList {
            windowRows(into: &data, limit: limit)
            if data.rows.isEmpty {
                data.state = "empty"
                data.emptySymbol = "macwindow.on.rectangle"
                data.emptyText = String(localized: "No windows available")
            }
            return
        }
        guard !unifiedQuery.isEmpty else {
            data.state = "blank"
            return
        }
        guard !unifiedResults.isEmpty else {
            data.state = isUnifiedSearchLoading ? "loading" : "empty"
            data.emptyText = isUnifiedSearchLoading ? String(localized: "Searching…") : String(localized: "No results")
            data.emptySymbol = "magnifyingglass"
            return
        }
        let lines = unifiedResults.lines
        var ids: [String] = []
        ids.reserveCapacity(lines.count)
        var selected: Int?
        for line in lines {
            if case let .row(selection) = line, selection == selectedItemID { selected = ids.count }
            ids.append(shellUnifiedLineKey(line))
        }
        for index in sliceRows(ids: ids, selectedIndex: selected, limit: limit, into: &data) {
            guard var row = shellUnifiedLine(lines[index]) else { continue }
            row.selected = index == selected
            decorateUnifiedRow(&row, line: lines[index])
            data.rows.append(row)
        }
    }

    private func decorateUnifiedRow(_ row: inout ShellCommandPaletteData.Row, line: UnifiedSearchResults.Line) {
        if case let .row(selection) = line {
            if row.selected, case let .window(token) = selection, isSummonRightAvailable,
               let item = windows.first(where: { $0.id == token }), allowsWindowAlternateAction(item)
            {
                let hint = CommandPalettePresentation.selectedWindowHint(isSummonRightAvailable: true)
                row.hint = hint?.title
                row.hintShortcut = hint?.shortcut
            }
            if let hit = unifiedResults.topHits.firstIndex(of: selection) {
                row.badges.append(.init(
                    text: CommandPalettePresentation.topHitShortcut(at: hit),
                    tone: .shortcut,
                    symbol: nil
                ))
            }
            shellIcon(for: selection, into: &row)
        }
    }

    private func shellUnifiedLineKey(_ line: UnifiedSearchResults.Line) -> String {
        switch line {
        case .topHitsHeading: "heading-unified-top"
        case let .groupHeading(mode): Self.shellUnifiedHeadings[mode]!.id
        case let .row(selection): shellRowKey(selection)
        }
    }

    private func shellUnifiedLine(_ line: UnifiedSearchResults.Line) -> ShellCommandPaletteData.Row? {
        switch line {
        case .topHitsHeading:
            return Self.shellTopHitsHeading
        case let .groupHeading(mode):
            return Self.shellUnifiedHeadings[mode]
        case let .row(selection): return shellUnifiedRow(selection)
        }
    }

    static let shellSearchPlaceholder = String(localized: "Search…")
    private static let shellTopHitsHeading = shellUnifiedHeading(
        id: "heading-unified-top", title: String(localized: "Top Hits")
    )
    private static let shellUnifiedHeadings = Dictionary(uniqueKeysWithValues: CommandPaletteMode.allCases.map {
        ($0, shellUnifiedHeading(id: "heading-unified-" + $0.rawValue, title: $0.localizedDisplayName))
    })

    private static func shellUnifiedHeading(id: String, title: String) -> ShellCommandPaletteData.Row {
        .init(
            id: id,
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

    func shellUnifiedRow(_ selection: CommandPaletteSelectionID) -> ShellCommandPaletteData.Row? {
        switch selection {
        case .window,
             .menu,
             .clipboard,
             .command: return shellSourceRow(selection)
        default: break
        }
        if let row = shellUnifiedRowCache[selection] { return row }
        let row: ShellCommandPaletteData.Row
        switch selection {
        case let .application(section, id):
            guard let item = applicationResult(section, id) else { return nil }
            row = shellLauncherRow(
                selection,
                kind: .application,
                title: item.displayName,
                subtitle: item.categoryName ?? "",
                symbol: "app.fill"
            )
        case let .file(section, id):
            guard let item = fileResult(section, id) else { return nil }
            row = shellLauncherRow(
                selection,
                kind: .file,
                title: item.displayName,
                subtitle: item.fileURL.deletingLastPathComponent().path,
                symbol: item.isDirectory ? "folder.fill" : "doc.fill"
            )
        case let .launcherEntry(id):
            guard let entry = launcherSavedEntries.first(where: { $0.id == id }) else { return nil }
            row = shellLauncherRow(
                selection,
                kind: .saved,
                title: entry.name,
                subtitle: entry.kind == .command ? entry.command : entry.path,
                symbol: entry.symbol
            )
        case let .showAll(mode):
            row = shellLauncherRow(
                selection,
                kind: .showAll,
                title: String(localized: "Show all in \(mode.localizedDisplayName)"),
                subtitle: "",
                symbol: "arrow.right.circle"
            )
        default: return nil
        }
        shellUnifiedRowCache[selection] = row
        return row
    }

    private func shellSourceRow(_ selection: CommandPaletteSelectionID) -> ShellCommandPaletteData.Row? {
        switch selection {
        case let .window(id):
            if let row = shellRowCache[id] { return row }
            return windows.first { $0.id == id }.map { cachedShellRow($0) }
        case let .menu(id):
            if let row = shellMenuRowCache[id] { return row }
            return menuItems.first { $0.id == id }.map { cachedShellRow($0) }
        case let .clipboard(id):
            if let row = shellClipboardRowCache[id] { return row }
            return clipboardItems.first { $0.id == id }.map { cachedShellRow($0) }
        case let .command(id):
            if let row = shellCommandRowCache[id] { return row }
            return commandItems.first { $0.id == id }.map { cachedShellRow($0) }
        case .executable: return nil
        default: return nil
        }
    }

    func shellLauncherRow(
        _ selection: CommandPaletteSelectionID, kind: ShellCommandPaletteRowKind,
        title: String, subtitle: String, symbol: String
    ) -> ShellCommandPaletteData.Row {
        .init(
            id: shellRowKey(selection),
            kind: kind,
            title: title,
            subtitle: subtitle,
            icon: .init(app: nil, pid: nil, symbol: symbol),
            badges: [],
            marks: [],
            hint: nil,
            hintShortcut: nil,
            selected: false,
            enabled: true
        )
    }

    private func shellIcon(for selection: CommandPaletteSelectionID, into row: inout ShellCommandPaletteData.Row) {
        let scale = presentation.panel?.backingScaleFactor ?? 1
        switch selection {
        case let .application(section, id):
            guard let item = applicationResult(section, id) else { return }
            shellApplicationIcon(item, selection: selection, points: Self.shellIconPoints, scale: scale, into: &row)
        case let .file(section, id):
            guard let item = fileResult(section, id) else { return }
            shellFileIcon(item, selection: selection, points: Self.shellIconPoints, scale: scale, into: &row)
        default:
            return
        }
    }

    func shellApplicationIcon(
        _ item: LauncherApplicationResult,
        selection: CommandPaletteSelectionID,
        points: CGFloat,
        scale: CGFloat,
        into row: inout ShellCommandPaletteData.Row
    ) {
        let store = LauncherIconStore.shared
        let image = store.applicationIcon(for: item, points: points, scale: scale)
        store.loadApplicationIcon(for: item, points: points, scale: scale)
        attachShellBitmap(image, for: selection, scale: scale, into: &row)
    }

    func shellFileIcon(
        _ item: LauncherFileResult,
        selection: CommandPaletteSelectionID,
        points: CGFloat,
        scale: CGFloat,
        into row: inout ShellCommandPaletteData.Row
    ) {
        if !shellFileIconRequests.contains(where: { $0.id == row.id && $0.points == points && $0.scale == scale }) {
            shellFileIconRequests.append(.init(id: row.id, item: item, points: points, scale: scale))
        }
        let store = LauncherIconStore.shared
        let image = store.fileThumbnail(for: item, points: points, scale: scale)
        store.loadFileThumbnail(for: item, points: points, scale: scale)
        attachShellBitmap(image, for: selection, scale: scale, into: &row)
    }

    private func attachShellBitmap(
        _ image: NSImage?,
        for selection: CommandPaletteSelectionID,
        scale: CGFloat,
        into row: inout ShellCommandPaletteData.Row
    ) {
        guard let image, let shell = presentation.shell else { return }
        if let cache = shellImageCache[selection], cache.image === image,
           cache.owner == ObjectIdentifier(shell), cache.generation == shell.bitmapGeneration, cache.scale == scale
        {
            row.icon.bitmap = cache.bitmap
            return
        }
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        if let previous = shellImageCache[selection] { shell.removeBitmap(previous.bitmap) }
        shellImageSequence &+= 1
        let id = shell.registerBitmap(bitmap, key: "icon-" + String(shellImageSequence))
        shellImageCache[selection] = .init(
            image: image,
            owner: ObjectIdentifier(shell),
            generation: shell.bitmapGeneration,
            scale: scale,
            bitmap: id
        )
        row.icon.bitmap = id
    }

    func finishShellFileIconDemand(_ rows: [ShellCommandPaletteData.Row], points: CGFloat = shellIconPoints) {
        let scale = presentation.panel?.backingScaleFactor ?? 1
        shellFileIconRequests.removeAll { request in
            guard request.scale != scale || request.points != points || !Self.draws(request.id, in: rows) else {
                return false
            }
            LauncherIconStore.shared.cancelFileThumbnail(
                for: request.item,
                points: request.points,
                scale: request.scale
            )
            return true
        }
    }

    private static func draws(_ id: String, in rows: [ShellCommandPaletteData.Row]) -> Bool {
        rows.contains { $0.id == id || $0.cells.contains { $0.id == id } }
    }
}

struct CommandPaletteShellImage {
    let image: NSImage
    let owner: ObjectIdentifier
    let generation: Int
    let scale: CGFloat
    let bitmap: String
}

struct CommandPaletteShellFileIconRequest {
    let id: String
    let item: LauncherFileResult
    let points: CGFloat
    let scale: CGFloat
}
