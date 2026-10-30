// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Observation
import SwiftUI

@MainActor
@Observable
final class ShellStyleGallery: Identifiable {
    enum Status: Equatable {
        case available
        case installed
        case otherCopy
    }

    static let source: (any ShellStyleSource)? = ShellStyleRepository.current ?? ShellGitHubStyleSource.official()

    let editor: ShellDesktopEditor
    let source: any ShellStyleSource
    private(set) var listings: [ShellStyleListing] = []
    private(set) var busy: Set<String> = []
    private(set) var notice: String?
    var problem: String?

    init(editor: ShellDesktopEditor, source: any ShellStyleSource) {
        self.editor = editor
        self.source = source
    }

    private var configuration: ShellConfigurationCoordinator {
        editor.configuration
    }

    func load() async {
        let source = source
        do {
            listings = try await Task.detached { try await source.styles() }.value
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func status(of name: String) -> Status {
        guard let style = configuration.styles.first(where: { $0.name == name }) else { return .available }
        return style.receipt == nil ? .otherCopy : .installed
    }

    func isActive(_ name: String) -> Bool {
        configuration.config.profile == name
    }

    func install(_ listing: ShellStyleListing, replacing: Bool) async {
        let source = source
        await perform(listing.name) { [configuration] in
            let payload = try await Task.detached { try await source.payload(for: listing) }.value
            return try await configuration.installStyle(payload, replacing: replacing)
        }
    }

    func use(_ name: String) async {
        await perform(name) { [configuration] in
            _ = try await configuration.selectProfile(name)
            return nil
        }
    }

    func remove(_ name: String) async {
        if editor.selectedStyle == name {
            let remaining = isActive(name) ? ShellDefaults.profile : configuration.config.profile
            guard await editor.selectStyle(remaining) else {
                problem = String(localized: "Save or discard your changes to this style first.")
                return
            }
        }
        await perform(name) { [configuration] in try await configuration.removeStyle(name) }
    }

    private func perform(_ name: String, _ operation: () async throws -> URL?) async {
        guard busy.insert(name).inserted else { return }
        defer { busy.remove(name) }
        do {
            let previous = try await operation()
            notice = previous.map { String(localized: "Your previous copy is in \($0.path).") }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

struct ShellStyleGalleryView: View {
    let gallery: ShellStyleGallery
    @Environment(\.dismiss) private var dismiss
    @State private var replacing: ShellStyleListing?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Get Styles").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let problem = gallery.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if let notice = gallery.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            List(gallery.listings) { listing in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(listing.manifest.title).font(.headline)
                        Text(listing.manifest.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    actions(listing)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .task { await gallery.load() }
        .confirmationDialog(
            "Replace your copy of \(replacing?.manifest.title ?? "")?",
            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
            presenting: replacing
        ) { listing in
            Button("Replace") { Task { await gallery.install(listing, replacing: true) } }
        } message: { _ in
            Text("Your current copy moves to the .backups folder in your shell folder.")
        }
    }

    @ViewBuilder
    private func actions(_ listing: ShellStyleListing) -> some View {
        if gallery.busy.contains(listing.name) {
            ProgressView().controlSize(.small)
        } else {
            switch gallery.status(of: listing.name) {
            case .available:
                Button("Install") { Task { await gallery.install(listing, replacing: false) } }
            case .otherCopy:
                Button("Replace…") { replacing = listing }
            case .installed:
                if gallery.isActive(listing.name) {
                    Text("In Use").foregroundStyle(.secondary)
                } else {
                    Button("Use Style") { Task { await gallery.use(listing.name) } }
                }
                Button("Remove") { Task { await gallery.remove(listing.name) } }
            }
        }
    }
}
