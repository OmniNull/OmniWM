// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct KeyboardModeGuideEntry: Equatable, Identifiable {
    let key: String
    let title: String

    var id: String {
        key
    }
}

@MainActor
final class KeyboardModeIndicatorController {
    static let bottomInset: CGFloat = 24
    static let sideInset: CGFloat = 24

    private typealias Surface = (panel: NSPanel, hostingView: NSHostingView<KeyboardModeIndicatorView>)

    private let ownedWindowRegistry: OwnedWindowRegistry
    private var surfaces: [Monitor.ID: Surface] = [:]
    private(set) var kind = KeyboardModeKind.normal
    private(set) var guideMonitorId: Monitor.ID?

    init(ownedWindowRegistry: OwnedWindowRegistry = .shared) {
        self.ownedWindowRegistry = ownedWindowRegistry
    }

    isolated deinit {
        destroy()
    }

    func show(
        kind: KeyboardModeKind,
        name: String? = nil,
        guide: [KeyboardModeGuideEntry],
        monitors: [Monitor],
        interactionMonitorId: Monitor.ID?
    ) {
        guard kind != .normal else {
            hide()
            return
        }
        if kind != self.kind || !monitors.contains(where: { $0.id == guideMonitorId }) {
            guideMonitorId = interactionMonitorId
        }
        self.kind = kind
        for monitorId in surfaces.keys where !monitors.contains(where: { $0.id == monitorId }) {
            destroySurface(monitorId)
        }
        for monitor in monitors {
            let (panel, hostingView) = surfaces[monitor.id] ?? makeSurface(for: monitor.id)
            hostingView.rootView = KeyboardModeIndicatorView(
                kind: kind,
                name: name,
                guide: monitor.id == guideMonitorId ? guide : [],
                maxWidth: monitor.visibleFrame.width - 2 * Self.sideInset
            )
            panel.setFrame(
                Self.panelFrame(size: hostingView.fittingSize, visibleFrame: monitor.visibleFrame),
                display: true
            )
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        kind = .normal
        guideMonitorId = nil
        for surface in surfaces.values {
            surface.panel.orderOut(nil)
        }
    }

    func destroy() {
        hide()
        for monitorId in Array(surfaces.keys) {
            destroySurface(monitorId)
        }
    }

    static func surfaceId(for monitorId: Monitor.ID) -> String {
        "keyboard-mode-indicator-\(monitorId.displayId)"
    }

    static func panelFrame(size: CGSize, visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + bottomInset,
            width: size.width,
            height: size.height
        )
    }

    private func destroySurface(_ monitorId: Monitor.ID) {
        guard let surface = surfaces.removeValue(forKey: monitorId) else { return }
        surface.panel.orderOut(nil)
        ownedWindowRegistry.unregister(surfaceId: Self.surfaceId(for: monitorId))
        surface.panel.close()
    }

    private func makeSurface(for monitorId: Monitor.ID) -> Surface {
        let panel = KeyboardModeIndicatorPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hostingView = NSHostingView(rootView: KeyboardModeIndicatorView(
            kind: kind,
            name: nil,
            guide: [],
            maxWidth: 0
        ))
        panel.contentView = hostingView
        ownedWindowRegistry.register(
            panel,
            surfaceId: Self.surfaceId(for: monitorId),
            policy: SurfacePolicy(
                kind: .keyboardModeIndicator,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        let surface = (panel: panel as NSPanel, hostingView: hostingView)
        surfaces[monitorId] = surface
        return surface
    }
}

private final class KeyboardModeIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

struct KeyboardModeIndicatorView: View {
    static let rowsPerColumn = 12
    static let maxColumns = 2
    private static let keyWidth: CGFloat = 44
    private static let maxTitleWidth: CGFloat = 220
    private static let cardPadding: CGFloat = 12
    private static let columnSpacing: CGFloat = 16

    let kind: KeyboardModeKind
    let name: String?
    let guide: [KeyboardModeGuideEntry]
    let maxWidth: CGFloat

    static func shownGuide(_ guide: [KeyboardModeGuideEntry]) -> ArraySlice<KeyboardModeGuideEntry> {
        guide.prefix(rowsPerColumn * maxColumns)
    }

    static func titleWidth(columns: Int, maxWidth: CGFloat) -> CGFloat {
        let columns = CGFloat(max(columns, 1))
        let available = maxWidth - 2 * cardPadding - (columns - 1) * columnSpacing
        return max(0, min(maxTitleWidth, available / columns - keyWidth - 8))
    }

    var body: some View {
        VStack(spacing: 8) {
            if !guide.isEmpty {
                guideCard
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Color(nsColor: StatusBarController.keyboardModeColor(kind)), in: Capsule())
        }
        .fixedSize()
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .paused: "Shortcuts paused"
        case .prefix: "Prefix · Escape cancels"
        case .normal,
             .window: "Window mode · Escape exits"
        case .named: "\(name ?? "Key mode") · Escape exits"
        }
    }

    private var guideCard: some View {
        let shown = Self.shownGuide(guide)
        let starts = Array(stride(from: shown.startIndex, to: shown.endIndex, by: Self.rowsPerColumn))
        let titleWidth = Self.titleWidth(columns: starts.count, maxWidth: maxWidth)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                ForEach(starts, id: \.self) { start in
                    guideColumn(
                        shown[start ..< min(start + Self.rowsPerColumn, shown.endIndex)],
                        titleWidth: titleWidth
                    )
                }
            }
            if guide.count > shown.count {
                Text("More: \(guide.count - shown.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Self.cardPadding)
        .omniGlassEffect(in: RoundedRectangle(cornerRadius: 12))
    }

    private func guideColumn(
        _ entries: ArraySlice<KeyboardModeGuideEntry>,
        titleWidth: CGFloat
    ) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(entries) { entry in
                GridRow {
                    Text(verbatim: entry.key)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .frame(width: Self.keyWidth)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    Text(verbatim: entry.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: titleWidth, alignment: .leading)
                }
            }
        }
    }
}
