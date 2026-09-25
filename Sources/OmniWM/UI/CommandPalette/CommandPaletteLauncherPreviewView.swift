// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import QuickLookUI
import SwiftUI

struct CommandPaletteLauncherPreviewView: View {
    let item: LauncherFileResult

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LauncherQuickLookView(fileURL: item.fileURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if let kind = item.kind {
                    metadataRow("Kind", value: kind)
                }
                if let size = item.size {
                    metadataRow("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let createdAt = item.createdAt {
                    metadataRow("Created", value: createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let modifiedAt = item.modifiedAt {
                    metadataRow("Modified", value: modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let lastOpenedAt = item.lastOpenedAt {
                    metadataRow("Last Opened", value: lastOpenedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadataRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
    }
}

private struct LauncherQuickLookView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context _: Context) -> NSView {
        let container = NSView(frame: .zero)
        if let preview = QLPreviewView(frame: container.bounds, style: .normal) {
            preview.shouldCloseWithWindow = false
            preview.autostarts = false
            preview.previewItem = fileURL as NSURL
            preview.autoresizingMask = [.width, .height]
            container.addSubview(preview)
        }
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        guard let preview = container.subviews.first as? QLPreviewView else { return }
        if (preview.previewItem as? NSURL) != fileURL as NSURL {
            preview.previewItem = fileURL as NSURL
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator _: ()) {
        (container.subviews.first as? QLPreviewView)?.close()
    }
}
