// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriContainer {
    func applyWindowWidth(
        _ window: NiriWindow,
        projectedWindows: [NiriWindow],
        pixels: CGFloat,
        availableSpan: CGFloat,
        gaps: CGFloat
    ) {
        var windowWidth = pixels
        let minWidthTaken: CGFloat
        if isTabbed {
            minWidthTaken = 0
        } else {
            minWidthTaken = projectedWindows
                .filter { $0 !== window }
                .reduce(CGFloat(0)) { partial, otherWindow in
                    partial + max(1, otherWindow.constraints.minSize.width) + gaps
                }
        }

        let widthLeft = max(1, availableSpan - gaps - minWidthTaken - gaps)
        windowWidth = min(widthLeft, windowWidth)
        windowWidth = window.constraints.clampWidth(windowWidth)
        windowWidth = window.packingHints.width?.packed(windowWidth, limit: widthLeft) ?? windowWidth
        window.windowWidth = .fixed(windowWidth.clamped(to: 1 ... NiriSizeChange.maxPixels))
        if window.sizingMode == .maximized {
            window.sizingMode = .normal
        }
    }

    func applyWindowHeight(
        _ window: NiriWindow,
        projectedWindows: [NiriWindow],
        pixels: CGFloat,
        availableSpan: CGFloat,
        gaps: CGFloat
    ) {
        var windowHeight = pixels
        let minHeightTaken: CGFloat
        if isTabbed {
            minHeightTaken = 0
        } else {
            minHeightTaken = projectedWindows
                .filter { $0 !== window }
                .reduce(CGFloat(0)) { partial, otherWindow in
                    partial + max(1, otherWindow.constraints.minSize.height) + gaps
                }
        }

        let heightLeft = max(1, availableSpan - gaps - minHeightTaken - gaps)
        windowHeight = min(heightLeft, windowHeight)
        windowHeight = window.constraints.clampHeight(windowHeight)
        windowHeight = window.packingHints.height?.packed(windowHeight, limit: heightLeft) ?? windowHeight
        window.height = .fixed(windowHeight.clamped(to: 1 ... NiriSizeChange.maxPixels))
        window.savedHeight = nil
        if window.sizingMode == .maximized {
            window.sizingMode = .normal
        }
    }

    func toggleFullHeightSpec() -> ProportionalSize {
        hasManualSingleWindowHeightOverride = true

        if isFullHeight {
            isFullHeight = false
            if let savedHeight = savedHeight {
                height = savedHeight
                self.savedHeight = nil
            }
        } else {
            savedHeight = height
            isFullHeight = true
        }

        return isFullHeight ? ProportionalSize.proportion(1) : height
    }

    func toggleFullWidthSpec() -> ProportionalSize {
        if isFullWidth {
            isFullWidth = false
            if let saved = savedWidth {
                width = saved
                savedWidth = nil
            }
            hasManualSingleWindowWidthOverride = true
            return width
        } else {
            savedWidth = width
            isFullWidth = true
            presetWidthIdx = nil
            hasManualSingleWindowWidthOverride = true
            return .proportion(1)
        }
    }

    func currentHeightForSizing(
        workingAreaHeight: CGFloat,
        gaps: CGFloat
    ) -> CGFloat {
        if let targetHeight {
            return targetHeight
        }
        if cachedHeight <= 0 {
            resolveAndCacheHeight(workingAreaHeight: workingAreaHeight, gaps: gaps)
        }

        return cachedHeight
    }

    func resolvedWidthPixels(
        _ width: ProportionalSize,
        availableSpan: CGFloat,
        gaps: CGFloat,
        contentInset: CGFloat
    ) -> CGFloat {
        resolvedPrimarySpan(
            width,
            orientation: .horizontal,
            availableSpace: availableSpan,
            gaps: gaps,
            contentInset: contentInset
        )
    }

    func resolvedHeightPixels(
        _ height: ProportionalSize,
        availableSpan: CGFloat,
        gaps: CGFloat
    ) -> CGFloat {
        resolvedPrimarySpan(height, orientation: .vertical, availableSpace: availableSpan, gaps: gaps)
    }

    func nextHeightPresetIndex(
        forwards: Bool,
        currentHeight: CGFloat,
        presets: [PresetSize],
        availableSpan: CGFloat,
        gaps: CGFloat
    ) -> Int {
        if forwards {
            return presets.firstIndex { preset in
                currentHeight + 1 < resolvedHeightPixels(
                    preset.asProportionalSize,
                    availableSpan: availableSpan,
                    gaps: gaps
                )
            } ?? 0
        } else {
            return presets.lastIndex { preset in
                resolvedHeightPixels(
                    preset.asProportionalSize,
                    availableSpan: availableSpan,
                    gaps: gaps
                ) + 1 < currentHeight
            } ?? (presets.count - 1)
        }
    }

    func resolvedHorizontalSize(in workingFrame: CGRect, primaryGap: CGFloat) -> CGSize {
        if cachedWidth <= 0 {
            resolveAndCacheWidth(
                workingAreaWidth: workingFrame.width,
                gaps: primaryGap,
                contentInset: 0
            )
        }
        return CGSize(
            width: min(workingFrame.width, max(0, cachedWidth)),
            height: workingFrame.height
        )
    }
}
