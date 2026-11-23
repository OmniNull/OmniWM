// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func settingsField(_ mark: SettingsFieldMark?) -> some View {
        if let mark { modifier(mark) }
        else { self }
    }

    func settingsField(_ paths: SettingsFieldID...) -> some View {
        modifier(SettingsFieldMark(fields: paths))
    }

    func settingsField(_ path: SettingsFieldID, member: String) -> some View {
        modifier(SettingsFieldMark(fields: [path], member: .key(member)))
    }

    func settingsField(_ path: SettingsFieldID, row: String?, leaf: String...) -> some View {
        modifier(SettingsFieldMark(fields: [path], member: .row(row), leaves: leaf))
    }

    func settingsField(_ path: SettingsFieldID, index: Int?, element: String? = nil, leaf: String...) -> some View {
        modifier(SettingsFieldMark(fields: [path], member: .index(index), leaves: leaf, element: element))
    }
}

struct SettingsFieldMark: ViewModifier {
    @Environment(SettingsStore.self) private var settings: SettingsStore?
    let fields: [SettingsFieldID]
    var member: SettingsFieldMember?
    var leaves: [String] = []
    var element: String?

    func body(content: Content) -> some View {
        let sites = settings?.fieldSources.sites(for: fields, member: member, leaves: leaves, element: element) ?? []
        if !sites.isEmpty, let settings, let document = settings.fieldSources.document {
            VStack(alignment: .leading, spacing: 2) {
                content
                SettingsSourceButton(sites: sites, file: settings.settingsFileURL, source: document.source)
                    .environment(\.isEnabled, true)
            }
        } else {
            content
        }
    }
}

extension SettingsFieldMark {
    init(_ paths: SettingsFieldID...) {
        self.init(fields: paths)
    }

    init(_ path: SettingsFieldID, row: String?, leaf: String...) {
        self.init(fields: [path], member: .row(row), leaves: leaf)
    }
}

private struct SettingsSourceButton: View {
    let sites: [SettingsCodeSite]
    let file: URL
    let source: Data
    @State private var selection: SettingsSourceSelection?

    var body: some View {
        if let first = sites.first {
            Group {
                if sites.count == 1 {
                    Button(label(first)) { open(first) }
                } else {
                    Menu(label(first)) {
                        ForEach(sites) { site in Button(label(site)) { open(site) } }
                    }
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .sheet(item: $selection) { selection in
                VStack(alignment: .leading) {
                    Text(verbatim: selection.file.lastPathComponent + ":" + String(selection.site.line)).font(.headline)
                    SettingsSourceText(selection: selection)
                    HStack {
                        Button("Edit Settings File") { NSWorkspace.shared.open(selection.file) }
                        Spacer()
                        Button("Close") { self.selection = nil }.keyboardShortcut(.cancelAction)
                    }
                }
                .padding()
                .frame(minWidth: 540, minHeight: 320)
            }
        }
    }

    private func label(_ site: SettingsCodeSite) -> String {
        String(localized: "Code · \(file.lastPathComponent):\(site.line)")
    }

    private func open(_ site: SettingsCodeSite) {
        selection = SettingsSourceSelection(file: file, source: source, site: site)
    }
}

private struct SettingsSourceSelection: Identifiable {
    let file: URL
    let source: Data
    let site: SettingsCodeSite
    var id: SettingsCodeSite {
        site
    }
}

private struct SettingsSourceText: NSViewControllerRepresentable {
    let selection: SettingsSourceSelection

    func makeNSViewController(context _: Context) -> SourceController {
        let controller = SourceController()
        let scroll = NSTextView.scrollableTextView()
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isRichText = false
            text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            text.string = String(decoding: selection.source, as: UTF8.self)
            let range = selection.site.selection(in: selection.source)
            text.setSelectedRange(range)
        }
        controller.view = scroll
        return controller
    }

    func updateNSViewController(_: SourceController, context _: Context) {}

    final class SourceController: NSViewController {
        override func viewDidAppear() {
            super.viewDidAppear()
            guard let scroll = view as? NSScrollView, let text = scroll.documentView as? NSTextView else { return }
            text.scrollRangeToVisible(text.selectedRange())
        }
    }
}
