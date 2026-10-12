// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct HiddenBarPanelPlacement: Equatable {
    static let continuousCornerReach: CGFloat = 1.52866
    static let liftMargin: CGFloat = 10

    struct WorkspaceBar: Equatable {
        let monitorId: Monitor.ID
        let frame: CGRect
        let backgroundStyle: WorkspaceBarSnapshot.BackgroundStyle
        let backgroundOpacity: Double
    }

    struct Join: Equatable {
        let monitorId: Monitor.ID
        let edge: PopupAttachment.Edge
    }

    private struct Spans {
        let span: ClosedRange<CGFloat>
        let seam: ClosedRange<CGFloat>
        let hasEars: Bool
    }

    let attachment: PopupAttachment
    let visibleFrame: CGRect
    var workspaceBar: WorkspaceBar?

    var isVertical: Bool {
        attachment.edge == .left || attachment.edge == .right
    }

    var join: Join? {
        workspaceBar.map { Join(monitorId: $0.monitorId, edge: attachment.edge) }
    }

    var cellHeight: CGFloat {
        guard let bar = workspaceBar?.frame else { return 20 }
        return max(20, (isVertical ? bar.width : bar.height) - 4)
    }

    var maxContentHeight: CGFloat {
        max(1, visibleFrame.height - 16 - HiddenBarPanelController.alongPadding * 2)
    }

    var maxContentWidth: CGFloat {
        max(1, visibleFrame.width - 16 - HiddenBarPanelController.alongPadding * 2)
    }

    func layout(size: CGSize) -> HiddenBarPanelLayout {
        let anchored = attachment.frame(size: size, visibleFrame: visibleFrame)
        guard let workspaceBar else {
            return HiddenBarPanelLayout(frame: anchored, body: anchored, seam: nil, hasEars: false)
        }
        let bar = workspaceBar.frame
        let reach = workspaceBar.backgroundStyle == .solidBlack ? 0 : WorkspaceBarGeometry.cornerRadius * Self
            .continuousCornerReach
        let join = joinSpans(
            start: isVertical ? anchored.minY : anchored.minX,
            length: isVertical ? size.height : size.width,
            bar: isVertical ? bar.minY ... bar.maxY : bar.minX ... bar.maxX,
            reach: reach
        )
        let depth = isVertical ? size.width : size.height
        let margin = Self.liftMargin
        let span = join.span.lowerBound
        let length = join.span.upperBound - join.span.lowerBound
        let seamStart = join.seam.lowerBound
        let seamLength = join.seam.upperBound - join.seam.lowerBound
        let body: CGRect
        let frame: CGRect
        let seam: CGRect
        switch attachment.edge {
        case .below:
            body = CGRect(x: span, y: bar.minY - depth, width: length, height: depth)
            frame = CGRect(x: span - margin, y: body.minY - margin, width: length + margin * 2, height: depth + margin)
            seam = CGRect(x: seamStart, y: bar.minY - 1, width: seamLength, height: 1)
        case .above:
            body = CGRect(x: span, y: bar.maxY, width: length, height: depth)
            frame = CGRect(x: span - margin, y: bar.maxY, width: length + margin * 2, height: depth + margin)
            seam = CGRect(x: seamStart, y: bar.maxY, width: seamLength, height: 1)
        case .right:
            body = CGRect(x: bar.maxX, y: span, width: depth, height: length)
            frame = CGRect(x: bar.maxX, y: span - margin, width: depth + margin, height: length + margin * 2)
            seam = CGRect(x: bar.maxX, y: seamStart, width: 1, height: seamLength)
        case .left:
            body = CGRect(x: bar.minX - depth, y: span, width: depth, height: length)
            frame = CGRect(x: body.minX - margin, y: span - margin, width: depth + margin, height: length + margin * 2)
            seam = CGRect(x: bar.minX - 1, y: seamStart, width: 1, height: seamLength)
        }
        return HiddenBarPanelLayout(frame: frame, body: body, seam: seam, hasEars: join.hasEars)
    }

    private func joinSpans(
        start: CGFloat, length: CGFloat, bar: ClosedRange<CGFloat>, reach: CGFloat
    ) -> Spans {
        let radius = WorkspaceBarGeometry.cornerRadius
        if start - radius >= bar.lowerBound + reach, start + length + radius <= bar.upperBound - reach {
            return Spans(
                span: start ... start + length,
                seam: start - radius ... start + length + radius,
                hasEars: true
            )
        }
        if length <= bar.upperBound - bar.lowerBound {
            return Spans(span: bar, seam: bar, hasEars: false)
        }
        let width = max(length, bar.upperBound - bar.lowerBound + reach * 2)
        let lower = (isVertical ? visibleFrame.minY : visibleFrame.minX) + 8
        let upper = (isVertical ? visibleFrame.maxY : visibleFrame.maxX) - 8 - width
        let centered = (bar.lowerBound + bar.upperBound - width) / 2
        let origin = upper >= lower ? min(max(centered, lower), upper) : lower
        let seam = max(bar.lowerBound, origin) ... min(bar.upperBound, origin + width)
        return Spans(span: origin ... origin + width, seam: seam, hasEars: false)
    }
}

struct HiddenBarPanelLayout: Equatable {
    let frame: CGRect
    let body: CGRect
    let seam: CGRect?
    let hasEars: Bool

    var squaresBar: Bool {
        seam != nil && !hasEars
    }

    init(frame: CGRect, body: CGRect, seam: CGRect?, hasEars: Bool) {
        self.frame = frame
        self.body = Self.localRect(body, in: frame)
        self.seam = seam.map { Self.localRect($0, in: frame) }
        self.hasEars = hasEars
    }

    private static func localRect(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
