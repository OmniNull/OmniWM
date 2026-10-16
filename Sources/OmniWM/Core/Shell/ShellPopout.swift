// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

struct ShellPopoutDrawer {
    let placement: HiddenBarPanelPlacement
    let isExemptWindow: @MainActor (NSWindow) -> Bool
    let onJoin: @MainActor (HiddenBarPanelPlacement.Join?) -> Void
}

struct ShellPopoutGeometry: Equatable {
    let panel: CGRect
    let content: CGRect
    let source: CGRect?

    static func make(content: CGRect, anchor: ShellAnchor, bridge: Bool) -> ShellPopoutGeometry {
        guard bridge, let bar = anchor.container else {
            return ShellPopoutGeometry(panel: content, content: content, source: nil)
        }
        let source = bar.width >= bar.height
            ? CGRect(x: anchor.frame.minX, y: bar.minY, width: anchor.frame.width, height: bar.height)
            : CGRect(x: bar.minX, y: anchor.frame.minY, width: bar.width, height: anchor.frame.height)
        return ShellPopoutGeometry(panel: content.union(source), content: content, source: source)
    }

    var bleed: Insets {
        Insets(
            left: Float(content.minX - panel.minX),
            top: Float(panel.maxY - content.maxY),
            right: Float(panel.maxX - content.maxX),
            bottom: Float(content.minY - panel.minY)
        )
    }

    var contentInPanel: CGRect {
        content.offsetBy(dx: -panel.minX, dy: -panel.minY)
    }

    func stage(anchor: CGRect) -> ShellShaderStage {
        let source = source ?? anchor
        return ShellShaderStage(
            anchor: CGPoint(x: source.midX - content.minX, y: content.maxY - source.midY),
            content: CGRect(origin: .zero, size: content.size)
        )
    }

    func surfacePoint(_ screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: screenPoint.x - content.minX, y: content.maxY - screenPoint.y)
    }
}

struct ShellAnchorSource {
    weak var surface: ShellWidgetSurface?
    let element: ElementHandle
}

@MainActor
final class ShellPopout {
    private enum Chrome {
        case popover(ShellPopoutPanel)
        case drawer(ShellDrawerChrome)
    }

    let widget: String
    let key: ShellBarKey
    let surface: ShellWidgetSurface
    private let chrome: Chrome
    private let anchor: ShellAnchor
    private let source: ShellAnchorSource?
    private var placedAnchor: CGRect?
    private var closing = false
    private let edge: PopupAttachment.Edge?
    let screen: NSScreen
    private let resources: ShellResources
    private let fitsAroundAnchor: Bool
    private let dismissal = PanelDismissalMonitor()
    private weak var companion: ShellPopout?
    private var opened = false
    private var onClosed: (@MainActor () -> Void)?
    private var geometry: ShellPopoutGeometry?
    private var pointerMonitors: [Any] = []

    init(
        widget: String,
        key: ShellBarKey,
        anchor: ShellAnchor,
        source: ShellAnchorSource? = nil,
        edge: PopupAttachment.Edge? = nil,
        screen: NSScreen,
        resources: ShellResources,
        directories: [URL],
        drawer: ShellPopoutDrawer? = nil,
        tracksDismissal: Bool = true,
        fitsAroundAnchor: Bool = false,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.widget = widget
        self.key = key
        self.anchor = anchor
        self.source = source
        self.edge = edge
        self.screen = screen
        self.resources = resources
        self.fitsAroundAnchor = fitsAroundAnchor
        surface = ShellWidgetSurface(scale: screen.backingScaleFactor, resources: resources, directories: directories)
        guard let drawer else {
            let panel = ShellPopoutPanel(content: surface.view)
            chrome = .popover(panel)
            surface.onShapeChange = { [weak self] in
                self?.pointerMoved()
            }
            if tracksDismissal {
                monitorPopoverDismissal(panel, onDismiss: onDismiss)
            }
            return
        }
        surface.focusAxis = Self.focusAxis(of: drawer.placement)
        let chrome = ShellDrawerChrome(
            content: surface.view,
            placement: drawer.placement,
            motion: resources.motion,
            onJoin: drawer.onJoin
        )
        self.chrome = .drawer(chrome)
        if tracksDismissal {
            dismissal.start(
                panels: [chrome.panel],
                isExemptWindow: drawer.isExemptWindow,
                containsPanelPoint: { [weak self] panel, point in
                    self?.contains(screenPoint: point, in: panel) == true
                },
                shouldHandleEscape: { [weak self] in self?.surface.hasFocusedTextInput != true },
                shouldDismissOnScreenChange: { [weak self] in self?.companion == nil },
                onDismiss: onDismiss
            )
        }
    }

    private func monitorPopoverDismissal(
        _ panel: ShellPopoutPanel, onDismiss: @escaping @MainActor () -> Void
    ) {
        dismissal.start(
            panels: [panel],
            isExemptWindow: { [weak self] _ in
                self?.currentAnchor.frame.contains(NSEvent.mouseLocation) == true
            },
            containsPanelPoint: { [weak self] panel, point in
                self?.contains(screenPoint: point, in: panel) ?? true
            },
            shouldHandleEscape: { [weak self] in self?.surface.hasFocusedTextInput != true },
            shouldDismissOnScreenChange: { [weak self] in self?.companion == nil },
            onDismiss: onDismiss
        )
    }

    var onKeyboardFocus: (@MainActor (Bool) -> Void)? {
        get { if case let .drawer(drawer) = chrome { drawer.onKeyboardFocus } else { nil } }
        set { if case let .drawer(drawer) = chrome { drawer.onKeyboardFocus = newValue } }
    }

    var panel: NSPanel {
        switch chrome {
        case let .popover(panel): panel
        case let .drawer(drawer): drawer.panel
        }
    }

    var drawerPlacement: HiddenBarPanelPlacement? {
        guard case let .drawer(drawer) = chrome else { return nil }
        return drawer.placement
    }

    func move(to placement: HiddenBarPanelPlacement) {
        guard case let .drawer(drawer) = chrome else { return }
        surface.focusAxis = Self.focusAxis(of: placement)
        drawer.move(to: placement)
    }

    func setCompanion(_ companion: ShellPopout?) {
        self.companion = companion
        dismissal.updatePanels([panel] + (companion.map { [$0.panel] } ?? []))
    }

    func contains(screenPoint point: CGPoint, in panel: NSPanel) -> Bool {
        if let companion, companion.panel === panel {
            return companion.contains(screenPoint: point)
        }
        guard self.panel === panel else { return false }
        switch chrome {
        case .popover: return contains(screenPoint: point)
        case let .drawer(drawer): return drawer.contains(screenPoint: point)
        }
    }

    private var currentAnchor: ShellAnchor {
        source.flatMap { $0.surface?.liveAnchor(of: $0.element) } ?? anchor
    }

    func refreshAnchor() {
        guard case let .popover(panel) = chrome, !closing, panel.isVisible, let placedAnchor,
              currentAnchor.frame != placedAnchor
        else {
            return
        }
        place(panel, size: surface.naturalSize, morph: nil)
    }

    func apply(_ output: [UInt8], text: ShellTextStore, gestureAcknowledgement: UInt64 = 0) -> Bool {
        let opening = !opened
        let timing = opening ? ShellWireDecoder.rootTiming(output) : surface.timing
        if opening {
            opened = true
            let standard = switch chrome {
            case .popover: fadeDuration(0.35)
            case .drawer: fadeDuration(HiddenBarDrawerView.opening.duration)
            }
            surface.setTransition(.opening(timing, standard: standard, at: CACurrentMediaTime()))
        }
        guard surface.apply(output, text: text, gestureAcknowledgement: gestureAcknowledgement) else { return false }
        let size = surface.naturalSize
        defer { surface.realizeTextInputFocus() }
        switch chrome {
        case let .popover(panel):
            guard size.width > 0, size.height > 0 else {
                panel.hide(fadeDuration: nil)
                return true
            }
            place(panel, size: size, morph: opening ? nil : surface.rootAnimation)
        case let .drawer(drawer):
            guard size.width > 0, size.height > 0 else {
                drawer.close(animated: false)
                return true
            }
            let placement = drawer.placement
            drawer.show(
                size: Self.fitted(size, attachment: placement.attachment, visibleFrame: placement.visibleFrame),
                level: Self.level(above: anchor),
                duration: opening ? timing.open : nil
            )
        }
        return true
    }

    private func place(_ panel: ShellPopoutPanel, size: CGSize, morph: ShellAnimation?) {
        let anchor = currentAnchor
        placedAnchor = anchor.frame
        let gap = surface.attaches ? 0 : PopupAttachment.gap
        let attachment = fitsAroundAnchor
            ? Self.fittedAttachment(anchor: anchor, size: size, visibleFrame: screen.visibleFrame, gap: gap)
            : Self.attachment(anchor: anchor, edge: edge, screen: screen.frame)
        let fitted = Self.fitted(size, attachment: attachment, visibleFrame: screen.visibleFrame, gap: gap)
        surface.setRootLimit(fitted == size ? nil : fitted)
        let geometry = ShellPopoutGeometry.make(
            content: attachment.frame(size: fitted, visibleFrame: screen.visibleFrame, gap: gap),
            anchor: anchor,
            bridge: surface.bridges
        )
        self.geometry = geometry
        surface.setRootBleed(geometry.bleed)
        surface.setStage(geometry.stage(anchor: anchor.frame))
        panel.show(
            frame: geometry.panel,
            content: geometry.source == nil ? nil : geometry.contentInPanel,
            level: Self.level(above: anchor),
            chrome: surface.chrome,
            fadeDuration: fadeDuration(0.15),
            morph: morph
        )
        updatePassThrough(panel)
    }

    var isShaped: Bool {
        guard case .popover = chrome else { return false }
        return surface.chrome.clear || geometry?.source != nil
    }

    func contains(screenPoint point: CGPoint) -> Bool {
        guard isShaped, let geometry else { return panel.frame.contains(point) }
        return surface.containsShape(at: geometry.surfacePoint(point))
    }

    private func updatePassThrough(_ panel: ShellPopoutPanel) {
        guard isShaped else {
            removePointerMonitors()
            panel.ignoresMouseEvents = false
            return
        }
        if pointerMonitors.isEmpty {
            let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.pointerMoved()
                return event
            }
            let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pointerMoved()
                }
            }
            pointerMonitors = [local, global].compactMap(\.self)
        }
        pointerMoved()
    }

    private func pointerMoved() {
        guard case let .popover(panel) = chrome, isShaped else { return }
        panel.ignoresMouseEvents = !contains(screenPoint: NSEvent.mouseLocation)
    }

    private func removePointerMonitors() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors = []
    }

    @discardableResult
    func close(animated: Bool = true, onClosed: @escaping @MainActor () -> Void = {}) -> Bool {
        closing = true
        surface.blurDeclaredFocus()
        onKeyboardFocus?(false)
        surface.cancelInput()
        dismissal.stop()
        removePointerMonitors()
        surface.onShapeChange = nil
        let now = CACurrentMediaTime()
        let progress = surface.transition.progress(at: now)
        let timing = surface.timing
        switch chrome {
        case let .popover(panel):
            let shaped = surface.animatesShaders
            let closing = ShellShaderTransition.closing(
                from: progress,
                timing,
                standard: fadeDuration(shaped ? 0.25 * Double(progress) : 0.12),
                at: now
            )
            guard animated, closing.duration > 0, panel.isVisible else {
                panel.hide(fadeDuration: nil)
                return true
            }
            self.onClosed = onClosed
            surface.setTransition(closing)
            panel.hide(fadeDuration: closing.duration, holdsUntilEnd: shaped || timing.close != nil) { [weak self] in
                self?.finishClose()
            }
            return false
        case let .drawer(drawer):
            let closing = ShellShaderTransition.closing(
                from: progress,
                timing,
                standard: fadeDuration(HiddenBarDrawerView.closing.duration),
                at: now
            )
            guard animated, closing.duration > 0, drawer.isShown else {
                drawer.close(animated: false)
                return true
            }
            self.onClosed = onClosed
            surface.setTransition(closing)
            drawer.close(animated: true, duration: timing.close == nil ? nil : closing.duration) { [weak self] in
                self?.notifyClosed()
            }
            return false
        }
    }

    func finishClose() {
        switch chrome {
        case let .popover(panel): panel.hide(fadeDuration: nil)
        case let .drawer(drawer): drawer.finishClose()
        }
        notifyClosed()
    }

    private func notifyClosed() {
        let onClosed = onClosed
        self.onClosed = nil
        onClosed?()
    }

    private func fadeDuration(_ duration: TimeInterval) -> TimeInterval? {
        resources.motion.animationsEnabled ? duration / resources.motion.animationSpeed : nil
    }
}

extension ShellPopout {
    static func attachment(anchor: ShellAnchor, edge: PopupAttachment.Edge?, screen: CGRect) -> PopupAttachment {
        guard let edge, let container = anchor.container else {
            return PopupAttachment(sourceFrame: anchor.frame, edge: anchor.frame.midY > screen.midY ? .below : .above)
        }
        return PopupAttachment(
            sourceFrame: container,
            edge: edge,
            alignment: CGPoint(x: anchor.frame.midX, y: anchor.frame.midY)
        )
    }

    static func fittedAttachment(
        anchor: ShellAnchor,
        size: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat = PopupAttachment.gap
    ) -> PopupAttachment {
        let below = anchor.frame.midY > visibleFrame.midY
        let preferred = PopupAttachment(sourceFrame: anchor.frame, edge: below ? .below : .above)
        let opposite = PopupAttachment(sourceFrame: anchor.frame, edge: below ? .above : .below)
        let available = preferred.availableSize(in: visibleFrame, gap: gap).height
        return size.height > available && opposite.availableSize(in: visibleFrame, gap: gap).height > available
            ? opposite : preferred
    }

    private static func focusAxis(of placement: HiddenBarPanelPlacement) -> ShellFocusAxis {
        placement.isVertical ? .vertical : .horizontal
    }

    static func fitted(
        _ size: CGSize,
        attachment: PopupAttachment,
        visibleFrame: CGRect,
        gap: CGFloat = PopupAttachment.gap
    ) -> CGSize {
        let available = attachment.availableSize(in: visibleFrame, gap: gap)
        return CGSize(width: min(size.width, available.width), height: min(size.height, available.height))
    }

    private static func level(above anchor: ShellAnchor) -> NSWindow.Level {
        NSWindow.Level(rawValue: max(anchor.level.rawValue + 1, NSWindow.Level.popUpMenu.rawValue))
    }
}
