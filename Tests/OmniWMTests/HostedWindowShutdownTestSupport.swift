// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM

actor HostedShutdownRetirementGate {
    private let entered: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(entered: @escaping @Sendable () -> Void) {
        self.entered = entered
    }

    func hold() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

extension ShellWidgetPackage {
    func gateHostedRetirement(_ gate: HostedShutdownRetirementGate) -> Bool {
        guard providerReconciliation == nil else { return false }
        providerReconciliation = Task {
            await gate.hold()
            providerReconciliation = nil
        }
        return true
    }
}

@MainActor
final class HostedShutdownClipboard {
    final class Timer: ClipboardHistoryTimer {
        var action: (@MainActor () -> Void)?

        func fire() {
            action?()
        }

        func invalidate() {
            action = nil
        }
    }

    private final class PasteboardState {
        var changeCount = 0
    }

    let directory: URL
    let configuration: ClipboardHistoryConfiguration
    let service: ClipboardHistoryService
    let value: String
    let timer = Timer()
    private let pasteboard = PasteboardState()

    init(value: String = "Clipboard history retained after a canceled quit") throws {
        self.value = value
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostedWindowShutdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = ClipboardHistoryContent(
            itemIndex: 0, type: NSPasteboard.PasteboardType.string.rawValue,
            kind: .text, data: Data(value.utf8)
        )
        let contents = [content]
        configuration = ClipboardHistoryConfiguration(
            isEnabled: true, maxItems: contents.count,
            maxItemBytes: content.data.count, maxTotalBytes: content.data.count,
            storageDirectory: directory
        )
        let capture = ClipboardPasteboardCapture(
            contents: contents, sourceBundleIdentifier: nil, capturedAt: .distantPast
        )
        let timer = timer
        let pasteboard = pasteboard
        var environment = ClipboardHistoryServiceEnvironment()
        environment.pasteboardChangeCount = { pasteboard.changeCount }
        environment.frontmostBundleIdentifier = { nil }
        environment.capturePasteboard = { _ in capture }
        environment.makeTimer = { _, action in
            timer.action = action
            return timer
        }
        service = ClipboardHistoryService(configuration: configuration, environment: environment)
    }

    func preventSaving() throws {
        try FileManager.default.createDirectory(at: configuration.storageURL, withIntermediateDirectories: false)
    }

    func capture() {
        service.start()
        pasteboard.changeCount += 1
        timer.fire()
    }

    func close() throws {
        service.stop()
        try FileManager.default.removeItem(at: directory)
    }
}
