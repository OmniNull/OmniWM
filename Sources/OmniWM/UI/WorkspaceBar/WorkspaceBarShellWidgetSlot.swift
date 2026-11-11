// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
struct ShellWidgetSlot: View {
    let widget: WorkspaceBarShellWidget
    let view: NSView?
    var cuttable = false

    var body: some View {
        ShellWidgetSlotHost(widget: widget, view: view, cuttable: cuttable)
            .id(view.map(ObjectIdentifier.init))
    }
}

@MainActor
private struct ShellWidgetFailureBadge: View {
    let name: String
    let failure: ShellWidgetFailure

    var body: some View {
        Button {
            let source = failure.source
            NSWorkspace.shared.open(source, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error != nil else { return }
                Task { @MainActor in
                    NSWorkspace.shared.activateFileViewerSelecting([source])
                }
            }
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: "\(name): \(failure.message)"))
    }
}

@MainActor
private struct ShellWidgetSlotHost: NSViewRepresentable {
    let widget: WorkspaceBarShellWidget
    let view: NSView?
    let cuttable: Bool

    func makeNSView(context _: Context) -> ShellWidgetClipView {
        ShellWidgetClipView(content: view)
    }

    func updateNSView(_ clip: ShellWidgetClipView, context _: Context) {
        update(clip)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView clip: ShellWidgetClipView, context _: Context) -> CGSize? {
        update(clip)
        let natural = clip.natural
        guard cuttable else { return natural }
        return CGSize(
            width: min(proposal.width ?? natural.width, natural.width),
            height: min(proposal.height ?? natural.height, natural.height)
        )
    }

    private func update(_ clip: ShellWidgetClipView) {
        clip.update(
            surface: widget.size,
            badge: widget.failure.map { ShellWidgetFailureBadge(name: widget.id, failure: $0) },
            keepsEnd: widget.lane == .trailing
        )
    }
}

final class ShellWidgetClipView: NSView {
    static let badgeGap: CGFloat = 4

    let content: NSView?
    private var badge: NSHostingView<ShellWidgetFailureBadge>?
    private var surface = CGSize.zero
    private var keepsEnd = false

    init(content: NSView?) {
        self.content = content
        super.init(frame: .zero)
        if let content { addSubview(content) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    var badgeView: NSView? {
        badge
    }

    var natural: CGSize {
        guard let badge else { return surface }
        let mark = badge.fittingSize
        guard surface.width > 0, surface.height > 0 else { return mark }
        return CGSize(width: mark.width + Self.badgeGap + surface.width, height: max(mark.height, surface.height))
    }

    var isCut: Bool {
        let natural = natural
        return bounds.width < natural.width || bounds.height < natural.height
    }

    fileprivate func update(surface: CGSize, badge mark: ShellWidgetFailureBadge?, keepsEnd: Bool) {
        var changed = surface != self.surface || keepsEnd != self.keepsEnd
        self.surface = surface
        self.keepsEnd = keepsEnd
        switch (badge, mark) {
        case let (nil, mark?):
            let host = NSHostingView(rootView: mark)
            addSubview(host)
            badge = host
            changed = true
        case let (host?, mark?):
            host.rootView = mark
        case let (host?, nil):
            host.removeFromSuperview()
            badge = nil
            changed = true
        case (nil, nil):
            break
        }
        if changed { applyCut() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyCut()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        if let superview {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(superviewMoved),
                name: NSView.frameDidChangeNotification,
                object: superview
            )
        }
    }

    @objc private func superviewMoved() {
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: self)
    }

    private func applyCut() {
        if let content, content.superview !== self { return }
        let natural = natural
        clipsToBounds = isCut
        let origin = keepsEnd
            ? CGPoint(x: min(0, bounds.width - natural.width), y: min(0, bounds.height - natural.height))
            : .zero
        var x = origin.x
        if let badge {
            let mark = badge.fittingSize
            badge.frame = CGRect(
                origin: CGPoint(x: x, y: origin.y + (natural.height - mark.height) / 2),
                size: mark
            )
            x += mark.width + Self.badgeGap
        }
        content?.frame = CGRect(
            origin: CGPoint(x: x, y: origin.y + (natural.height - surface.height) / 2),
            size: surface
        )
        if let content = content as? ShellSurfaceView {
            let shown = content.bounds.intersection(content.convert(bounds, from: self))
            if let surface = content.surface {
                surface.setRootLimit(isCut && !keepsEnd && surface.hasMarquee ? shown.size : nil)
                surface.setVisibleBounds(isCut ? shown : nil)
            }
        }
    }
}
