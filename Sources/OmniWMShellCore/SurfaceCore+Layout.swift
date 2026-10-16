// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

extension SurfaceCore {
    static let autoShaderSize: Float = 16

    mutating func measure(slot: Int32) -> Size2 {
        let slotIndex = Int(slot)
        if flags[slotIndex] & flagMeasureDirty == 0 {
            return measured[slotIndex]
        }
        let style = layout[slotIndex]
        var size = switch kind[slotIndex] {
        case .label:
            measureText(slotIndex)
        case .group,
             .box:
            measureChildren(of: slotIndex, style: style)
        case .shader:
            Size2(width: Self.autoShaderSize, height: Self.autoShaderSize)
        case .path:
            Size2(
                width: content[slotIndex].params.z > 0 ? content[slotIndex].params.z : Self.autoShaderSize,
                height: content[slotIndex].params.w > 0 ? content[slotIndex].params.w : Self.autoShaderSize
            )
        case .symbol,
             .image,
             .bitmap,
             .progress,
             .slider,
             .input:
            Size2(width: 0, height: 0)
        }
        if style.width >= 0 {
            size.width = style.width
        }
        if style.height >= 0 {
            size.height = style.height
        }
        measured[slotIndex] = size
        flags[slotIndex] &= ~flagMeasureDirty
        return size
    }

    func measureText(_ slotIndex: Int) -> Size2 {
        let current = content[slotIndex]
        let textID = current.reserve != 0 ? current.reserve : current.text
        guard textID != 0, let measureFunction else { return Size2(width: 0, height: 0) }
        var width: Float = 0
        var height: Float = 0
        measureFunction(measureContext, textID, current.style, current.maxWidth, current.lines, &width, &height)
        if current.maxWidth > 0 {
            width = Swift.min(width, current.maxWidth)
        }
        return Size2(width: width, height: height)
    }

    mutating func measureChildren(of slotIndex: Int, style: LayoutStyle) -> Size2 {
        var mainTotal: Float = 0
        var crossMax: Float = 0
        var count = 0
        var child = firstChild[slotIndex]
        while child >= 0 {
            let childSize = measure(slot: child)
            switch style.axis {
            case .row:
                mainTotal += childSize.width
                crossMax = Swift.max(crossMax, childSize.height)
            case .column:
                mainTotal += childSize.height
                crossMax = Swift.max(crossMax, childSize.width)
            case .overlay:
                if !fills(Int(child), across: true) {
                    mainTotal = Swift.max(mainTotal, childSize.width)
                }
                if !fills(Int(child), across: false) {
                    crossMax = Swift.max(crossMax, childSize.height)
                }
            }
            count += 1
            child = nextSibling[Int(child)]
        }
        if count > 1, style.axis != .overlay {
            mainTotal += style.gap * Float(count - 1)
        }
        let inset = style.padding * 2
        return switch style.axis {
        case .row,
             .overlay:
            Size2(width: mainTotal + inset, height: crossMax + inset)
        case .column:
            Size2(width: crossMax + inset, height: mainTotal + inset)
        }
    }

    mutating func arrange(slot: Int32, to newFrame: Rect, patches: inout PatchBuffer) {
        let slotIndex = Int(slot)
        let old = frame[slotIndex]
        if old != newFrame {
            frame[slotIndex] = newFrame
            patches.ops.append(.setFrame(handle(slot), newFrame))
        }
        let resized = !(old.width == newFrame.width && old.height == newFrame.height)
        guard resized || flags[slotIndex] & flagLayoutDirty != 0 else { return }
        flags[slotIndex] &= ~flagLayoutDirty
        guard firstChild[slotIndex] >= 0 else { return }
        if layout[slotIndex].axis == .overlay {
            arrangeOverlay(slotIndex, in: newFrame, patches: &patches)
        } else {
            arrangeLinear(slotIndex, in: newFrame, patches: &patches)
        }
    }

    mutating func arrangeOverlay(_ slotIndex: Int, in newFrame: Rect, patches: inout PatchBuffer) {
        var child = firstChild[slotIndex]
        while child >= 0 {
            var size = measured[Int(child)]
            let style = layout[Int(child)]
            if style.axis != .overlay,
               content[Int(child)].scrolls || scrollingLength(of: Int(child), along: style.axis) > 0
            {
                if style.axis == .row {
                    size.width = Swift.min(size.width, newFrame.width)
                } else {
                    size.height = Swift.min(size.height, newFrame.height)
                }
            }
            let fillsWidth = fills(Int(child), across: true)
            let fillsHeight = fills(Int(child), across: false)
            let bleed = slotIndex == Int(root) ? rootBleed : Insets()
            let childFrame = Rect(
                x: (fillsWidth ? -bleed.left : Self.aligned(style.align & 3, free: newFrame.width - size.width))
                    + style.dx,
                y: (fillsHeight ? -bleed.top : Self.aligned(style.align >> 2 & 3, free: newFrame.height - size.height))
                    + style.dy,
                width: fillsWidth ? newFrame.width + bleed.left + bleed.right : size.width,
                height: fillsHeight ? newFrame.height + bleed.top + bleed.bottom : size.height
            )
            arrange(slot: child, to: childFrame, patches: &patches)
            child = nextSibling[Int(child)]
        }
    }

    func fills(_ slotIndex: Int, across horizontal: Bool) -> Bool {
        (kind[slotIndex] == .shader || kind[slotIndex] == .path)
            && (horizontal ? layout[slotIndex].width : layout[slotIndex].height) < 0
    }

    mutating func clampScroll(_ slotIndex: Int, limit: Float, patches: inout PatchBuffer) {
        scrollLimit[slotIndex] = limit
        guard scrollOffset[slotIndex] > limit else { return }
        scrollOffset[slotIndex] = limit
        patches.ops.append(.setScroll(
            handle(Int32(slotIndex)),
            offset: limit,
            vertical: layout[slotIndex].axis == .column
        ))
    }

    func scrolls(_ slotIndex: Int, along axis: Axis) -> Bool {
        content[slotIndex].scrolls && layout[slotIndex].axis == axis
    }

    func scrollingLength(of slotIndex: Int, along axis: Axis) -> Float {
        var length: Float = 0
        var child = firstChild[slotIndex]
        while child >= 0 {
            if scrolls(Int(child), along: axis) {
                length += axis == .row ? measured[Int(child)].width : measured[Int(child)].height
            }
            child = nextSibling[Int(child)]
        }
        return length
    }

    static func aligned(_ edge: UInt8, free: Float) -> Float {
        switch edge {
        case 1: 0
        case 2: free
        default: free / 2
        }
    }

    mutating func arrangeLinear(_ slotIndex: Int, in newFrame: Rect, patches: inout PatchBuffer) {
        let style = layout[slotIndex]
        let row = style.axis == .row
        var used: Float = style.padding * 2
        var growTotal: Float = 0
        var count = 0
        var child = firstChild[slotIndex]
        while child >= 0 {
            let size = measured[Int(child)]
            used += row ? size.width : size.height
            growTotal += layout[Int(child)].grow
            count += 1
            child = nextSibling[Int(child)]
        }
        if count > 1 {
            used += style.gap * Float(count - 1)
        }
        let available = row ? newFrame.width : newFrame.height
        let crossAvailable = row ? newFrame.height : newFrame.width
        let free = Swift.max(0, available - used)
        let shrinkable = used > available ? scrollingLength(of: slotIndex, along: style.axis) : 0
        let absorbed = Swift.min(Swift.max(0, used - available), shrinkable)
        if content[slotIndex].scrolls {
            clampScroll(slotIndex, limit: Swift.max(0, used - absorbed - available), patches: &patches)
        }
        var cursor = style.padding
        child = firstChild[slotIndex]
        while child >= 0 {
            let childIndex = Int(child)
            let size = measured[childIndex]
            var main = row ? size.width : size.height
            if growTotal > 0 {
                main += free * layout[childIndex].grow / growTotal
            }
            if absorbed > 0, scrolls(childIndex, along: style.axis) {
                main -= absorbed * main / shrinkable
            }
            let cross = row ? size.height : size.width
            let crossPosition = style.centerCross ? (crossAvailable - cross) / 2 : style.padding
            let childFrame = row
                ? Rect(x: cursor, y: crossPosition, width: main, height: cross)
                : Rect(x: crossPosition, y: cursor, width: cross, height: main)
            arrange(slot: child, to: childFrame, patches: &patches)
            cursor += main + style.gap
            child = nextSibling[childIndex]
        }
    }
}
