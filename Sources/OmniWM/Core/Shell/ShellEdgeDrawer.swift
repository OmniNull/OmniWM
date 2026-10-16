// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellEdgeDrawer {
    struct Section {
        let widget: String
        let key: ShellBarKey
        let surface: ShellWidgetSurface
    }

    static let padding: CGFloat = 12
    static let spacing: CGFloat = 12
    static let margin: CGFloat = 8
    static let radius: CGFloat = 14
    static let slide: CFTimeInterval = 0.18
    static let slop: CGFloat = 25
    static let overshoot: CGFloat = 0.12

    struct Member {
        let widget: String
        let key: ShellBarKey
        let directories: [URL]
    }

    let id: String
    let edge: ShellDrawerConfig.Edge
    let chrome: Bool
    let sections: [Section]
    let panel: ShellPopoutPanel
    private let screen: NSScreen
    private let area: CGRect
    private let resources: ShellResources
    private let dismissal = PanelDismissalMonitor()
    private var target: CGRect?
    private var opened: Set<Int> = []

    init(
        id: String,
        edge: ShellDrawerConfig.Edge,
        chrome: Bool = true,
        screen: NSScreen,
        area: CGRect? = nil,
        resources: ShellResources,
        members: [Member],
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.edge = edge
        self.chrome = chrome
        self.screen = screen
        self.area = area ?? screen.visibleFrame
        self.resources = resources
        sections = members.map { member in
            Section(
                widget: member.widget,
                key: member.key,
                surface: ShellWidgetSurface(
                    scale: screen.backingScaleFactor,
                    resources: resources,
                    directories: member.directories
                )
            )
        }
        let stack = ShellDrawerStack()
        for section in sections {
            stack.addSubview(section.surface.view)
        }
        panel = ShellPopoutPanel(content: stack)
        dismissal.start(
            panels: [panel], isExemptWindow: { _ in false },
            shouldHandleEscape: { [weak self] in self?.sections.contains { $0.surface.hasFocusedTextInput } != true },
            onDismiss: onDismiss
        )
    }

    var monitor: Monitor.ID? {
        sections.first?.key.monitor
    }

    func section(widget: String, key: ShellBarKey) -> Section? {
        sections.first { $0.widget == widget && $0.key == key }
    }

    func apply(
        widget: String,
        key: ShellBarKey,
        _ output: [UInt8],
        text: ShellTextStore,
        gestureAcknowledgement: UInt64 = 0
    ) -> Bool {
        guard let index = sections.firstIndex(where: { $0.widget == widget && $0.key == key }) else { return false }
        let surface = sections[index].surface
        if opened.insert(index).inserted {
            surface.setTransition(.opening(
                ShellWireDecoder.rootTiming(output),
                standard: fadeDuration(Self.slide),
                at: CACurrentMediaTime()
            ))
        }
        guard surface.apply(output, text: text, gestureAcknowledgement: gestureAcknowledgement) else { return false }
        layout()
        return true
    }

    func reset(widget: String, text: ShellTextStore) {
        sections.filter { $0.widget == widget }.forEach { $0.surface.reset(text: text) }
    }

    @discardableResult
    func close(animated: Bool, onClosed: @escaping @MainActor () -> Void = {}) -> Bool {
        dismissal.stop()
        target = nil
        let now = CACurrentMediaTime()
        var longest: CFTimeInterval = 0
        var holds = false
        for section in sections {
            section.surface.blurDeclaredFocus()
            section.surface.cancelInput()
            let timing = section.surface.timing
            let closing = ShellShaderTransition.closing(
                from: section.surface.transition.progress(at: now),
                timing,
                standard: fadeDuration(0.12),
                at: now
            )
            holds = holds || timing.close != nil || !chrome
            longest = max(longest, closing.duration)
            if animated {
                section.surface.setTransition(closing)
            }
        }
        guard animated, longest > 0, panel.isVisible else {
            panel.hide(fadeDuration: nil)
            return true
        }
        panel.hide(fadeDuration: longest, holdsUntilEnd: holds, onHidden: onClosed)
        return false
    }

    func finishClose() {
        panel.hide(fadeDuration: nil)
    }

    static func frame(size: CGSize, edge: ShellDrawerConfig.Edge, visibleFrame: CGRect) -> CGRect {
        let width = min(size.width, visibleFrame.width - margin * 2)
        let height = min(size.height, visibleFrame.height - margin * 2)
        let x = switch edge {
        case .left: visibleFrame.minX + margin
        case .right: visibleFrame.maxX - margin - width
        case .top,
             .bottom: visibleFrame.midX - width / 2
        }
        let y = switch edge {
        case .bottom: visibleFrame.minY + margin
        case .top: visibleFrame.maxY - margin - height
        case .left,
             .right: visibleFrame.midY - height / 2
        }
        return CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    static func area(_ visible: CGRect, beside bar: CGRect?) -> CGRect {
        guard let bar, bar.intersects(visible) else { return visible }
        var area = visible
        if bar.width >= bar.height {
            if bar.midY > visible.midY {
                area.size.height = max(0, bar.minY - area.minY)
            } else {
                area.size.height = max(0, area.maxY - bar.maxY)
                area.origin.y = bar.maxY
            }
        } else if bar.midX < visible.midX {
            area.size.width = max(0, area.maxX - bar.maxX)
            area.origin.x = bar.maxX
        } else {
            area.size.width = max(0, bar.minX - area.minX)
        }
        return area
    }

    static func flush(size: CGSize, edge: ShellDrawerConfig.Edge, area: CGRect) -> (panel: CGRect, content: CGRect) {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        let room = ((edge == .top || edge == .bottom ? height : width) * overshoot).rounded()
        let x = switch edge {
        case .left: area.minX
        case .right: area.maxX - width
        case .top,
             .bottom: area.midX - width / 2
        }
        let y = switch edge {
        case .top: area.maxY - height
        case .bottom: area.minY
        case .left,
             .right: area.midY - height / 2
        }
        let content = CGRect(x: x, y: y, width: width, height: height).integral
        let panel = switch edge {
        case .top: CGRect(x: content.minX, y: content.minY - room, width: width, height: height + room)
        case .bottom: CGRect(x: content.minX, y: content.minY, width: width, height: height + room)
        case .left: CGRect(x: content.minX, y: content.minY, width: width + room, height: height)
        case .right: CGRect(x: content.minX - room, y: content.minY, width: width + room, height: height)
        }
        return (panel, content)
    }

    private var shown: Bool {
        target != nil
    }

    var holdRegion: CGRect? {
        guard let frame = target else { return nil }
        let screen = screen.frame
        return switch edge {
        case .top: CGRect(
                x: frame.minX - Self.slop,
                y: frame.minY,
                width: frame.width + Self.slop * 2,
                height: screen.maxY - frame.minY
            )
        case .bottom: CGRect(
                x: frame.minX - Self.slop,
                y: screen.minY,
                width: frame.width + Self.slop * 2,
                height: frame.maxY - screen.minY
            )
        case .left: CGRect(
                x: screen.minX,
                y: frame.minY - Self.slop,
                width: frame.maxX - screen.minX,
                height: frame.height + Self.slop * 2
            )
        case .right: CGRect(
                x: frame.minX,
                y: frame.minY - Self.slop,
                width: screen.maxX - frame.minX,
                height: frame.height + Self.slop * 2
            )
        }
    }

    static func hiddenFrame(_ frame: CGRect, edge: ShellDrawerConfig.Edge) -> CGRect {
        switch edge {
        case .left: frame.offsetBy(dx: -(frame.width + margin), dy: 0)
        case .right: frame.offsetBy(dx: frame.width + margin, dy: 0)
        case .top: frame.offsetBy(dx: 0, dy: frame.height + margin)
        case .bottom: frame.offsetBy(dx: 0, dy: -(frame.height + margin))
        }
    }

    private func layout() {
        let visible = sections.filter { $0.surface.size.width > 0 && $0.surface.size.height > 0 }
        defer { for section in visible { section.surface.realizeTextInputFocus() } }
        guard !visible.isEmpty else {
            panel.hide(fadeDuration: nil)
            target = nil
            return
        }
        let padding = chrome ? Self.padding : 0
        let content = visible.map(\.surface.size.width).max() ?? 0
        var y = padding
        for section in sections {
            let size = section.surface.size
            let isVisible = size.width > 0 && size.height > 0
            section.surface.view.isHidden = !isVisible
            guard isVisible else { continue }
            section.surface.view.frame = CGRect(
                x: padding + (content - size.width) / 2,
                y: y,
                width: size.width,
                height: size.height
            )
            y += size.height + Self.spacing
        }
        let size = CGSize(width: content + padding * 2, height: y - Self.spacing + padding)
        guard chrome else {
            let flush = Self.flush(size: size, edge: edge, area: area)
            panel.show(
                frame: flush.panel,
                content: flush.content.offsetBy(dx: -flush.panel.minX, dy: -flush.panel.minY),
                level: .popUpMenu,
                chrome: ShellPopoutChrome(clear: true, radius: 0),
                fadeDuration: nil,
                morph: shown ? visible.lazy.compactMap(\.surface.rootAnimation).first : nil
            )
            target = flush.panel
            return
        }
        let frame = Self.frame(size: size, edge: edge, visibleFrame: screen.visibleFrame)
        let explicit = sections.compactMap(\.surface.timing.open).max()
        let fade = shown ? nil : explicit.map { $0 > 0 ? $0 : nil } ?? fadeDuration(Self.slide)
        panel.show(
            frame: frame,
            level: .popUpMenu,
            chrome: ShellPopoutChrome(radius: Self.radius),
            fadeDuration: fade,
            from: fade == nil ? nil : Self.hiddenFrame(frame, edge: edge),
            morph: shown ? visible.lazy.compactMap(\.surface.rootAnimation).first : nil
        )
        target = frame
    }

    private func fadeDuration(_ duration: TimeInterval) -> TimeInterval? {
        resources.motion.animationsEnabled ? duration / resources.motion.animationSpeed : nil
    }
}

private final class ShellDrawerStack: NSView {
    override var isFlipped: Bool {
        true
    }
}
