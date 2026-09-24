// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import SwiftUI

struct SavedDiagnosticsSection: View {
    let files: [DiagnosticsFile]
    let onRevealFolder: () -> Void
    let onRefresh: () -> Void
    let copyFile: (URL) -> Void

    @ViewBuilder
    var body: some View {
        Section("Saved Diagnostics") {
            if files.isEmpty {
                Text("No diagnostics files yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(files.prefix(10)) { file in
                    savedDiagnosticRow(file)
                }
            }
            HStack {
                Button("Refresh") {
                    onRefresh()
                }
                Button("Reveal Folder") {
                    onRevealFolder()
                }
            }
        }
    }

    @ViewBuilder
    private func savedDiagnosticRow(_ file: DiagnosticsFile) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button("Copy Path") {
                    copyToPasteboard(file.url.path)
                }
                .accessibilityLabel("Copy path for \(file.name)")
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
                .accessibilityLabel("Reveal \(file.name) in Finder")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        } label: {
            Text(artifactType(file))
                .font(.callout)
            Text(file.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(file.modified.formatted(date: .abbreviated, time: .shortened)) · \(byteCount(file.sizeBytes))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Copy Path") {
                copyToPasteboard(file.url.path)
            }
            Button("Copy File") {
                copyFile(file.url)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func artifactType(_ file: DiagnosticsFile) -> String {
        let name = file.name
        if name.hasPrefix("omniwm-trace-") {
            return name.hasSuffix(".partial.log")
                ? String(localized: "Trace (incomplete)")
                : String(localized: "Trace")
        }
        if name.hasPrefix("omniwm-performance-") {
            return String(localized: "Performance")
        }
        if name.hasPrefix("omniwm-crash-") {
            return String(localized: "Crash")
        }
        if name.hasPrefix("omniwm-diagnostics-") {
            return String(localized: "Diagnostics")
        }
        return name
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
