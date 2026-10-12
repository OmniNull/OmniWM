// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct HiddenBarGlyph: Identifiable, Equatable {
    let key: MenuBarItemKey
    let name: String
    let image: NSImage?
    let size: CGSize

    var id: MenuBarItemKey {
        key
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.name == rhs.name && lhs.image === rhs.image && lhs.size == rhs.size
    }
}

@MainActor
@Observable
final class HiddenBarPanelModel {
    var items: [HiddenBarGlyph] = []
    var focusRequest = 0
    var placement: HiddenBarPanelPlacement?
    var layout: HiddenBarPanelLayout?
}

struct HiddenBarPanelView: View {
    @Bindable var model: HiddenBarPanelModel
    var onActivate: (MenuBarItemKey) -> Void
    var onDismiss: () -> Void

    @FocusState private var focusedKey: MenuBarItemKey?

    private var bodyInsets: EdgeInsets {
        guard let layout = model.layout else { return EdgeInsets() }
        return EdgeInsets(
            top: layout.body.minY,
            leading: layout.body.minX,
            bottom: layout.frame.height - layout.body.maxY,
            trailing: layout.frame.width - layout.body.maxX
        )
    }

    var body: some View {
        Group {
            if model.items.isEmpty {
                Text("No hidden items")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: cellHeight)
            } else {
                glyphs
            }
        }
        .padding(
            .horizontal,
            isVertical ? HiddenBarPanelController.crossPadding : HiddenBarPanelController.alongPadding
        )
        .padding(.vertical, isVertical ? HiddenBarPanelController.alongPadding : HiddenBarPanelController.crossPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(bodyInsets)
        .background {
            if let layout = model.layout {
                HiddenBarPanelBackground(layout: layout, placement: model.placement)
            }
        }
        .onAppear {
            focusFirstItem()
        }
        .onChange(of: model.focusRequest) { _, _ in
            focusFirstItem()
        }
        .onChange(of: model.items.map(\.key)) { _, keys in
            if let focusedKey, keys.contains(focusedKey) {
                return
            }
            focusFirstItem()
        }
        .onKeyPress(keys: [.tab, .leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            handleKeyPress(press)
        }
        .onExitCommand(perform: onDismiss)
    }

    private var isVertical: Bool {
        model.placement?.isVertical == true
    }

    private var cellHeight: CGFloat {
        model.placement?.cellHeight ?? 20
    }

    private var glyphs: some View {
        let outer = isVertical
            ? AnyLayout(HStackLayout(alignment: .top, spacing: HiddenBarPanelController.lineSpacing))
            : AnyLayout(VStackLayout(spacing: HiddenBarPanelController.lineSpacing))
        let inner = isVertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return outer {
            ForEach(Array(itemRanges.enumerated()), id: \.offset) { _, range in
                inner {
                    ForEach(range, id: \.self) { index in
                        HiddenBarGlyphButton(
                            glyph: model.items[index],
                            width: isVertical ? columnWidth(range) : itemWidths[index],
                            height: cellHeight,
                            isFocused: focusedKey == model.items[index].key,
                            onActivate: onActivate
                        )
                        .focused($focusedKey, equals: model.items[index].key)
                    }
                }
            }
        }
    }

    private var itemWidths: [CGFloat] {
        model.items.map { HiddenBarPanelController.glyphDisplayWidth(for: $0.size) }
    }

    private func columnWidth(_ range: Range<Int>) -> CGFloat {
        itemWidths[range].max() ?? HiddenBarPanelController.minimumTargetSide
    }

    private var itemRanges: [Range<Int>] {
        guard let placement = model.placement else { return [] }
        return HiddenBarPanelController.itemRanges(itemWidths: itemWidths, placement: placement)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .tab:
            moveLinear(by: press.modifiers.contains(.shift) ? -1 : 1)
        case .leftArrow:
            if isVertical { moveAcrossLines(by: -1) } else { moveLinear(by: -1) }
        case .rightArrow:
            if isVertical { moveAcrossLines(by: 1) } else { moveLinear(by: 1) }
        case .upArrow:
            if isVertical { moveLinear(by: -1) } else { moveAcrossLines(by: -1) }
        case .downArrow:
            if isVertical { moveLinear(by: 1) } else { moveAcrossLines(by: 1) }
        default:
            return .ignored
        }
        return .handled
    }

    private func focusFirstItem() {
        focusedKey = model.items.first?.key
    }

    private func moveLinear(by offset: Int) {
        guard !model.items.isEmpty else { return }
        guard let currentIndex else {
            focusFirstItem()
            return
        }
        let count = model.items.count
        focusedKey = model.items[(currentIndex + offset + count) % count].key
    }

    private func moveAcrossLines(by offset: Int) {
        let ranges = itemRanges
        guard ranges.count > 1, let currentIndex,
              let currentRow = ranges.firstIndex(where: { $0.contains(currentIndex) })
        else {
            if focusedKey == nil {
                focusFirstItem()
            }
            return
        }
        let targetRow = (currentRow + offset + ranges.count) % ranges.count
        let column = currentIndex - ranges[currentRow].lowerBound
        let targetRange = ranges[targetRow]
        let targetIndex = targetRange.lowerBound + min(column, targetRange.count - 1)
        focusedKey = model.items[targetIndex].key
    }

    private var currentIndex: Int? {
        guard let focusedKey else { return nil }
        return model.items.firstIndex { $0.key == focusedKey }
    }
}

private struct HiddenBarGlyphButton: View {
    let glyph: HiddenBarGlyph
    let width: CGFloat
    let height: CGFloat
    let isFocused: Bool
    var onActivate: (MenuBarItemKey) -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            onActivate(glyph.key)
        } label: {
            glyphImage
                .frame(width: width, height: height)
                .clipped()
                .background {
                    if hovering || isFocused {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                            .padding(2)
                    }
                }
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(glyph.name)
        .accessibilityLabel(String(localized: "\(glyph.name), menu bar item \(glyph.key.ordinal + 1)"))
        .accessibilityHint("Reveals this item and opens its menu")
        .onHover { hovering = $0 }
    }

    private var glyphImage: some View {
        Group {
            if let image = glyph.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: glyph.size.width, height: glyph.size.height)
            } else {
                Image(systemName: "app.dashed")
                    .resizable().scaledToFit()
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
        }
    }
}
