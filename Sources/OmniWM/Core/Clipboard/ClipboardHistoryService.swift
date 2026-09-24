// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@preconcurrency import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

@MainActor
protocol ClipboardHistoryTimer: AnyObject {
    func invalidate()
}

@MainActor
private final class ClipboardHistoryRunLoopTimer: ClipboardHistoryTimer {
    private var timer: Timer?

    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                action()
            }
        }
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}

struct ClipboardHistoryServiceEnvironment {
    var pasteboardChangeCount: @MainActor () -> Int = {
        NSPasteboard.general.changeCount
    }

    var frontmostBundleIdentifier: @MainActor () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    var date: () -> Date = {
        Date()
    }

    var capturePasteboard: @Sendable (ClipboardPasteboardCaptureConfiguration) -> ClipboardPasteboardCapture? = {
        ClipboardHistoryPasteboard.capture(configuration: $0)
    }

    var writePasteboard: @MainActor (ClipboardHistoryItem) -> Bool = {
        ClipboardHistoryPasteboard.write($0)
    }

    var writePlainTextPasteboard: @MainActor (String, ClipboardHistoryItem) -> Bool = {
        ClipboardHistoryPasteboard.writePlainText($0, from: $1)
    }

    var recognizeImageText: @Sendable (Data) -> String? = {
        ClipboardHistoryImageText.recognize($0)
    }

    var makeTimer: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> ClipboardHistoryTimer = {
        ClipboardHistoryRunLoopTimer(interval: $0, action: $1)
    }
}

final class ClipboardPasteboardReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.omniwm.clipboard-history.reader", qos: .utility)
    private let provider: @Sendable (ClipboardPasteboardCaptureConfiguration) -> ClipboardPasteboardCapture?

    init(provider: @escaping @Sendable (ClipboardPasteboardCaptureConfiguration) -> ClipboardPasteboardCapture?) {
        self.provider = provider
    }

    func capture(configuration: ClipboardPasteboardCaptureConfiguration) async -> ClipboardPasteboardCapture? {
        await withCheckedContinuation { continuation in
            queue.async { [provider] in
                continuation.resume(returning: provider(configuration))
            }
        }
    }
}

@MainActor
final class ClipboardHistoryService: @unchecked Sendable {
    struct PerformanceSnapshot: Equatable, Sendable {
        let timerFires: UInt64
    }

    private(set) var paletteItems: [ClipboardPaletteItem] = []
    var onPaletteItemsChanged: (@MainActor @Sendable ([ClipboardPaletteItem]) -> Void)?

    private var configuration: ClipboardHistoryConfiguration
    private var environment: ClipboardHistoryServiceEnvironment
    private var store: ClipboardHistoryStore
    private var reader: ClipboardPasteboardReader
    private var timer: ClipboardHistoryTimer?
    private var lastChangeCount: Int
    private var configurationGeneration = 0
    private var captureGeneration = 0
    private var captureEpoch = 0
    private var monitoringSuspensions = 0
    private var captureTasks: [Int: Task<Void, Never>] = [:]
    private var imageRecognitionTasks: [UUID: Task<Void, Never>] = [:]
    private var performanceTimerFires: UInt64?

    init(
        configuration: ClipboardHistoryConfiguration,
        environment: ClipboardHistoryServiceEnvironment = .init()
    ) {
        self.configuration = configuration
        self.environment = environment
        store = ClipboardHistoryStore(configuration: configuration)
        reader = ClipboardPasteboardReader(provider: environment.capturePasteboard)
        lastChangeCount = environment.pasteboardChangeCount()
    }

    func updateConfiguration(_ configuration: ClipboardHistoryConfiguration) {
        configurationGeneration &+= 1
        captureGeneration &+= 1
        let generation = configurationGeneration
        self.configuration = configuration
        reader = ClipboardPasteboardReader(provider: environment.capturePasteboard)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshots = await store.updateConfiguration(configuration)
            guard generation == configurationGeneration else { return }
            applyPaletteItems(self.configuration.isEnabled ? snapshots : [])
        }
        if configuration.isEnabled {
            start()
        } else {
            stop()
            applyPaletteItems([])
        }
    }

    func start() {
        guard configuration.isEnabled, timer == nil, monitoringSuspensions == 0 else { return }
        lastChangeCount = environment.pasteboardChangeCount()
        resumeMonitoring()
        let generation = captureGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshots = await store.load()
            guard generation == captureGeneration else { return }
            applyPaletteItems(configuration.isEnabled ? snapshots : [])
        }
    }

    func stop() {
        pauseMonitoring()
        captureGeneration &+= 1
    }

    func beginPerformanceCapture() {
        performanceTimerFires = 0
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        performanceTimerFires.map { PerformanceSnapshot(timerFires: $0) }
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        let snapshot = performanceSnapshot()
        performanceTimerFires = nil
        return snapshot
    }

    func copyItemToPasteboard(id: UUID, plainText: Bool = false) async -> Bool {
        let text: String?
        if plainText {
            guard let item = await store.item(id: id) else { return false }
            guard let plainText = await Task.detached(priority: .utility, operation: {
                ClipboardHistoryPasteboard.fullPlainText(from: item)
            }).value else { return false }
            text = plainText
        } else {
            text = nil
        }
        guard configuration.isEnabled,
              let item = await store.itemForUse(id: id)
        else {
            return false
        }
        let didWrite = if let text {
            environment.writePlainTextPasteboard(text, item)
        } else {
            environment.writePasteboard(item)
        }
        let snapshots = await store.paletteItems()
        applyPaletteItems(snapshots)
        return didWrite
    }

    func deleteItem(id: UUID) async -> [ClipboardPaletteItem] {
        let snapshots = await store.delete(id: id)
        applyPaletteItems(snapshots)
        return snapshots
    }

    func setPinned(_ pinned: Bool, id: UUID) async -> [ClipboardPaletteItem] {
        let snapshots = await store.pin(id: id, isPinned: pinned)
        applyPaletteItems(snapshots)
        return snapshots
    }

    func preview(id: UUID) async -> ClipboardPalettePreview? {
        guard let item = await store.item(id: id) else { return nil }
        return await Task.detached(priority: .utility) {
            if let content = item.contents.first(where: { $0.kind == .image }),
               let data = ClipboardHistoryImageText.thumbnail(content.data)
            {
                return ClipboardPalettePreview.image(data)
            }
            if let text = ClipboardHistoryPasteboard.plainText(from: item) {
                return .text(ClipboardHistoryPasteboard.previewText(text))
            }
            let paths = item.contents
                .filter { $0.kind == .fileURL }
                .compactMap { URL(dataRepresentation: $0.data, relativeTo: nil)?.path }
            return .text(ClipboardHistoryPasteboard.previewText(
                paths.isEmpty ? item.title : paths.joined(separator: "\n")
            ))
        }.value
    }

    func clearHistory() async throws -> [ClipboardPaletteItem] {
        let changeCountAtClear = environment.pasteboardChangeCount()
        suspendMonitoring()
        defer { releaseMonitoring() }
        for task in Array(captureTasks.values) {
            await task.value
        }
        let clearEpoch = captureEpoch &+ 1
        let snapshots = try await store.clear(epoch: clearEpoch)
        captureGeneration &+= 1
        captureEpoch = clearEpoch
        lastChangeCount = max(lastChangeCount, changeCountAtClear)
        applyPaletteItems(snapshots)
        return snapshots
    }

    func flushForQuit() async throws {
        suspendMonitoring()
        for task in Array(captureTasks.values) {
            await task.value
        }
        stop()
        captureEpoch &+= 1
        await store.fenceCaptures(epoch: captureEpoch)
        for task in Array(imageRecognitionTasks.values) {
            await task.value
        }
        try await store.flush()
    }

    func resumeAfterCanceledQuit() {
        releaseMonitoring()
    }

    private func suspendMonitoring() {
        monitoringSuspensions += 1
        pauseMonitoring()
    }

    private func releaseMonitoring() {
        monitoringSuspensions -= 1
        guard monitoringSuspensions == 0 else { return }
        resumeMonitoring()
        pollPasteboard()
    }

    private func pauseMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func resumeMonitoring() {
        guard configuration.isEnabled, timer == nil, monitoringSuspensions == 0 else { return }
        timer = environment.makeTimer(0.5) { [weak self] in
            self?.pollPasteboard()
        }
    }

    private func pollPasteboard() {
        performanceTimerFires? &+= 1
        guard configuration.isEnabled, timer != nil, monitoringSuspensions == 0 else { return }
        let changeCount = environment.pasteboardChangeCount()
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        captureGeneration &+= 1
        let generation = captureGeneration
        let captureConfiguration = ClipboardPasteboardCaptureConfiguration(
            maxItemBytes: configuration.maxItemBytes,
            sourceBundleIdentifier: environment.frontmostBundleIdentifier(),
            capturedAt: environment.date(),
            ignoredTypes: Set(configuration.ignoredTypes)
        )
        let epoch = captureEpoch
        let reader = reader
        captureTasks[generation] = Task { @MainActor [weak self] in
            let capture = await reader.capture(configuration: captureConfiguration)
            guard let self else { return }
            defer { self.captureTasks.removeValue(forKey: generation) }
            guard generation == self.captureGeneration,
                  self.configuration.isEnabled,
                  let capture
            else {
                return
            }
            let snapshots = await self.store.handleCapture(capture, epoch: epoch)
            guard generation == self.captureGeneration,
                  epoch == self.captureEpoch,
                  self.configuration.isEnabled
            else {
                return
            }
            self.applyPaletteItems(snapshots)
            await self.recognizeImageTextIfNeeded(capture, generation: generation, epoch: epoch)
        }
    }

    private func recognizeImageTextIfNeeded(
        _ capture: ClipboardPasteboardCapture,
        generation: Int,
        epoch: Int
    ) async {
        guard let content = capture.contents.first(where: { $0.kind == .image }),
              let item = await store.item(matching: capture),
              generation == captureGeneration,
              epoch == captureEpoch,
              item.recognizedText == nil,
              imageRecognitionTasks[item.id] == nil
        else {
            return
        }
        let id = item.id
        let digest = item.digest
        let provider = environment.recognizeImageText
        imageRecognitionTasks[id] = Task.detached(priority: .utility) { [weak self] in
            let text = provider(content.data) ?? ""
            await self?.completeImageText(id: id, digest: digest, text: text)
        }
    }

    private func completeImageText(id: UUID, digest: String, text: String) async {
        let snapshots = await store.setRecognizedText(id: id, digest: digest, text: text)
        applyPaletteItems(snapshots)
        imageRecognitionTasks.removeValue(forKey: id)
    }

    private func applyPaletteItems(_ items: [ClipboardPaletteItem]) {
        paletteItems = items
        onPaletteItemsChanged?(items)
    }
}

enum ClipboardHistoryImageText {
    static func recognize(_ data: Data) -> String? {
        guard let data = thumbnail(data) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        let handler = VNImageRequestHandler(data: data)
        guard (try? handler.perform([request])) != nil else { return nil }
        let text = request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        return text?.isEmpty == false ? text : nil
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
