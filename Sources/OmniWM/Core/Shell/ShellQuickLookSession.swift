// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuickLookUI

@MainActor
final class ShellQuickLookSession: NSResponder, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    private let items: [NSURL]
    private let index: Int
    private let source: ShellDesktopSource
    private var completion: ShellDesktopPlatform.PresentationCompletion?
    private weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private var panel: QLPreviewPanel?
    private var endFocus: ShellDesktopSource.FocusEnd?
    private var closing = false
    private var failure: String?

    init(
        urls: [URL],
        index: Int,
        source: ShellDesktopSource,
        completion: @escaping ShellDesktopPlatform.PresentationCompletion
    ) {
        items = urls.map { $0 as NSURL }
        self.index = index
        self.source = source
        self.completion = completion
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present() throws {
        guard source.isCurrent(), let parent = source.window, parent.isVisible else {
            throw ShellResourceFailure("source_surface_unavailable")
        }
        guard !items.isEmpty, index > 0, index <= items.count, let panel = QLPreviewPanel.shared() else {
            throw ShellResourceFailure("preview_unavailable")
        }
        guard panel.currentController == nil, !panel.isVisible else { throw ShellResourceFailure("quicklook_busy") }
        self.panel = panel
        self.parent = parent
        endFocus = try source.beginFocus(panel)
        previousResponder = parent.nextResponder
        nextResponder = previousResponder
        parent.nextResponder = self
        panel.updateController()
        guard (panel.currentController as AnyObject?) === self else {
            detachResponder()
            finish("preview_unavailable")
            return
        }
        panel.currentPreviewItemIndex = index - 1
        panel.makeKeyAndOrderFront(nil)
    }

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated {
            !closing && completion != nil && source.isCurrent() && self.panel === panel
        }
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard self.panel === panel else { return }
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard self.panel === panel else { return }
            if (panel.dataSource as AnyObject?) === self { panel.dataSource = nil }
            if (panel.delegate as AnyObject?) === self { panel.delegate = nil }
            detachResponder()
            finish(failure, resume: closing)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? QLPreviewPanel, panel === closed else { return }
        dismiss(nil, orderOut: false)
    }

    func cancel() {
        dismiss("cancelled", orderOut: true)
    }

    private func dismiss(_ error: String?, orderOut: Bool) {
        guard completion != nil, !closing else { return }
        closing = true
        failure = error
        guard let panel else { finish(error)
            return
        }
        if orderOut, (panel.currentController as AnyObject?) === self { panel.orderOut(nil) }
        detachResponder()
        panel.updateController()
        if (panel.currentController as AnyObject?) !== self { finish(error) }
    }

    private func detachResponder() {
        if parent?.nextResponder === self { parent?.nextResponder = previousResponder }
        nextResponder = nil
    }

    private func finish(_ error: String?, resume: Bool = true) {
        guard let completion else { return }
        self.completion = nil
        let endFocus = endFocus
        self.endFocus = nil
        endFocus?(resume)
        self.panel = nil
        completion(error)
    }
}
