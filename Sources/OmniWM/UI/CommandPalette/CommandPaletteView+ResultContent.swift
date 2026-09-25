// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

extension CommandPaletteView {
    var launcherResults: some View {
        CommandPaletteLauncherResultsView(
            mode: controller.selectedMode,
            applicationSections: controller.applicationSections,
            fileSections: controller.fileSections,
            chips: controller.launcherChips,
            selectedChipID: controller.selectedLauncherChipID,
            viewStyle: controller.launcherViewStyle,
            selectedItem: controller.selectedLauncherItem,
            scrollRequest: controller.selectionScrollRequest,
            requestGeneration: controller.launcherRequestGeneration,
            showsPaths: controller.launcherShowsPaths,
            onChipSelect: { controller.selectLauncherChip($0) },
            onViewStyleChange: { controller.setLauncherViewStyle($0) },
            onSelect: { controller.selectLauncherItem($0, activate: false) },
            onActivate: { controller.selectLauncherItem($0, activate: true) },
            onContextAction: { controller.performLauncherContextAction($1, for: $0) },
            onColumnCountChange: { controller.launcherColumnCount = $0 }
        )
    }

    @ViewBuilder
    var clipboardPreview: some View {
        if controller.isClipboardPreviewLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview = controller.clipboardPreview {
            ScrollView([.vertical, .horizontal]) {
                switch preview {
                case let .text(text):
                    Text(text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .image:
                    if let image = controller.clipboardPreviewImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Preview unavailable")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
        } else {
            Text("Preview unavailable")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
