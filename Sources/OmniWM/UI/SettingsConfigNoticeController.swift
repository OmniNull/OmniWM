// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class SettingsConfigNoticeController {
    static let surfaceId = "settings-config-notice"

    private let settings: SettingsStore
    private let ownedWindowRegistry: OwnedWindowRegistry
    private let openFile: (URL) -> Bool
    private var surface: (panel: NSPanel, hostingView: NSHostingView<SettingsConfigNoticeView>)?
    private(set) var issue: DiagnosticsIssue?
    private(set) var fileStatus: SettingsFileStatus?

    init(
        settings: SettingsStore,
        ownedWindowRegistry: OwnedWindowRegistry = .shared,
        openFile: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.settings = settings
        self.ownedWindowRegistry = ownedWindowRegistry
        self.openFile = openFile
    }

    isolated deinit {
        close()
    }

    func refresh() {
        let nextIssue = Self.issue(for: settings.configNotice, fileURL: settings.settingsFileURL)
        guard nextIssue != issue else { return }
        issue = nextIssue
        fileStatus = nil
        guard let issue else {
            close()
            return
        }
        let (panel, _) = surface ?? makeSurface(issue: issue)
        render(issue)
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main {
            panel.setFrameOrigin(CGPoint(
                x: screen.visibleFrame.maxX - panel.frame.width - 20,
                y: screen.visibleFrame.maxY - panel.frame.height - 20
            ))
        }
        panel.orderFrontRegardless()
    }

    func dismiss() {
        surface?.panel.orderOut(nil)
    }

    func close() {
        guard let surface else { return }
        ownedWindowRegistry.unregister(surfaceId: Self.surfaceId)
        surface.panel.close()
        self.surface = nil
    }

    func openSettingsFile() {
        do {
            fileStatus = try SettingsFileWorkflow.perform(.open, settings: settings, openFile: openFile)
        } catch {
            fileStatus = .error(error.localizedDescription)
        }
        if let issue { render(issue) }
    }

    private static func issue(for notice: SettingsConfigNotice?, fileURL: URL) -> DiagnosticsIssue? {
        guard let notice else { return nil }
        let kind: DiagnosticsIssue.Kind
        if case let .invalidRejected(reason) = notice {
            kind = .settingsInvalidRejected(reason: reason)
        } else if let reason = notice.blockingReason {
            kind = .settingsPersistenceBlocked(reason: reason, backupURL: nil)
        } else {
            return nil
        }
        return DiagnosticsIssue(kind: kind, configFileURL: fileURL)
    }

    private func content(_ issue: DiagnosticsIssue) -> SettingsConfigNoticeView {
        SettingsConfigNoticeView(
            issue: issue,
            fileStatus: fileStatus,
            openFile: { [weak self] in self?.openSettingsFile() },
            dismiss: { [weak self] in self?.dismiss() }
        )
    }

    private func render(_ issue: DiagnosticsIssue) {
        guard let surface else { return }
        surface.panel.title = issue.localizedTitle
        surface.hostingView.rootView = content(issue)
    }

    private func makeSurface(
        issue: DiagnosticsIssue
    ) -> (panel: NSPanel, hostingView: NSHostingView<SettingsConfigNoticeView>) {
        let panel = SettingsConfigNoticePanel(
            contentRect: CGRect(x: 0, y: 0, width: 440, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        let hostingView = NSHostingView(rootView: content(issue))
        panel.contentView = hostingView
        ownedWindowRegistry.register(
            panel,
            surfaceId: Self.surfaceId,
            policy: SurfacePolicy(
                kind: .utility,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        surface = (panel, hostingView)
        return (panel, hostingView)
    }
}

private final class SettingsConfigNoticePanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

private struct SettingsConfigNoticeView: View {
    let issue: DiagnosticsIssue
    let fileStatus: SettingsFileStatus?
    let openFile: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(issue.localizedTitle, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ScrollView {
                Text(issue.localizedMessage)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let fileStatus {
                Label(fileStatus.message, systemImage: fileStatus.icon)
                    .font(.caption)
                    .foregroundStyle(fileStatus.color)
                    .lineLimit(2)
            }
            HStack {
                Button("Edit Settings File", action: openFile)
                Spacer()
                Button("Dismiss", action: dismiss)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
