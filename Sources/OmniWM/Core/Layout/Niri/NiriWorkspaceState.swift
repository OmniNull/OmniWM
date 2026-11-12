// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum CenterFocusedColumn: String, CaseIterable, Codable, Identifiable {
    case never
    case always
    case onOverflow

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .never: "Never"
        case .always: "Always"
        case .onOverflow: "On Overflow"
        }
    }
}

struct WorkingAreaContext {
    var workingFrame: CGRect
    var singleWindowFrame: CGRect
    var borderSafeFillFrame: CGRect
    var fullscreenLayoutFrame: CGRect
    var viewFrame: CGRect
    var scale: CGFloat

    init(
        workingFrame: CGRect,
        singleWindowFrame: CGRect? = nil,
        borderSafeFillFrame: CGRect? = nil,
        fullscreenLayoutFrame: CGRect? = nil,
        viewFrame: CGRect,
        scale: CGFloat
    ) {
        self.workingFrame = workingFrame
        self.singleWindowFrame = singleWindowFrame ?? workingFrame
        self.borderSafeFillFrame = borderSafeFillFrame ?? fullscreenLayoutFrame ?? workingFrame
        self.fullscreenLayoutFrame = fullscreenLayoutFrame ?? workingFrame
        self.viewFrame = viewFrame
        self.scale = scale
    }
}

struct Struts: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    static let zero = Struts()
}

func computeWorkingArea(
    parentArea: CGRect,
    scale: CGFloat,
    struts: Struts
) -> CGRect {
    var workingArea = parentArea

    workingArea.size.width = max(0, workingArea.size.width - struts.left - struts.right)
    workingArea.origin.x += struts.left

    workingArea.size.height = max(0, workingArea.size.height - struts.top - struts.bottom)
    workingArea.origin.y += struts.bottom

    let physicalX = ceil(workingArea.origin.x * scale) / scale
    let physicalY = ceil(workingArea.origin.y * scale) / scale

    let xDiff = min(workingArea.size.width, physicalX - workingArea.origin.x)
    let yDiff = min(workingArea.size.height, physicalY - workingArea.origin.y)

    workingArea.size.width -= xDiff
    workingArea.size.height -= yDiff
    workingArea.origin.x = physicalX
    workingArea.origin.y = physicalY

    return workingArea
}

func normalizedTopStrut(top: CGFloat, menuBarInset: CGFloat, reservedTopInset: CGFloat) -> CGFloat {
    max(0, top - menuBarInset) + reservedTopInset
}

struct NiriRenderStyle {
    var tabIndicatorWidth: CGFloat

    static let `default` = NiriRenderStyle(
        tabIndicatorWidth: 0
    )
}

struct NiriShrinkToFitGeometry: Equatable {
    let span: CGFloat
    let gaps: CGFloat
    let orientation: Monitor.Orientation

    init(_ workingFrame: CGRect, gaps: CGFloat, orientation: Monitor.Orientation) {
        span = orientation == .horizontal ? workingFrame.width : workingFrame.height
        self.gaps = gaps
        self.orientation = orientation
    }
}

final class NiriWorkspaceState {
    let root: NiriRoot
    var nodesByToken: [WindowToken: NiriWindow] = [:]
    var attachedMonitorId: Monitor.ID?
    var manualWidthColumnCount: Int?
    var manualHeightColumnCount: Int?
    var shrinkToFitColumnIds: Set<NodeId> = []
    var shrinkToFitGeometry: NiriShrinkToFitGeometry?

    init(workspaceId: WorkspaceDescriptor.ID) {
        root = NiriRoot(workspaceId: workspaceId)
    }

    func index(_ window: NiriWindow) {
        if let existing = nodesByToken[window.token] {
            precondition(existing === window)
            return
        }
        nodesByToken[window.token] = window
    }

    func unindex(_ window: NiriWindow) {
        if nodesByToken[window.token] === window {
            nodesByToken.removeValue(forKey: window.token)
        }
    }
}
