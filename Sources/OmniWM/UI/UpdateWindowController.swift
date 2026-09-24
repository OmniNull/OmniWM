// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class UpdateWindowController: UpdateWindowControlling {
    static let shared = UpdateWindowController()

    var onWindowClosedWithoutAction: (() -> Void)?

    private let presenter = HostedWindowPresenter()
    private var actionHandledOnClose = false

    func show(configuration: UpdatePopupConfiguration) {
        actionHandledOnClose = false
        if let window = presenter.window,
           let hosting = window.contentViewController as? NSHostingController<UpdatePopupView>
        {
            hosting.rootView = UpdatePopupView(configuration: configuration)
            centerOnMouseScreen(window)
        }

        presenter.present(
            title: String(localized: "Update Available"),
            styleMask: [.titled, .closable, .fullSizeContentView],
            contentSize: NSSize(width: 720, height: 560),
            minSize: NSSize(width: 620, height: 460),
            center: centerOnMouseScreen,
            configure: { window in
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isOpaque = false
                window.backgroundColor = .clear
                window.collectionBehavior = [.moveToActiveSpace]
            },
            onWillClose: { [weak self] in
                guard let self else { return }
                let shouldNotify = !actionHandledOnClose
                actionHandledOnClose = false
                if shouldNotify {
                    onWindowClosedWithoutAction?()
                }
            },
            content: {
                UpdatePopupView(configuration: configuration)
            }
        )
    }

    func close(markingActionHandled: Bool) {
        if markingActionHandled {
            actionHandledOnClose = true
        }
        presenter.close()
    }

    private func centerOnMouseScreen(_ window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else {
            window.center()
            return
        }

        let origin = CGPoint(
            x: screen.frame.midX - window.frame.width / 2,
            y: screen.frame.midY - window.frame.height / 2
        )
        window.setFrameOrigin(origin)
    }
}

private struct UpdatePopupView: View {
    let configuration: UpdatePopupConfiguration

    @State private var copiedCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            versionStrip
            releaseNotesSection
            footer
        }
        .padding(28)
        .frame(width: 720, height: 560)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("OmniWM Update Available")
                    .font(.system(size: 28, weight: .bold))
            }

            Text(configuration.releaseTitle)
                .font(.system(size: 16, weight: .semibold))

            if let publishedDateText = configuration.publishedDateText {
                Text("Published \(publishedDateText)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var versionStrip: some View {
        HStack(spacing: 12) {
            versionCard(label: String(localized: "Current"), value: configuration.currentVersion)
            versionCard(label: String(localized: "Latest"), value: configuration.latestVersion)
            Spacer()
            commandChip
        }
    }

    private func versionCard(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var commandChip: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("Manual update command")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(UpdateCoordinator.homebrewUpdateCommand)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.14))
                .clipShape(Capsule())
        }
    }

    private var releaseNotesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Release Notes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(configuration.releaseNotes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }
            .padding(16)
            .background(.black.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Updates stay manual. OmniWM can open the release page or copy the Homebrew upgrade command for you.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Skip This Version") {
                    configuration.skipThisVersion()
                }
                .buttonStyle(.omniGlass)

                Button("Not Now") {
                    configuration.notNow()
                }
                .buttonStyle(.omniGlass)

                Spacer()

                Button(copiedCommand ? String(localized: "Copied") : String(localized: "Copy brew upgrade omniwm")) {
                    configuration.copyCommand()
                    copiedCommand = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedCommand = false
                    }
                }
                .buttonStyle(.omniGlass)

                Button("Open Release Page") {
                    configuration.openReleasePage()
                }
                .buttonStyle(.omniGlassProminent)
            }
        }
    }
}
