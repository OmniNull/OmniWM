// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct CommandPaletteLauncherCell: View {
    let displayName: String
    let subtitle: String?
    let symbolName: String
    let image: NSImage?
    let viewStyle: LauncherViewStyle
    let isSelected: Bool
    let nameLineLimit: Int
    let onSelect: () -> Void
    let onActivate: () -> Void

    var body: some View {
        Button {
            onSelect()
            onActivate()
        } label: {
            if viewStyle == .grid {
                gridContent
            } else {
                listContent
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var gridContent: some View {
        VStack(spacing: 7) {
            icon(size: 75)
                .frame(width: 75, height: 75)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

            Text(displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(nameLineLimit)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: nameLineLimit == 1 ? 112 : 128)
        .padding(6)
        .background(selectionBackground)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var listContent: some View {
        HStack(spacing: 10) {
            icon(size: 28)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 45)
        .padding(.horizontal, 12)
        .background(selectionBackground)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var selectionBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
    }

    @ViewBuilder
    private func icon(size: CGFloat) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: size * 0.48, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}
