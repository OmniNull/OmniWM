// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension CommandPaletteController {
    static let shellPreviewPoints: CGFloat = 256
    static let shellPreviewSplit: CGFloat = 0.55

    func shellFilePreview(scale: CGFloat) -> ShellCommandPaletteData.Preview {
        guard let item = selectedLauncherFileResult, case let .file(section, _)? = selectedItemID,
              let shell = presentation.shell
        else {
            retireShellFilePreview()
            return Self.blankFilePreview
        }
        let store = LauncherIconStore.shared
        let image = store.fileThumbnail(for: item, points: Self.shellPreviewPoints, scale: scale)
        store.loadFileThumbnail(for: item, points: Self.shellPreviewPoints, scale: scale)
        let previous = shellFilePreviewCache
        if let previous, previous.item.id == item.id, previous.scale == scale, previous.image === image,
           previous.owner == ObjectIdentifier(shell), previous.generation == shell.bitmapGeneration
        {
            return previous.data
        }
        if let previous, previous.item.id != item.id || previous.scale != scale {
            store.cancelFileThumbnail(for: previous.item, points: Self.shellPreviewPoints, scale: previous.scale)
        }
        var preview = ShellCommandPaletteData.Preview(
            id: shellRowKey(.file(section, item.id)), state: "file", text: nil, image: nil
        )
        preview.title = item.displayName
        preview.symbol = item.isDirectory ? "folder.fill" : "doc.fill"
        preview.details = previous?.item.id == item.id ? previous?.data.details ?? [] : Self.fileDetails(item)
        if let image, let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            shellImageSequence &+= 1
            preview.image = shell.registerBitmap(bitmap, key: "preview-" + String(shellImageSequence))
            preview.width = Double(CGFloat(bitmap.width) / scale)
            preview.height = Double(CGFloat(bitmap.height) / scale)
        }
        shellFilePreviewCache = .init(
            item: item,
            scale: scale,
            image: image,
            owner: ObjectIdentifier(shell),
            generation: shell.bitmapGeneration,
            data: preview
        )
        return preview
    }

    func retireShellFilePreview() {
        guard let cache = shellFilePreviewCache else { return }
        shellFilePreviewCache = nil
        LauncherIconStore.shared.cancelFileThumbnail(
            for: cache.item,
            points: Self.shellPreviewPoints,
            scale: cache.scale
        )
    }

    func openLauncherQuickLook() {
        guard selectedMode == .files, launcherQuickLook == nil, let item = selectedLauncherFileResult,
              let panel = presentation.panel
        else { return }
        let source = ShellDesktopSource(
            window: panel,
            isCurrent: { [weak self] in self?.isVisible == true && self?.selectedMode == .files },
            beginFocus: { [weak self] child in
                guard let self, isVisible else { throw ShellResourceFailure("source_surface_unavailable") }
                return beginQuickLookFocus(child)
            }
        )
        do {
            let quickLook = try environment.quickLook([item.fileURL], source) { [weak self] _ in
                self?.launcherQuickLook = nil
            }
            launcherQuickLook = quickLook
            try quickLook.start()
        } catch {
            launcherQuickLook = nil
        }
    }

    func closeLauncherQuickLook() {
        let quickLook = launcherQuickLook
        launcherQuickLook = nil
        quickLook?.cancel()
    }

    private func beginQuickLookFocus(_ child: NSWindow?) -> ShellDesktopSource.FocusEnd {
        if let child { presentation.registerOwnedChild(child) }
        return { [weak self, weak child] resume in
            guard let self else { return }
            if let child { presentation.unregisterOwnedChild(child) }
            guard resume, isVisible, selectedMode == .files, let panel = presentation.panel else { return }
            panel.makeKey()
        }
    }

    private static func fileDetails(_ item: LauncherFileResult) -> [ShellCommandPaletteData.Detail] {
        var details: [ShellCommandPaletteData.Detail] = []
        if let kind = item.kind {
            details.append(.init(label: String(localized: "Kind"), value: kind))
        }
        if let size = item.size {
            details.append(.init(
                label: String(localized: "Size"),
                value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            ))
        }
        let dates = [
            (String(localized: "Created"), item.createdAt),
            (String(localized: "Modified"), item.modifiedAt),
            (String(localized: "Last Opened"), item.lastOpenedAt)
        ]
        for (label, date) in dates {
            guard let date else { continue }
            details.append(.init(label: label, value: date.formatted(date: .abbreviated, time: .shortened)))
        }
        return details
    }

    private static let blankFilePreview = ShellCommandPaletteData.Preview(
        id: "blank", state: "blank", text: nil, image: nil
    )
}

struct CommandPaletteShellFilePreviewCache {
    let item: LauncherFileResult
    let scale: CGFloat
    let image: NSImage?
    let owner: ObjectIdentifier
    let generation: Int
    let data: ShellCommandPaletteData.Preview
}
