// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

struct HiddenBarShellDrawer {
    let isActive: @MainActor () -> Bool
    let isOpen: @MainActor () -> Bool
    let show: @MainActor ([HiddenBarGlyph], Monitor.ID?, HiddenBarPanelPlacement) -> Void
    let refresh: @MainActor ([HiddenBarGlyph]) -> Void
    let close: @MainActor (_ animated: Bool) -> Void
}

extension MenuBarItemKey {
    init?(shellID: String) {
        guard let separator = shellID.lastIndex(of: "#"), let ordinal = Int(shellID[shellID.index(after: separator)...])
        else {
            return nil
        }
        self.init(bundleID: String(shellID[..<separator]), ordinal: ordinal)
    }

    var shellID: String {
        "\(bundleID)#\(ordinal)"
    }
}

extension WorkspaceBarManager {
    func showHiddenBarMenu(_ key: MenuBarItemKey, origin: ShellCommandOrigin) {
        guard let hiddenBar = controller?.hiddenBarController else { return }
        guard let host = shellHost, host.popout != nil, let anchor = origin.anchor else {
            hiddenBar.activate(key)
            return
        }
        host.closeHiddenBarMenu()
        let session = hiddenBar.menuSession
        let shown = host.showHiddenBarMenu(
            Self.hiddenBarMenuMessage("Loading…"),
            anchor: anchor,
            onSelect: { [weak host, weak session] id in
                guard let host, let session else { return }
                switch session.select(id: id) {
                case .updated:
                    if let page = session.page {
                        host.hiddenBarMenu?.update(page: page)
                    }
                case .performed:
                    host.closePopout(animated: false)
                case .unavailable:
                    host.hiddenBarMenu?.update(page: Self.unavailableHiddenBarMenu)
                case .ignored:
                    break
                }
            },
            onClose: { [weak self, weak session] in
                session?.close()
                self?.updateShellHiddenBarPlacement()
            }
        )
        if !shown {
            session.close()
            return
        }
        hiddenBar.openMenu(key) { [weak host, weak hiddenBar] result in
            guard let host, let hiddenBar else { return }
            switch result {
            case .menu:
                if let page = hiddenBar.menuSession.page { host.hiddenBarMenu?.update(page: page) }
            case .noMenu:
                host.closePopout(animated: false)
                hiddenBar.activate(key)
            case .unavailable:
                host.hiddenBarMenu?.update(page: Self.unavailableHiddenBarMenu)
            }
        }
    }

    private static var unavailableHiddenBarMenu: HiddenBarMenuPage {
        hiddenBarMenuMessage("Unavailable")
    }

    private static func hiddenBarMenuMessage(_ message: String) -> HiddenBarMenuPage {
        HiddenBarMenuPage(title: nil, rows: [
            HiddenBarMenuRow(
                id: "", title: ShellLocalizer.string(message, []), enabled: false,
                mark: nil, shortcut: nil, submenu: false, separator: false
            )
        ], backID: nil)
    }

    func makeShellHiddenBarDrawer() -> HiddenBarShellDrawer {
        HiddenBarShellDrawer(
            isActive: { [weak self] in
                self?.shellHost?.hiddenBarWidget != nil
            },
            isOpen: { [weak self] in
                guard let host = self?.shellHost, let widget = host.hiddenBarWidget else { return false }
                return host.popout?.widget == widget
            },
            show: { [weak self] glyphs, monitor, placement in
                self?.showShellHiddenBar(glyphs, on: monitor, placement: placement)
            },
            refresh: { [weak self] glyphs in
                self?.publishShellHiddenBar(glyphs)
            },
            close: { [weak self] animated in
                self?.shellHost?.closePopout(animated: animated)
            }
        )
    }

    private func showShellHiddenBar(
        _ glyphs: [HiddenBarGlyph],
        on monitor: Monitor.ID?,
        placement: HiddenBarPanelPlacement
    ) {
        guard let host = shellHost, let widget = host.hiddenBarWidget, let hiddenBar = controller?.hiddenBarController,
              let monitor = monitor ?? controller?.workspaceManager.interactionMonitorId ?? lastBars.first?.monitor.id
        else {
            return
        }
        publishShellHiddenBar(glyphs, placement: placement)
        let panel = barsByMonitor[monitor].map(\.primary.panel)
        let anchor = panel.flatMap { $0.isVisible ? ShellAnchor(frame: $0.frame, level: $0.level) : nil }
        _ = host.togglePopout(of: widget, on: monitor, anchor: anchor, drawer: ShellPopoutDrawer(
            placement: placement,
            isExemptWindow: { [weak hiddenBar] in hiddenBar?.isExemptWindow($0) == true },
            onJoin: { [weak self] in self?.setHiddenBarJoin($0) }
        ))
    }

    func updateShellHiddenBarPlacement() {
        guard let popout = shellHost?.popout, let bar = popout.drawerPlacement?.workspaceBar else { return }
        guard let placement = hiddenBarPanelPlacement(on: bar.monitorId) else {
            shellHost?.closePopout(animated: false)
            return
        }
        guard placement != popout.drawerPlacement else { return }
        guard controller?.hiddenBarController.menuSession.bundleID == nil else { return }
        popout.move(to: placement)
        shellHost?.closeHiddenBarMenu()
        controller?.hiddenBarController.refreshPanelIfVisible()
    }

    func publishShellHiddenBar(_ glyphs: [HiddenBarGlyph], placement explicit: HiddenBarPanelPlacement? = nil) {
        guard let host = shellHost, let settings = controller?.settings else { return }
        let placement = explicit ?? host.popout?.drawerPlacement
        var bitmaps: Set<String> = []
        let items = glyphs.map { glyph in
            let image = glyph.image.flatMap { Self.bitmap($0, size: glyph.size) }
            let id = image.map { "hidden-bar/\(glyph.key.shellID)/\(ObjectIdentifier($0).hashValue)" }
            if let id, let image {
                host.resources.setBitmap(image, for: id)
                bitmaps.insert(id)
            }
            return ShellHiddenBarItem(
                id: glyph.key.shellID,
                name: glyph.name,
                image: id,
                width: glyph.size.width,
                height: glyph.size.height
            )
        }
        for id in retiredShellHiddenBarBitmaps.subtracting(bitmaps) {
            host.resources.setBitmap(nil, for: id)
        }
        retiredShellHiddenBarBitmaps = shellHiddenBarBitmaps.subtracting(bitmaps)
        shellHiddenBarBitmaps = bitmaps
        host.updateHiddenBar(ShellHiddenBarData(
            enabled: settings.effectiveHiddenBarEnabled,
            available: controller?.hiddenBarController.isHidingAvailable == true,
            rehide: settings.hiddenBar.resolvedRehideIntervalSeconds,
            items: items,
            maxWidth: placement.map { Double($0.maxContentWidth) } ?? 0,
            maxHeight: placement.map { Double($0.maxContentHeight) } ?? 0,
            cell: Double(placement?.cellHeight ?? 20),
            vertical: placement?.isVertical == true
        ))
    }

    private static func bitmap(_ image: NSImage, size: CGSize) -> CGImage? {
        var rect = CGRect(origin: .zero, size: CGSize(width: size.width * 2, height: size.height * 2))
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
