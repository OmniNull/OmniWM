// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func singleWindowScrollRect(
        in workspaceId: WorkspaceDescriptor.ID,
        workingFrame: CGRect,
        gaps: LayoutGaps
    ) -> CGRect? {
        guard effectiveSettings(in: workspaceId).edgeOverscroll != .disabled,
              let single = singleWindowLayoutContext(in: workspaceId)
        else { return nil }
        // The stored frame is the rendered rect, placed in layout-area frames
        // that can differ from the interaction working frame (edgeGaps off).
        return single.container.frame ?? resolvedSingleWindowRect(
            for: single, in: workingFrame, scale: displayScale(in: workspaceId),
            gaps: gaps, orientation: monitorForWorkspace(workspaceId)?.orientation ?? .horizontal
        )
    }

    /// Converts rect-relative gesture offsets to working-area coordinates and
    /// back; 0 outside single-window layouts.
    func singleWindowGestureOrigin(context: NiriInteractionContext) -> CGFloat {
        guard let rect = singleWindowScrollRect(
            in: context.workspaceId, workingFrame: context.workingFrame, gaps: LayoutGaps(
                horizontal: context.gaps,
                vertical: context.gaps
            )
        ) else { return 0 }
        return context.orientation == .horizontal
            ? context.workingFrame.minX - rect.minX
            : context.workingFrame.minY - rect.minY
    }

    @discardableResult
    func correctSingleWindowGestureOffset(
        context: NiriInteractionContext,
        state: inout ViewportState,
        workingArea: WorkingAreaContext
    ) -> Bool {
        guard state.preservesGestureOffset,
              let single = singleWindowLayoutContext(in: context.workspaceId)
        else { return false }
        let rect = resolvedSingleWindowRect(
            for: single,
            in: workingArea.singleWindowFrame,
            borderSafeFillFrame: workingArea.borderSafeFillFrame,
            fullscreenLayoutFrame: workingArea.fullscreenLayoutFrame,
            scale: workingArea.scale,
            gaps: LayoutGaps(horizontal: context.gaps, vertical: context.gaps),
            orientation: context.orientation
        )
        let span = context.orientation == .horizontal ? rect.width : rect.height
        let viewportSpan = context.orientation == .horizontal
            ? context.workingFrame.width : context.workingFrame.height
        let originOffset = context.orientation == .horizontal
            ? context.workingFrame.minX - rect.minX : context.workingFrame.minY - rect.minY
        guard let bounds = effectiveSettings(in: context.workspaceId).edgeOverscroll.bounds(
            firstSpan: span, lastSpan: span, totalSpan: span, viewportSpan: viewportSpan, gap: context.gaps
        ) else { return false }
        let viewStart = state.viewOffset + originOffset
        let bounded = viewStart.clamped(to: bounds)
        guard abs(bounded - viewStart) > 0.5 else { return false }
        state.animateToOffset(bounded - originOffset, motion: context.motion)
        return true
    }

    private func centeredSingleWindowRect(
        in workingFrame: CGRect,
        size: CGSize,
        scale: CGFloat
    ) -> CGRect {
        CGRect(
            x: workingFrame.minX + (workingFrame.width - size.width) / 2,
            y: workingFrame.minY + (workingFrame.height - size.height) / 2,
            width: size.width,
            height: size.height
        ).roundedToPhysicalPixels(scale: scale)
    }

    private func rectExpandedToMinimum(_ rect: CGRect, minSize: CGSize) -> CGRect {
        var expanded = rect
        if expanded.width < minSize.width {
            expanded.origin.x -= (minSize.width - expanded.width) / 2
            expanded.size.width = minSize.width
        }
        if expanded.height < minSize.height {
            expanded.origin.y -= (minSize.height - expanded.height) / 2
            expanded.size.height = minSize.height
        }
        return expanded
    }

    func resolvedSingleWindowRect(
        for context: SingleWindowLayoutContext,
        in workingFrame: CGRect,
        borderSafeFillFrame: CGRect? = nil,
        fullscreenLayoutFrame: CGRect? = nil,
        scale: CGFloat,
        gaps: LayoutGaps,
        orientation: Monitor.Orientation
    ) -> CGRect {
        let minSize = context.window.constraints.normalized().minSize
        let hasManualPrimaryOverride = switch orientation {
        case .horizontal:
            context.container.hasManualSingleWindowWidthOverride
        case .vertical:
            context.container.hasManualSingleWindowHeightOverride
        }
        let hasManualSecondaryOverride = orientation == .vertical && context.window.windowWidth != .default
        guard hasManualPrimaryOverride || hasManualSecondaryOverride else {
            let baseFrame = context.fit.usesFullscreenLayoutFrame
                ? borderSafeFillFrame ?? fullscreenLayoutFrame ?? workingFrame
                : workingFrame
            return rectExpandedToMinimum(context.fit.frame(in: baseFrame), minSize: minSize)
                .roundedToPhysicalPixels(scale: scale)
        }

        let boundedSize: CGSize
        switch orientation {
        case .horizontal:
            boundedSize = context.container.resolvedHorizontalSize(in: workingFrame, primaryGap: gaps.horizontal)
        case .vertical:
            let windowWidth = resolvedSingleWindowWidth(
                for: context,
                in: workingFrame,
                hasManualSecondaryOverride: hasManualSecondaryOverride,
                secondaryGap: gaps.horizontal
            )
            if context.container.cachedHeight <= 0 {
                context.container.resolveAndCacheHeight(
                    workingAreaHeight: workingFrame.height,
                    gaps: gaps.vertical
                )
            }
            let tabOffset: CGFloat = 0
            let containerWidth = hasManualSecondaryOverride
                ? context.window.constraints.clampWidth(windowWidth) + tabOffset
                : windowWidth
            boundedSize = CGSize(
                width: min(workingFrame.width, max(0, containerWidth)),
                height: min(workingFrame.height, max(0, context.container.cachedHeight))
            )
        }
        return rectExpandedToMinimum(
            centeredSingleWindowRect(in: workingFrame, size: boundedSize, scale: scale),
            minSize: minSize
        ).roundedToPhysicalPixels(scale: scale)
    }

    private func resolvedSingleWindowWidth(
        for context: SingleWindowLayoutContext,
        in workingFrame: CGRect,
        hasManualSecondaryOverride: Bool,
        secondaryGap: CGFloat
    ) -> CGFloat {
        let windowWidth: CGFloat
        if hasManualSecondaryOverride {
            windowWidth = switch context.window.windowWidth {
            case let .fixed(width):
                width
            case let .preset(index):
                resolvePresetSpan(
                    presetWindowSecondarySpans,
                    index: index,
                    availableSpace: workingFrame.width,
                    gap: secondaryGap
                ) ?? workingFrame.width
            case .auto:
                context.window.resolvedWidth ?? context.window.frame?.width ?? workingFrame.width
            }
        } else {
            windowWidth = workingFrame.width
        }
        return windowWidth
    }
}

extension NiriLayoutEngine.SingleWindowLayoutContext {
    func layoutPlacement(
        for canonicalRect: CGRect,
        workspaceOffset: CGFloat,
        scale: CGFloat,
        time: TimeInterval,
        orientation: Monitor.Orientation,
        viewportOffset: CGFloat = 0
    ) -> NiriContainerPlacement {
        let renderOffset = container.renderOffset(at: time)
        let renderedRect = canonicalRect
            .offsetBy(
                dx: workspaceOffset + renderOffset.x - (orientation == .horizontal ? viewportOffset : 0),
                dy: renderOffset.y - (orientation == .vertical ? viewportOffset : 0)
            )
            .roundedToPhysicalPixels(scale: scale)
        let tabOffset: CGFloat = 0
        let secondarySpanOverride: CGFloat? = if orientation == .vertical,
                                                 window.windowWidth != .default
        {
            max(0, canonicalRect.width - tabOffset)
        } else {
            nil
        }

        return NiriContainerPlacement(
            canonicalRect: canonicalRect,
            renderedRect: renderedRect,
            secondarySpanOverride: secondarySpanOverride
        )
    }
}
