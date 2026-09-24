// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CryptoKit
import Darwin
import Foundation

struct ClipboardHistoryPersistence: Sendable {
    let fileURL: URL

    func load() -> [ClipboardHistoryItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data)
        else {
            return []
        }
        return items
    }

    func save(_ items: [ClipboardHistoryItem]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
        chmod(fileURL.path, S_IRUSR | S_IWUSR)
    }
}

actor ClipboardHistoryStore {
    private var configuration: ClipboardHistoryConfiguration
    private var persistence: ClipboardHistoryPersistence
    private var items: [ClipboardHistoryItem] = []
    private var hasLoaded = false
    private var hasPendingChanges = false
    private var lastClearEpoch = Int.min
    private let sleep: @Sendable (Duration) async throws -> Void
    private(set) var saveTask: Task<Void, Never>?

    init(
        configuration: ClipboardHistoryConfiguration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.configuration = Self.normalized(configuration)
        self.sleep = sleep
        persistence = ClipboardHistoryPersistence(fileURL: self.configuration.storageURL)
    }

    func updateConfiguration(_ configuration: ClipboardHistoryConfiguration) -> [ClipboardPaletteItem] {
        let fileURLChanged = self.configuration.storageURL != configuration.storageURL
        self.configuration = Self.normalized(configuration)
        if fileURLChanged {
            saveTask?.cancel()
            saveTask = nil
            hasPendingChanges = false
            persistence = ClipboardHistoryPersistence(fileURL: self.configuration.storageURL)
            items = []
            hasLoaded = false
        }
        ensureLoaded()
        let previous = items
        prune()
        if items != previous { scheduleSave() }
        return paletteItems()
    }

    func load() -> [ClipboardPaletteItem] {
        ensureLoaded()
        return paletteItems()
    }

    func fenceCaptures(epoch: Int) {
        ensureLoaded()
        lastClearEpoch = max(lastClearEpoch, epoch)
    }

    func handleCapture(_ capture: ClipboardPasteboardCapture, epoch: Int = 0) -> [ClipboardPaletteItem] {
        ensureLoaded()
        guard epoch >= lastClearEpoch else { return paletteItems() }
        let configuration = self.configuration
        guard configuration.isEnabled,
              !capture.contents.contains(where: { configuration.ignoredTypes.contains($0.type) })
        else {
            return paletteItems()
        }
        guard !capture.contents.isEmpty else { return paletteItems() }
        let byteCount = capture.contents.reduce(0) { $0 + $1.data.count }
        guard byteCount <= configuration.maxItemBytes else { return paletteItems() }

        let digest = digest(for: capture.contents)
        let derivedText = searchable(capture.derivedText)
        return record(capture, byteCount: byteCount, digest: digest, derivedText: derivedText)
    }

    func item(matching capture: ClipboardPasteboardCapture) -> ClipboardHistoryItem? {
        ensureLoaded()
        let captureDigest = digest(for: capture.contents)
        return items.first { $0.digest == captureDigest }
    }

    func item(id: UUID) -> ClipboardHistoryItem? {
        ensureLoaded()
        return items.first { $0.id == id }
    }

    func pin(id: UUID, isPinned: Bool) -> [ClipboardPaletteItem] {
        ensureLoaded()
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isPinned != isPinned else {
            return paletteItems()
        }
        var item = items.remove(at: index)
        item.pinnedAt = isPinned ? Date() : nil
        items.insert(item, at: 0)
        prune()
        scheduleSave()
        return paletteItems()
    }

    func setRecognizedText(id: UUID, digest: String, text: String) -> [ClipboardPaletteItem] {
        ensureLoaded()
        guard let index = items.firstIndex(where: { $0.id == id && $0.digest == digest }) else {
            return paletteItems()
        }
        let recognizedText = searchable(text) ?? ""
        guard items[index].recognizedText != recognizedText else { return paletteItems() }
        items[index].recognizedText = recognizedText
        items[index].title = title(
            for: items[index].contents,
            derivedText: items[index].derivedText,
            recognizedText: recognizedText
        )
        scheduleSave()
        return paletteItems()
    }

    func itemForUse(id: UUID) -> ClipboardHistoryItem? {
        ensureLoaded()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        var item = items.remove(at: index)
        item.lastCopiedAt = Date()
        item.numberOfCopies += 1
        items.insert(item, at: 0)
        prune()
        scheduleSave()
        return item
    }

    func delete(id: UUID) -> [ClipboardPaletteItem] {
        ensureLoaded()
        let previousCount = items.count
        items.removeAll { $0.id == id }
        if items.count != previousCount { scheduleSave() }
        return paletteItems()
    }

    func clear(epoch: Int = 0) throws -> [ClipboardPaletteItem] {
        ensureLoaded()
        let retained = items.filter(\.isPinned)
        try persistence.save(retained)
        saveTask?.cancel()
        saveTask = nil
        hasPendingChanges = false
        items = retained
        lastClearEpoch = max(lastClearEpoch, epoch)
        return paletteItems()
    }

    func paletteItems() -> [ClipboardPaletteItem] {
        ensureLoaded()
        return items.map(\.paletteItem)
    }

    func flush() throws {
        ensureLoaded()
        guard hasPendingChanges else { return }
        saveTask?.cancel()
        saveTask = nil
        try persistence.save(items)
        hasPendingChanges = false
    }

    private func scheduleSave() {
        hasPendingChanges = true
        saveTask?.cancel()
        saveTask = Task { [weak self, sleep] in
            do {
                try await sleep(.milliseconds(250))
            } catch {
                return
            }
            await self?.flushScheduledSave()
        }
    }

    private func flushScheduledSave() {
        guard !Task.isCancelled else { return }
        do {
            try flush()
        } catch {
            Log.config.error("Failed to save clipboard history: \(error.localizedDescription)")
        }
    }

    private static func normalized(_ configuration: ClipboardHistoryConfiguration) -> ClipboardHistoryConfiguration {
        ClipboardHistoryConfiguration(
            isEnabled: configuration.isEnabled,
            maxItems: max(1, configuration.maxItems),
            maxItemBytes: max(1, configuration.maxItemBytes),
            maxTotalBytes: max(1, configuration.maxTotalBytes),
            storageDirectory: configuration.storageDirectory,
            ignoredTypes: configuration.ignoredTypes
        )
    }

    private func ensureLoaded() {
        guard !hasLoaded else { return }
        items = persistence.load()
        hasLoaded = true
        let loadedItems = items
        prune()
        if items != loadedItems { scheduleSave() }
    }

    private func prune() {
        let pinned = items.filter(\.isPinned)
        var kept = pinned
        kept.reserveCapacity(items.count)
        var total = pinned.reduce(0) { $0 + $1.byteCount }
        var unpinnedCount = 0
        for item in items where !item.isPinned {
            guard unpinnedCount < configuration.maxItems else { break }
            guard item.byteCount <= configuration.maxItemBytes,
                  total <= configuration.maxTotalBytes - item.byteCount
            else {
                continue
            }
            kept.append(item)
            unpinnedCount += 1
            total += item.byteCount
        }
        items = kept
    }

    private func digest(for contents: [ClipboardHistoryContent]) -> String {
        var hasher = SHA256()
        let separator = Data([0])
        for content in contents.sorted(by: contentSort) {
            hasher.update(data: Data(content.itemIndex.description.utf8))
            hasher.update(data: separator)
            hasher.update(data: Data(content.type.utf8))
            hasher.update(data: separator)
            hasher.update(data: content.data)
            hasher.update(data: separator)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func contentSort(_ lhs: ClipboardHistoryContent, _ rhs: ClipboardHistoryContent) -> Bool {
        if lhs.itemIndex != rhs.itemIndex { return lhs.itemIndex < rhs.itemIndex }
        return lhs.type < rhs.type
    }

    private func primaryKind(for contents: [ClipboardHistoryContent]) -> ClipboardContentKind {
        if contents.contains(where: { $0.kind == .text }) { return .text }
        if contents.contains(where: { $0.kind == .richText }) { return .richText }
        if contents.contains(where: { $0.kind == .html }) { return .html }
        if contents.contains(where: { $0.kind == .fileURL }) { return .fileURL }
        if contents.contains(where: { $0.kind == .image }) { return .image }
        return contents.first?.kind ?? .text
    }

    private func title(
        for contents: [ClipboardHistoryContent],
        derivedText: String?,
        recognizedText: String?
    ) -> String {
        if let text = contents.first(where: { $0.kind == .text }).flatMap({ String(data: $0.data, encoding: .utf8) }) {
            let collapsed = collapsed(text)
            return shortened(collapsed.isEmpty ? "Empty Text" : collapsed, to: 1_000)
        }
        if let derivedText {
            let collapsed = collapsed(derivedText)
            if !collapsed.isEmpty { return shortened(collapsed, to: 1_000) }
        }
        if let fileURL = contents.first(where: { $0.kind == .fileURL }).flatMap({
            URL(dataRepresentation: $0.data, relativeTo: nil)?.lastPathComponent
        }), !fileURL.isEmpty {
            return fileURL
        }
        if let recognizedText {
            let collapsed = collapsed(recognizedText)
            if !collapsed.isEmpty { return shortened(collapsed, to: 1_000) }
        }
        switch primaryKind(for: contents) {
        case .text:
            return "Text"
        case .richText:
            return "Rich Text"
        case .html:
            return "HTML"
        case .image:
            return "Image"
        case .fileURL:
            return "File"
        case .other:
            return "Content"
        }
    }

    private func searchable(_ text: String?) -> String? {
        guard let text else { return nil }
        let limited = shortened(text.trimmingCharacters(in: .whitespacesAndNewlines), to: 10_000)
        return limited.isEmpty ? nil : limited
    }

    private func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shortened(_ value: String, to maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let end = value.index(value.startIndex, offsetBy: maxLength)
        return String(value[..<end])
    }
}

extension ClipboardHistoryStore {
    private func record(
        _ capture: ClipboardPasteboardCapture,
        byteCount: Int,
        digest: String,
        derivedText: String?
    ) -> [ClipboardPaletteItem] {
        if let index = items.firstIndex(where: { $0.digest == digest }) {
            var existing = items.remove(at: index)
            existing.lastCopiedAt = capture.capturedAt
            existing.numberOfCopies += 1
            existing.sourceBundleIdentifier = capture.sourceBundleIdentifier ?? existing.sourceBundleIdentifier
            existing.derivedText = derivedText ?? existing.derivedText
            existing.title = title(
                for: existing.contents,
                derivedText: existing.derivedText,
                recognizedText: existing.recognizedText
            )
            items.insert(existing, at: 0)
        } else {
            let pinnedBytes = items.filter(\.isPinned).reduce(0) { $0 + $1.byteCount }
            guard pinnedBytes <= configuration.maxTotalBytes - byteCount else { return paletteItems() }
            items.insert(
                ClipboardHistoryItem(
                    id: UUID(),
                    contents: capture.contents,
                    title: title(for: capture.contents, derivedText: derivedText, recognizedText: nil),
                    sourceBundleIdentifier: capture.sourceBundleIdentifier,
                    firstCopiedAt: capture.capturedAt,
                    lastCopiedAt: capture.capturedAt,
                    numberOfCopies: 1,
                    digest: digest,
                    byteCount: byteCount,
                    kind: primaryKind(for: capture.contents),
                    pinnedAt: nil,
                    derivedText: derivedText,
                    recognizedText: nil
                ),
                at: 0
            )
        }
        prune()
        scheduleSave()
        return paletteItems()
    }
}
