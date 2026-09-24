// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

struct OverviewRibbonAxis {
    let orientation: Monitor.Orientation

    init(_ orientation: Monitor.Orientation) {
        self.orientation = orientation
    }

    func minimum(_ frame: CGRect) -> CGFloat {
        orientation == .horizontal ? frame.minX : frame.minY
    }

    func maximum(_ frame: CGRect) -> CGFloat {
        orientation == .horizontal ? frame.maxX : frame.maxY
    }

    func span(_ frame: CGRect) -> CGFloat {
        orientation == .horizontal ? frame.width : frame.height
    }

    func offset(_ frame: CGRect, by delta: CGFloat) -> CGRect {
        frame.offsetBy(dx: orientation == .horizontal ? delta : 0, dy: orientation == .vertical ? delta : 0)
    }

    func frame(start: CGFloat, span: CGFloat, across bounds: CGRect) -> CGRect {
        orientation == .horizontal
            ? CGRect(x: start, y: bounds.minY, width: span, height: bounds.height)
            : CGRect(x: bounds.minX, y: start, width: bounds.width, height: span)
    }
}

struct OverviewTabControl {
    enum Style: Equatable {
        case segmented
        case pickerOnly
    }

    enum Segment: CaseIterable {
        case previous
        case picker
        case next
    }

    let handle: WindowHandle
    let previousHandle: WindowHandle?
    let nextHandle: WindowHandle?
    let frame: CGRect
    let positionLabel: String
    var style: Style = .segmented

    func frame(for segment: Segment) -> CGRect {
        if style == .pickerOnly {
            return segment == .picker ? frame : .null
        }
        let buttonWidth: CGFloat = 24
        switch segment {
        case .previous:
            return CGRect(x: frame.minX, y: frame.minY, width: buttonWidth, height: frame.height)
        case .picker:
            return frame.insetBy(dx: buttonWidth, dy: 0)
        case .next:
            return CGRect(x: frame.maxX - buttonWidth, y: frame.minY, width: buttonWidth, height: frame.height)
        }
    }

    func label(for segment: Segment) -> String {
        switch segment {
        case .previous: "‹"
        case .picker: positionLabel
        case .next: "›"
        }
    }

    func steppedHandle(at point: CGPoint) -> WindowHandle? {
        if frame(for: .previous).contains(point) { return previousHandle }
        if frame(for: .next).contains(point) { return nextHandle }
        return nil
    }

    func isEnabled(_ segment: Segment) -> Bool {
        if style == .pickerOnly { return segment == .picker }
        return switch segment {
        case .previous: previousHandle != nil
        case .picker: true
        case .next: nextHandle != nil
        }
    }
}

extension OverviewLayout {
    func backgroundFrame(for section: OverviewWorkspaceSection) -> CGRect {
        guard !section.visibleFrame.isEmpty, !section.ribbonFrame.isEmpty else { return section.visibleFrame }
        var bounds = section.visibleFrame
        for column in niriColumnsByWorkspace[section.workspaceId] ?? [] {
            bounds = bounds.union(column.frame)
        }
        for window in section.windows where window.isTiled {
            bounds = bounds.union(window.overviewFrame)
        }
        return CGRect(
            x: bounds.minX,
            y: section.visibleFrame.minY,
            width: bounds.width,
            height: section.visibleFrame.height
        )
    }

    func overflowPills(for section: OverviewWorkspaceSection) -> [OverviewOverflowPill] {
        guard !section.ribbonFrame.isEmpty else { return [] }
        let height = OverviewLayoutMetrics.overflowPillHeight * OverviewLayoutCalculator.clampedScale(scale)
        let width = OverviewLayoutMetrics.overflowPillWidth * OverviewLayoutCalculator.clampedScale(scale)
        return [
            (OverviewOverflowPill.Edge.leading, section.hiddenColumnsBefore),
            (.trailing, section.hiddenColumnsAfter)
        ]
        .compactMap { edge, count in
            guard count > 0 else { return nil }
            let frame: CGRect
            if section.orientation == .horizontal {
                frame = CGRect(
                    x: edge == .leading ? section.ribbonFrame.minX : section.ribbonFrame.maxX - width,
                    y: section.ribbonFrame.midY - height / 2,
                    width: width,
                    height: height
                )
            } else {
                frame = CGRect(
                    x: section.ribbonFrame.midX - width / 2,
                    y: edge == .leading ? section.ribbonFrame.minY : section.ribbonFrame.maxY - height,
                    width: width,
                    height: height
                )
            }
            return OverviewOverflowPill(
                workspaceId: section.workspaceId,
                edge: edge,
                count: count,
                frame: frame,
                orientation: section.orientation
            )
        }
    }

    func overflowPill(at point: CGPoint) -> OverviewOverflowPill? {
        let adjustedPoint = CGPoint(x: point.x, y: point.y + scrollOffset)
        return workspaceSections.lazy.flatMap { overflowPills(for: $0) }
            .first { $0.frame.contains(adjustedPoint) }
    }

    func tabControls(for section: OverviewWorkspaceSection) -> [OverviewTabControl] {
        let isDwindle = dwindleGroupsByWorkspace[section.workspaceId] != nil
        return tabbedWindowGroups(in: section.workspaceId).compactMap { group in
            let members = group.filter { window(for: $0)?.matchesSearch == true }
            guard members.count > 1,
                  let activeIndex = members.firstIndex(where: { window(for: $0)?.isDisplayed == true }),
                  let active = window(for: members[activeIndex])
            else { return nil }
            let bounds = active.overviewFrame.intersection(section.ribbonFrame)
            let frame: CGRect
            let label: String
            let style: OverviewTabControl.Style
            if bounds.width >= 100, bounds.height >= (isDwindle ? 92 : 60) {
                frame = CGRect(
                    x: bounds.minX + 8, y: bounds.minY + (isDwindle ? 40 : 36),
                    width: min(112, bounds.width - 16), height: 22
                )
                label = "\(activeIndex + 1) / \(members.count)"
                style = .segmented
            } else if isDwindle, bounds.width >= 74, bounds.height >= 68 {
                label = "\(members.count) ▾"
                let width = max(32, ceil((label as NSString).size(withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12)
                ]).width) + 12)
                guard bounds.width >= width + 42 else { return nil }
                frame = CGRect(x: bounds.minX + 8, y: bounds.maxY - 30, width: width, height: 22)
                style = .pickerOnly
            } else {
                return nil
            }
            return OverviewTabControl(
                handle: active.handle,
                previousHandle: activeIndex > 0 ? members[activeIndex - 1] : nil,
                nextHandle: activeIndex + 1 < members.count ? members[activeIndex + 1] : nil,
                frame: frame, positionLabel: label, style: style
            )
        }
    }

    func tabControl(at point: CGPoint) -> OverviewTabControl? {
        let adjusted = CGPoint(x: point.x, y: point.y + scrollOffset)
        return workspaceSections.lazy.flatMap { tabControls(for: $0) }.first { $0.frame.contains(adjusted) }
    }

    func tabMembers(for handle: WindowHandle) -> [OverviewWindowItem] {
        guard let window = window(for: handle),
              let group = tabGroup(containing: handle, in: window.workspaceId) else { return [] }
        return group.compactMap { self.window(for: $0) }.filter(\.matchesSearch)
    }

    var searchResultCount: Int {
        workspaceSections.reduce(0) { count, section in
            count + section.windows.lazy.filter(\.matchesSearch).count
        }
    }

    var searchClearFrame: CGRect {
        CGRect(x: searchBarFrame.maxX - 62, y: searchBarFrame.minY, width: 62, height: searchBarFrame.height)
    }

    func searchFeedback(query: String) -> String {
        let count = searchResultCount
        if query.isEmpty {
            return String(localized: LocalizedStringResource(
                "\(count) windows", bundle: .omniWM
            ))
        }
        if count == 0 { return String(localized: "No matching windows") }
        return String(localized: LocalizedStringResource(
            "\(count) results", bundle: .omniWM
        ))
    }
}
