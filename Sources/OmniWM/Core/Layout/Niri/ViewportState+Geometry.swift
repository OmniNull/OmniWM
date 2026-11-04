// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct ViewportColumnTarget {
    let index: Int
    let position: CGFloat
    let span: CGFloat
    let mode: SizingMode
}

struct ViewportFittingAreas {
    let working: CGRect
    let parent: CGRect
    let orientation: Monitor.Orientation
    let scale: CGFloat

    var viewSpan: CGFloat {
        span(of: parent)
    }

    func span(of rect: CGRect) -> CGFloat {
        switch orientation {
        case .horizontal:
            rect.width
        case .vertical:
            rect.height
        }
    }

    func origin(of rect: CGRect) -> CGFloat {
        switch orientation {
        case .horizontal:
            rect.minX
        case .vertical:
            rect.minY
        }
    }

    func area(for mode: SizingMode) -> CGRect {
        mode.isMaximized ? parent : working
    }
}

extension ViewportFittingAreas {
    init(geometry: NiriViewportGeometry) {
        let orientation = geometry.orientation
        let crossSpan: CGFloat = switch orientation {
        case .horizontal:
            geometry.workingArea?.height ?? geometry.viewFrame?.height ?? 0
        case .vertical:
            geometry.workingArea?.width ?? geometry.viewFrame?.width ?? 0
        }
        let fallbackParentFrame: CGRect = switch orientation {
        case .horizontal:
            CGRect(x: 0, y: 0, width: geometry.viewportSpan, height: crossSpan)
        case .vertical:
            CGRect(x: 0, y: 0, width: crossSpan, height: geometry.viewportSpan)
        }
        let parentFrame = geometry.viewFrame ?? geometry.workingArea ?? fallbackParentFrame

        let localWorking = CGRect(origin: .zero, size: geometry.workingArea?.size ?? parentFrame.size)

        let parent: CGRect
        if let workingArea = geometry.workingArea {
            parent = CGRect(
                x: parentFrame.minX - workingArea.minX,
                y: parentFrame.minY - workingArea.minY,
                width: parentFrame.width,
                height: parentFrame.height
            )
        } else {
            parent = CGRect(
                origin: .zero,
                size: parentFrame.size
            )
        }

        let fallbackLocalSize = geometry.workingArea?.size ?? fallbackParentFrame.size
        let fallbackLocalFrame = CGRect(origin: .zero, size: fallbackLocalSize)
        let primarySpan: (CGRect) -> CGFloat = { rect in
            switch orientation {
            case .horizontal:
                rect.width
            case .vertical:
                rect.height
            }
        }

        self.init(
            working: primarySpan(localWorking) > 0 ? localWorking : fallbackLocalFrame,
            parent: primarySpan(parent) > 0 ? parent : fallbackLocalFrame,
            orientation: orientation,
            scale: geometry.scale
        )
    }

    private func computeFitOffset(
        currentViewPos: CGFloat,
        viewSpan: CGFloat,
        targetPos: CGFloat,
        targetSpan: CGFloat,
        gap: CGFloat
    ) -> CGFloat {
        let pixelEpsilon: CGFloat = 1.0 / max(scale, 1.0)

        if viewSpan <= targetSpan + pixelEpsilon {
            return 0
        }

        let padding = ((viewSpan - targetSpan) / 2).clamped(to: 0 ... gap)
        let preferredStart = targetPos - padding
        let targetEnd = targetPos + targetSpan
        let preferredEnd = targetEnd + padding

        if currentViewPos - pixelEpsilon <= preferredStart
            && preferredEnd <= currentViewPos + viewSpan + pixelEpsilon
        {
            return currentViewPos - targetPos
        }

        let distToStart = abs(currentViewPos - preferredStart)
        let distToEnd = abs((currentViewPos + viewSpan) - preferredEnd)

        if distToStart <= distToEnd {
            return -padding
        } else {
            return -(viewSpan - padding - targetSpan)
        }
    }

    func fitOffset(
        currentViewStart: CGFloat,
        target: ViewportColumnTarget,
        gap: CGFloat
    ) -> CGFloat {
        if target.mode.isFullscreen {
            return 0
        }

        let area = self.area(for: target.mode)
        let areaStart = origin(of: area)
        let padding = target.mode.isMaximized ? 0 : gap
        let newOffset = computeFitOffset(
            currentViewPos: currentViewStart + areaStart,
            viewSpan: span(of: area),
            targetPos: target.position,
            targetSpan: target.span,
            gap: padding
        )
        return newOffset - areaStart
    }

    func centeredOffset(
        currentViewStart: CGFloat,
        target: ViewportColumnTarget,
        gap: CGFloat
    ) -> CGFloat {
        if target.mode.isFullscreen {
            return fitOffset(
                currentViewStart: currentViewStart,
                target: target,
                gap: gap
            )
        }

        let area = self.area(for: target.mode)
        let areaSpan = span(of: area)
        let areaStart = origin(of: area)
        if areaSpan <= target.span {
            return fitOffset(
                currentViewStart: currentViewStart,
                target: target,
                gap: gap
            )
        }

        return -(areaSpan - target.span) / 2 - areaStart
    }
}

extension SizingMode {
    var isMaximized: Bool {
        self == .maximized
    }

    var isFullscreen: Bool {
        self == .fullscreen
    }
}

extension Monitor.Orientation {
    var renderedSpanKeyPath: KeyPath<NiriContainer, CGFloat> {
        switch self {
        case .horizontal: \.cachedWidth
        case .vertical: \.cachedHeight
        }
    }

    var settledSpanKeyPath: KeyPath<NiriContainer, CGFloat> {
        switch self {
        case .horizontal: \.settledWidth
        case .vertical: \.settledHeight
        }
    }
}

extension NiriContainer {
    var effectiveSizingMode: SizingMode {
        var anyFullscreen = false
        var anyMaximized = false
        for window in windowNodes {
            switch window.sizingMode {
            case .normal:
                continue
            case .maximized:
                anyMaximized = true
            case .fullscreen:
                anyFullscreen = true
            }
        }

        if anyFullscreen {
            return .fullscreen
        } else if anyMaximized {
            return .maximized
        } else {
            return .normal
        }
    }
}

extension ViewportState {
    func columnX(at index: Int, columns: [NiriContainer], gap: CGFloat) -> CGFloat {
        containerPosition(at: index, containers: columns, gap: gap, sizeKeyPath: \.cachedWidth)
    }

    func containerPosition(
        at index: Int,
        containers: [NiriContainer],
        gap: CGFloat,
        sizeKeyPath: KeyPath<NiriContainer, CGFloat>
    ) -> CGFloat {
        var pos: CGFloat = 0
        for i in 0 ..< index {
            guard i < containers.count else { break }
            pos += containers[i][keyPath: sizeKeyPath] + gap
        }
        return pos
    }

    func totalSpan(containers: [NiriContainer], gap: CGFloat, sizeKeyPath: KeyPath<NiriContainer, CGFloat>) -> CGFloat {
        guard !containers.isEmpty else { return 0 }
        let sizeSum = containers.reduce(0) { $0 + $1[keyPath: sizeKeyPath] }
        let gapSum = CGFloat(max(0, containers.count - 1)) * gap
        return sizeSum + gapSum
    }

    func computeCenteredOffset(
        containerIndex: Int,
        containers: [NiriContainer],
        context: NiriInteractionContext,
        viewFrame: CGRect? = nil,
        scale: CGFloat = 2.0
    ) -> CGFloat {
        guard !containers.isEmpty, containerIndex >= 0, containerIndex < containers.count else { return 0 }

        let sizeKeyPath = context.orientation.settledSpanKeyPath
        let viewportSpan: CGFloat = switch context.orientation {
        case .horizontal: context.workingFrame.width
        case .vertical: context.workingFrame.height
        }
        let areas = ViewportFittingAreas(geometry: NiriViewportGeometry(
            gap: context.gaps,
            viewportSpan: viewportSpan,
            orientation: context.orientation,
            workingArea: context.workingFrame,
            viewFrame: viewFrame,
            scale: scale
        ))
        let target = ViewportColumnTarget(
            index: containerIndex,
            position: containerPosition(
                at: containerIndex,
                containers: containers,
                gap: context.gaps,
                sizeKeyPath: sizeKeyPath
            ),
            span: containers[containerIndex][keyPath: sizeKeyPath],
            mode: containers[containerIndex].effectiveSizingMode
        )

        return areas.centeredOffset(
            currentViewStart: target.position,
            target: target,
            gap: context.gaps
        )
    }

    func computeVisibleOffset(
        containerIndex: Int,
        containers: [NiriContainer],
        context: NiriInteractionContext,
        currentViewStart: CGFloat,
        centerMode: CenterFocusedColumn,
        alwaysCenterSingleColumn: Bool = false,
        fromContainerIndex: Int? = nil,
        scale: CGFloat = 2.0,
        viewFrame: CGRect? = nil
    ) -> CGFloat {
        guard !containers.isEmpty, containerIndex >= 0, containerIndex < containers.count else { return 0 }

        let sizeKeyPath = context.orientation.settledSpanKeyPath
        let viewportSpan: CGFloat = switch context.orientation {
        case .horizontal: context.workingFrame.width
        case .vertical: context.workingFrame.height
        }
        let areas = ViewportFittingAreas(geometry: NiriViewportGeometry(
            gap: context.gaps,
            viewportSpan: viewportSpan,
            orientation: context.orientation,
            workingArea: context.workingFrame,
            viewFrame: viewFrame,
            scale: scale
        ))
        let effectiveCenterMode = (containers.count == 1 && alwaysCenterSingleColumn) ? .always : centerMode
        let target = ViewportColumnTarget(
            index: containerIndex,
            position: containerPosition(
                at: containerIndex,
                containers: containers,
                gap: context.gaps,
                sizeKeyPath: sizeKeyPath
            ),
            span: containers[containerIndex][keyPath: sizeKeyPath],
            mode: containers[containerIndex].effectiveSizingMode
        )

        let shouldCenter = switch effectiveCenterMode {
        case .always: true
        case .never: false
        case .onOverflow:
            shouldCenterAdjacentPair(
                target: target,
                fromIndex: fromContainerIndex,
                containers: containers,
                context: context,
                areas: areas
            )
        }
        if shouldCenter {
            return areas.centeredOffset(currentViewStart: currentViewStart, target: target, gap: context.gaps)
        }
        return areas.fitOffset(currentViewStart: currentViewStart, target: target, gap: context.gaps)
    }

    private func shouldCenterAdjacentPair(
        target: ViewportColumnTarget,
        fromIndex: Int?,
        containers: [NiriContainer],
        context: NiriInteractionContext,
        areas: ViewportFittingAreas
    ) -> Bool {
        guard let fromIndex, fromIndex != target.index, containers.indices.contains(fromIndex) else { return false }
        let sourceIndex = if fromIndex > target.index {
            min(target.index + 1, containers.count - 1)
        } else {
            max(target.index - 1, 0)
        }
        let sizeKeyPath = context.orientation.settledSpanKeyPath
        let sourcePosition = containerPosition(
            at: sourceIndex,
            containers: containers,
            gap: context.gaps,
            sizeKeyPath: sizeKeyPath
        )
        let sourceSpan = containers[sourceIndex][keyPath: sizeKeyPath]
        let pairSpan = if sourcePosition < target.position {
            target.position - sourcePosition + target.span
        } else {
            sourcePosition - target.position + sourceSpan
        }
        return (pairSpan + context.gaps * 2).roundedToPhysicalPixel(scale: areas.scale)
            > areas.span(of: areas.working).roundedToPhysicalPixel(scale: areas.scale)
    }
}
