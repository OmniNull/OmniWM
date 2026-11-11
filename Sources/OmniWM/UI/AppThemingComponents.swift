// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

extension AppThemeColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: alpha)
    }
}

struct AppThemePalettePreview: View {
    let palette: AppThemePalette?
    let dark: Bool

    var body: some View {
        if let scheme = palette?.scheme(dark: dark) {
            HStack(alignment: .top, spacing: 14) {
                terminal(scheme)
                VStack(alignment: .leading, spacing: 4) {
                    swatches(Array(scheme.ansi.prefix(8)))
                    swatches(Array(scheme.ansi.suffix(8)))
                    SettingsCaption(
                        localized: "Terminal colors 0 to 15. Colors 1 to 15 keep at least 4.5:1 contrast with the background."
                    )
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(dark ? Text("Dark palette preview") : Text("Light palette preview"))
        } else {
            SettingsCaption(localized: "Waiting for OmniWM’s palette.")
        }
    }

    private func terminal(_ scheme: AppThemePalette.Scheme) -> some View {
        let background = scheme.roles[.background] ?? .black
        let foreground = scheme.ansi[15]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text(verbatim: "~ ").foregroundStyle(scheme.ansi[4].swiftUIColor)
                Text(verbatim: "git status").foregroundStyle(foreground.swiftUIColor)
            }
            HStack(spacing: 0) {
                Text(verbatim: "modified: ").foregroundStyle(scheme.ansi[1].swiftUIColor)
                Text(verbatim: "theme.toml").foregroundStyle(scheme.ansi[3].swiftUIColor)
            }
            HStack(spacing: 0) {
                Text(verbatim: "added: ").foregroundStyle(scheme.ansi[2].swiftUIColor)
                Text(verbatim: "kitty.conf").foregroundStyle(scheme.ansi[5].swiftUIColor)
            }
            Text(verbatim: "# 2 files").foregroundStyle(scheme.ansi[8].swiftUIColor)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .frame(width: 170, alignment: .leading)
        .background(background.swiftUIColor, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private func swatches(_ colors: [AppThemeColor]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.swiftUIColor)
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                    .help(color.hex)
            }
        }
    }
}

struct AppThemingPaths: View {
    let paths: [String]

    var body: some View {
        ForEach(paths, id: \.self) { path in
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(verbatim: path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    reveal(path)
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .help(Text("Show in Finder"))
            }
        }
    }

    private func reveal(_ path: String) {
        let expanded = path.hasPrefix("~/")
            ? FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
            : path
        let url = URL(fileURLWithPath: expanded)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

struct AppThemingStatus: View {
    let result: AppThemeResult?
    let onReview: () -> Void

    var body: some View {
        if let result {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon(result)).foregroundStyle(tint(result))
                    Text(verbatim: result.message).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(verbatim: Self.time(result.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let reload = result.reload {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: result.reloadFailed ? "arrow.clockwise.circle" : "arrow.clockwise")
                            .foregroundStyle(result.reloadFailed ? Color.orange : Color.secondary)
                        Text(verbatim: reload).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if result.outcome == .conflict {
                    Button("Review and Replace…", action: onReview)
                }
            }
        } else {
            SettingsCaption(localized: "Not written yet.")
        }
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    private func icon(_ result: AppThemeResult) -> String {
        switch result.outcome {
        case .updated,
             .unchanged: result.reloadFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .conflict: "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ result: AppThemeResult) -> Color {
        switch result.outcome {
        case .updated,
             .unchanged: result.reloadFailed ? .orange : .green
        case .failed: .red
        case .conflict: .orange
        }
    }
}

struct AppThemingPlaceholderHelp: View {
    var body: some View {
        Section {
            DisclosureGroup("Template Placeholders") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "{{colors.<name>.<variant>.<format>}}").font(.caption.monospaced())
                    SettingsCaption(
                        localized: "Names: every OmniWM palette role, such as background, foreground, accent or accentContainer, plus ansi0 to ansi15."
                    )
                    SettingsCaption(
                        localized: "Variants: default follows macOS light and dark; light and dark pick one."
                    )
                    SettingsCaption(
                        localized: "Formats: hex, hex_stripped, rgb, rgba, red, green, blue and alpha. {{mode}} is light or dark."
                    )
                    HStack(spacing: 4) {
                        SettingsCaption(localized: "For literal braces, write")
                        Text(verbatim: "\\{{").font(.caption.monospaced())
                    }
                    SettingsCaption(localized: "Templates are only filled in. Nothing in a template is ever run.")
                }
                .padding(.vertical, 4)
            }
        }
    }
}
