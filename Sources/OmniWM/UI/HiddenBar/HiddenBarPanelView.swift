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
    var maxContentWidth: CGFloat = 600
    var focusRequest = 0
}

struct HiddenBarPanelView: View {
    @Bindable var model: HiddenBarPanelModel
    var onActivate: (MenuBarItemKey) -> Void
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @FocusState private var focusedKey: MenuBarItemKey?

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        Group {
            if model.items.isEmpty {
                Text("No hidden items")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: HiddenBarPanelController.rowHeight)
            } else {
                rows
            }
        }
        .padding(HiddenBarPanelController.padding)
        .background {
            if accessibilityReduceTransparency {
                barShape.fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
            } else {
                barShape.fill(.ultraThinMaterial)
            }
            barShape.strokeBorder(
                colorSchemeContrast == .increased
                    ? Color.primary.opacity(0.45)
                    : Color.secondary.opacity(0.18),
                lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
            )
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

    private var rows: some View {
        return VStack(spacing: HiddenBarPanelController.spacing) {
            ForEach(Array(rowRanges.enumerated()), id: \.offset) { _, range in
                HStack(spacing: HiddenBarPanelController.spacing) {
                    ForEach(range, id: \.self) { index in
                        HiddenBarGlyphButton(
                            glyph: model.items[index],
                            width: itemWidths[index],
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
        model.items.map {
            HiddenBarPanelController.glyphDisplayWidth(for: $0.size, rowHeight: HiddenBarPanelController.rowHeight)
        }
    }

    private var rowRanges: [Range<Int>] {
        HiddenBarPanelController.rowRanges(
            itemWidths: itemWidths,
            maxContentWidth: model.maxContentWidth,
            spacing: HiddenBarPanelController.spacing
        )
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .tab:
            moveLinear(by: press.modifiers.contains(.shift) ? -1 : 1)
        case .leftArrow:
            moveLinear(by: -1)
        case .rightArrow:
            moveLinear(by: 1)
        case .upArrow:
            moveVertically(by: -1)
        case .downArrow:
            moveVertically(by: 1)
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

    private func moveVertically(by offset: Int) {
        let ranges = rowRanges
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
    let isFocused: Bool
    var onActivate: (MenuBarItemKey) -> Void

    @State private var hovering = false

    var body: some View {
        Button {
            onActivate(glyph.key)
        } label: {
            glyphImage
                .frame(
                    width: width - HiddenBarPanelController.glyphInset * 2,
                    height: HiddenBarPanelController.rowHeight - HiddenBarPanelController.glyphInset * 2
                )
                .padding(HiddenBarPanelController.glyphInset)
                .background {
                    if hovering || isFocused {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                    }
                }
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
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
                    .interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "app.dashed")
                    .resizable().scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
        }
    }
}
