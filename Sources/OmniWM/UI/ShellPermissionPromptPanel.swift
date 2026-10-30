// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class ShellPermissionPromptPanel {
    private let panel: NSPanel
    private let registry: OwnedWindowRegistry
    private var closed = false

    static func present(
        _ request: ShellPermissionPrompts.Request,
        title: String,
        answer: @escaping @MainActor (Bool) -> Void
    ) -> @MainActor () -> Void {
        let prompt = ShellPermissionPromptPanel(request: request, title: title, registry: .shared, answer: answer)
        return { prompt.close() }
    }

    private init(
        request: ShellPermissionPrompts.Request,
        title: String,
        registry: OwnedWindowRegistry,
        answer: @escaping @MainActor (Bool) -> Void
    ) {
        panel = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        self.registry = registry
        let availableHeight = (panel.screen ?? NSScreen.main).map {
            panel.contentRect(forFrameRect: $0.visibleFrame).height
        } ?? 600
        let maximumHeight = min(600, availableHeight)
        let view = ShellPermissionPromptView(
            request: request,
            name: title,
            maximumHeight: maximumHeight
        ) { [weak self] allowed in
            guard let self, !closed else { return }
            close()
            answer(allowed)
        }
        let content = NSHostingView(rootView: view)
        panel.title = "OmniWM"
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.center()
        registry.register(panel)
        panel.orderFrontRegardless()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        registry.windowWillClose(panel)
        panel.close()
    }
}

struct ShellPermissionPromptView: View {
    let request: ShellPermissionPrompts.Request
    let name: String
    let maximumHeight: CGFloat
    let answer: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .vertical) {
                information.fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    information
                }
            }
            SettingsCaption(
                localized: "OmniWM remembers your choice. You can change it in Settings › Network & Permissions."
            )
            HStack {
                Spacer()
                Button("Allow") { answer(true) }
                    .accessibilityIdentifier("shell-permission-allow")
                Button("Deny") { answer(false) }
                    .accessibilityIdentifier("shell-permission-deny")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(message).fixedSize(horizontal: false, vertical: true)
                }
            }
            details
            VStack(alignment: .leading, spacing: 2) {
                Text("Source").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: request.principal.source)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch request {
        case .network: "network"
        case .program: "terminal"
        }
    }

    private var title: String {
        switch request {
        case .network: String(localized: "Allow “\(name)” to connect to the internet?")
        case .program: String(localized: "Allow “\(name)” to run a program?")
        }
    }

    private var message: String {
        switch request {
        case .network:
            String(localized: "This widget asks to send requests to the servers below.")
        case let .program(approval):
            String(
                localized: "“\(name)” runs “\(approval.command.joined(separator: " "))” as you, with full access to your files and network. Only allow programs you trust."
            )
        }
    }

    @ViewBuilder private var details: some View {
        if case let .network(approval) = request {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(approval.key.hosts.sorted(), id: \.self) { host in
                    Text(verbatim: host).font(.body.monospaced()).textSelection(.enabled)
                }
            }
            .padding(.leading, 40)
            if let purpose = approval.purpose {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The widget’s own description").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: purpose).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
