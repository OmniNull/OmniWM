// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Cocoa

@MainActor
protocol QuakeTerminalTabBarDelegate: AnyObject {
    func tabBarDidSelectTab(at index: Int)
    func tabBarDidRequestNewTab()
    func tabBarDidRequestCloseTab(at index: Int)
}

@MainActor
final class QuakeTerminalTabBar: NSView {
    static let barHeight: CGFloat = 28

    weak var delegate: QuakeTerminalTabBarDelegate?

    private var tabTitles: [String] = []
    private var selectedIndex: Int = 0
    private var hoveredIndex: Int = -1
    private var hoveredCloseIndex: Int = -1
    private var hoverTrackingAreas: [NSTrackingArea] = []

    private let tabMinWidth: CGFloat = 100
    private let tabMaxWidth: CGFloat = 200
    private let newTabButtonWidth: CGFloat = 28
    private let closeButtonSize: CGFloat = 14
    private let tabPadding: CGFloat = 8

    override var isFlipped: Bool {
        true
    }

    func update(titles: [String], selectedIndex: Int) {
        self.tabTitles = titles
        self.selectedIndex = selectedIndex
        rebuildTrackingAreas()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.1, alpha: 0.95).setFill()
        bounds.fill()

        let tabWidth = calculateTabWidth()

        for i in 0 ..< tabTitles.count {
            let tabRect = NSRect(x: CGFloat(i) * tabWidth, y: 0, width: tabWidth, height: bounds.height)
            drawTab(at: i, in: tabRect)
        }

        let plusRect = NSRect(
            x: CGFloat(tabTitles.count) * tabWidth,
            y: 0,
            width: newTabButtonWidth,
            height: bounds.height
        )
        drawNewTabButton(in: plusRect)

        NSColor(white: 0.2, alpha: 1).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func drawTab(at index: Int, in rect: NSRect) {
        let isSelected = index == selectedIndex
        let isHovered = index == hoveredIndex

        if isSelected {
            NSColor(white: 0.2, alpha: 1).setFill()
            rect.fill()
        } else if isHovered {
            NSColor(white: 0.15, alpha: 1).setFill()
            rect.fill()
        }

        let title = tabTitles[index]
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: isSelected ? NSColor.white : NSColor(white: 0.6, alpha: 1),
            .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .medium : .regular)
        ]

        let closeSpace: CGFloat = closeButtonSize + tabPadding
        let maxTextWidth = rect.width - tabPadding * 2 - closeSpace
        let attrStr = NSAttributedString(string: title, attributes: attrs)
        let textSize = attrStr.size()
        let textRect = NSRect(
            x: rect.minX + tabPadding,
            y: (rect.height - textSize.height) / 2,
            width: min(textSize.width, maxTextWidth),
            height: textSize.height
        )
        attrStr.draw(with: textRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])

        if isHovered || isSelected {
            let closeRect = self.closeButtonRect(for: index, tabRect: rect)
            let isCloseHovered = index == hoveredCloseIndex

            if isCloseHovered {
                NSColor(white: 0.35, alpha: 1).setFill()
                let bg = NSBezierPath(roundedRect: closeRect.insetBy(dx: -2, dy: -2), xRadius: 3, yRadius: 3)
                bg.fill()
            }

            let closeColor = isCloseHovered ? NSColor.white : NSColor(white: 0.5, alpha: 1)
            let closeAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: closeColor,
                .font: NSFont.systemFont(ofSize: 10, weight: .medium)
            ]
            let closeStr = NSAttributedString(string: "×", attributes: closeAttrs)
            let closeSize = closeStr.size()
            let drawRect = NSRect(
                x: closeRect.midX - closeSize.width / 2,
                y: closeRect.midY - closeSize.height / 2,
                width: closeSize.width,
                height: closeSize.height
            )
            closeStr.draw(in: drawRect)
        }

        NSColor(white: 0.25, alpha: 1).setFill()
        NSRect(x: rect.maxX - 0.5, y: 4, width: 0.5, height: rect.height - 8).fill()
    }

    private func drawNewTabButton(in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.5, alpha: 1),
            .font: NSFont.systemFont(ofSize: 14, weight: .light)
        ]
        let str = NSAttributedString(string: "+", attributes: attrs)
        let size = str.size()
        let drawRect = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        str.draw(in: drawRect)
    }

    private func closeButtonRect(for index: Int, tabRect: NSRect) -> NSRect {
        NSRect(
            x: tabRect.maxX - tabPadding - closeButtonSize,
            y: (tabRect.height - closeButtonSize) / 2,
            width: closeButtonSize,
            height: closeButtonSize
        )
    }

    private func calculateTabWidth() -> CGFloat {
        guard !tabTitles.isEmpty else { return tabMinWidth }
        let available = bounds.width - newTabButtonWidth
        let perTab = available / CGFloat(tabTitles.count)
        return min(max(perTab, tabMinWidth), tabMaxWidth)
    }

    private func tabIndex(at point: NSPoint) -> Int? {
        let tabWidth = calculateTabWidth()
        let index = Int(point.x / tabWidth)
        guard index >= 0, index < tabTitles.count else { return nil }
        return index
    }

    private func isNewTabButton(at point: NSPoint) -> Bool {
        let tabWidth = calculateTabWidth()
        let plusX = CGFloat(tabTitles.count) * tabWidth
        return point.x >= plusX && point.x <= plusX + newTabButtonWidth
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let index = tabIndex(at: point) {
            let tabWidth = calculateTabWidth()
            let tabRect = NSRect(x: CGFloat(index) * tabWidth, y: 0, width: tabWidth, height: bounds.height)
            let closeRect = closeButtonRect(for: index, tabRect: tabRect).insetBy(dx: -4, dy: -4)
            if closeRect.contains(point) {
                delegate?.tabBarDidRequestCloseTab(at: index)
                return
            }
            delegate?.tabBarDidSelectTab(at: index)
            return
        }

        if isNewTabButton(at: point) {
            delegate?.tabBarDidRequestNewTab()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = -1
        hoveredCloseIndex = -1
        needsDisplay = true
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let oldHover = hoveredIndex
        let oldClose = hoveredCloseIndex

        hoveredIndex = tabIndex(at: point) ?? -1
        hoveredCloseIndex = -1

        if hoveredIndex >= 0 {
            let tabWidth = calculateTabWidth()
            let tabRect = NSRect(x: CGFloat(hoveredIndex) * tabWidth, y: 0, width: tabWidth, height: bounds.height)
            let closeRect = closeButtonRect(for: hoveredIndex, tabRect: tabRect).insetBy(dx: -4, dy: -4)
            if closeRect.contains(point) {
                hoveredCloseIndex = hoveredIndex
            }
        }

        if hoveredIndex != oldHover || hoveredCloseIndex != oldClose {
            needsDisplay = true
        }
    }

    private func rebuildTrackingAreas() {
        for area in hoverTrackingAreas {
            removeTrackingArea(area)
        }
        hoverTrackingAreas.removeAll()

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingAreas.append(area)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingAreas()
    }
}
