// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension CommandPaletteController {
    func menuRows(into data: inout ShellCommandPaletteData, limit: Float) {
        let items = filteredMenuItems
        var ids: [String] = []
        ids.reserveCapacity(items.count)
        var selected: Int?
        for index in items.indices {
            ids.append(shellRowKey(.menu(items[index].id)))
            if selectedItemID == .menu(items[index].id) { selected = index }
        }
        for index in sliceRows(ids: ids, selectedIndex: selected, limit: limit, into: &data) {
            var row = cachedShellRow(items[index])
            row.selected = index == selected
            data.rows.append(row)
        }
    }

    func clipboardRows(into data: inout ShellCommandPaletteData, limit: Float) {
        let items = filteredClipboardItems
        var ids: [String] = []
        ids.reserveCapacity(items.count)
        var selected: Int?
        for index in items.indices {
            ids.append(shellRowKey(.clipboard(items[index].id)))
            if selectedItemID == .clipboard(items[index].id) { selected = index }
        }
        for index in sliceRows(ids: ids, selectedIndex: selected, limit: limit, into: &data) {
            var row = cachedShellRow(items[index])
            row.selected = index == selected
            data.rows.append(row)
        }
    }

    func cachedShellRow(_ item: MenuItemModel) -> ShellCommandPaletteData.Row {
        if let cached = shellMenuRowCache[item.id] { return cached }
        let row = ShellCommandPaletteData.Row(
            id: shellRowKey(.menu(item.id)), kind: .menu, title: item.title,
            subtitle: item.parentTitles.joined(separator: " > "),
            icon: .init(app: nil, pid: nil, symbol: nil),
            badges: item.keyboardShortcut.map { [.init(text: $0, tone: .shortcut, symbol: nil)] } ?? [],
            marks: [], hint: nil, hintShortcut: nil, selected: false, enabled: true
        )
        shellMenuRowCache[item.id] = row
        return row
    }

    func cachedShellRow(_ item: ClipboardPaletteItem) -> ShellCommandPaletteData.Row {
        if let cached = shellClipboardRowCache[item.id] { return cached }
        let id = shellRowKey(.clipboard(item.id))
        let row = ShellCommandPaletteData.Row(
            id: id, kind: .clipboard, title: item.title, subtitle: item.subtitle,
            icon: .init(app: nil, pid: nil, symbol: item.kind.paletteSymbol), badges: [], marks: [],
            hint: nil, hintShortcut: nil, selected: false, enabled: true, pinned: item.isPinned,
            actions: [
                .init(
                    id: "paste " + id,
                    title: String(localized: "Paste"),
                    symbol: "arrow.turn.down.left",
                    shortcut: ""
                ),
                .init(
                    id: "menu " + id,
                    title: String(localized: "More actions for \(item.title)"),
                    symbol: "ellipsis",
                    shortcut: ""
                )
            ]
        )
        shellClipboardRowCache[item.id] = row
        return row
    }

    func shellClipboardPreview() -> ShellCommandPaletteData.Preview? {
        guard let shell = presentation.shell, case let .clipboard(id)? = selectedItemID else { return nil }
        if let cache = shellPreviewCache, cache.owner == ObjectIdentifier(shell),
           cache.generation == shell.bitmapGeneration, cache.previewGeneration == clipboardPreviewGeneration,
           cache.loading == isClipboardPreviewLoading, cache.available == (clipboardPreview != nil)
        {
            return cache.data
        }
        if let image = shellPreviewCache?.data.image { shell.removeBitmap(image) }
        let key = id.uuidString + "-" + String(clipboardPreviewGeneration)
        var preview = ShellCommandPaletteData.Preview(id: key, state: "unavailable", text: nil, image: nil)
        if isClipboardPreviewLoading {
            preview.state = "loading"
        } else if case let .text(text)? = clipboardPreview {
            preview.state = "text"
            preview.text = text
        } else if let image = clipboardPreviewImage,
                  let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            preview.state = "image"
            preview.image = shell.registerBitmap(bitmap, key: key)
            preview.width = Double(bitmap.width)
            preview.height = Double(bitmap.height)
        }
        shellPreviewCache = .init(
            owner: ObjectIdentifier(shell), generation: shell.bitmapGeneration,
            previewGeneration: clipboardPreviewGeneration, loading: isClipboardPreviewLoading,
            available: clipboardPreview != nil, data: preview
        )
        return preview
    }
}

struct CommandPaletteShellPreviewCache {
    let owner: ObjectIdentifier
    let generation: Int
    let previewGeneration: Int
    let loading: Bool
    let available: Bool
    let data: ShellCommandPaletteData.Preview
}

extension ClipboardContentKind {
    var paletteSymbol: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "doc.richtext"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .fileURL: "doc"
        case .other: "doc.questionmark"
        }
    }
}
