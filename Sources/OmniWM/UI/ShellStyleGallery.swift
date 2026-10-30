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
        case update
        case otherCopy
    }

    static let source: (any ShellStyleSource)? = ShellStyleRepository.current ?? ShellGitHubStyleSource.official()

    let editor: ShellDesktopEditor
    let source: any ShellStyleSource
    private(set) var listings: [ShellStyleListing] = []
    private(set) var busy: Set<String> = []
    private(set) var notice: String?
    var confirming: ShellStyleListing?
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

    func status(of listing: ShellStyleListing) -> Status {
        guard let style = configuration.styles.first(where: { $0.name == listing.name }) else { return .available }
        guard let receipt = style.receipt else { return .otherCopy }
        guard let installed = ReleaseVersion(receipt.version), let offered = ReleaseVersion(listing.manifest.version),
              offered > installed
        else { return .installed }
        return .update
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

    func update(_ listing: ShellStyleListing) async {
        guard let receipt = configuration.style(listing.name).receipt else { return }
        let folder = configuration.shellDirectory.appendingPathComponent(listing.name, isDirectory: true)
        let changed = await Task.detached {
            (try? ShellStyleInstaller.hasChanges(in: folder, from: receipt)) ?? true
        }.value
        if changed {
            confirming = listing
        } else {
            await install(listing, replacing: true)
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
    @State private var selected: ShellStyleListing?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if selected != nil {
                    Button("Back", systemImage: "chevron.left") { selected = nil }
                }
                Text(selected?.manifest.title ?? String(localized: "Get Styles")).font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let problem = gallery.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if let notice = gallery.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            } else if selected == nil {
                Text("Styles change how the bar, island and drawers look.").font(.callout).foregroundStyle(.secondary)
            }
            if let selected {
                ShellStyleDetail(gallery: gallery, listing: selected)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(gallery.listings) { listing in
                            ShellStyleCard(gallery: gallery, listing: listing).onTapGesture { selected = listing }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 700, height: 520)
        .task { await gallery.load() }
        .confirmationDialog(
            confirmation(gallery.confirming),
            isPresented: Binding(get: { gallery.confirming != nil }, set: { if !$0 { gallery.confirming = nil } }),
            presenting: gallery.confirming
        ) { listing in
            Button(gallery.status(of: listing) == .update ? "Back Up and Update" : "Replace") {
                Task { await gallery.install(listing, replacing: true) }
            }
        } message: { _ in
            Text("Your current copy moves to the .backups folder in your shell folder.")
        }
    }

    private func confirmation(_ listing: ShellStyleListing?) -> String {
        guard let listing else { return "" }
        return gallery.status(of: listing) == .update
            ? String(localized: "Update \(listing.manifest.title)? You changed its files.")
            : String(localized: "Replace your copy of \(listing.manifest.title)?")
    }
}

private struct ShellStyleCard: View {
    let gallery: ShellStyleGallery
    let listing: ShellStyleListing

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ShellStylePicture(url: listing.previews.first).frame(height: 112)
            Text(listing.manifest.title).font(.headline).padding(.top, 4)
            Text(listing.manifest.summary).font(.callout).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            Text(verbatim: listing.byline).font(.caption).foregroundStyle(.tertiary)
            HStack {
                badge
                Spacer(minLength: 4)
                ShellStyleActions(gallery: gallery, listing: listing)
            }
            .padding(.top, 4)
        }
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay {
            if gallery.isActive(listing.name) {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var badge: some View {
        switch gallery.status(of: listing) {
        case .available: EmptyView()
        case .installed: label(gallery.isActive(listing.name) ? "In Use" : "Installed", tint: .green)
        case .update: label("Update Available", tint: .orange)
        case .otherCopy: label("Your Copy", tint: .secondary)
        }
    }

    private func label(_ text: LocalizedStringKey, tint: Color) -> some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: .capsule)
    }
}

private struct ShellStyleDetail: View {
    let gallery: ShellStyleGallery
    let listing: ShellStyleListing
    @State private var page = 0

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 8) {
                ShellStylePicture(url: listing.previews.indices.contains(page) ? listing.previews[page] : nil)
                    .aspectRatio(16 / 10, contentMode: .fit)
                if listing.previews.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(listing.previews.indices, id: \.self) { index in
                            Button { page = index } label: {
                                Circle().fill(index == page ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                                    .frame(width: 7, height: 7)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(listing.manifest.summary).font(.headline)
                if let description = listing.manifest.description {
                    Text(description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: listing.byline).font(.caption).foregroundStyle(.tertiary)
                ShellStyleActions(gallery: gallery, listing: listing, showsRemove: true).padding(.top, 4)
            }
            .frame(width: 240, alignment: .leading)
        }
    }
}

private struct ShellStyleActions: View {
    let gallery: ShellStyleGallery
    let listing: ShellStyleListing
    var showsRemove = false

    var body: some View {
        if gallery.busy.contains(listing.name) {
            ProgressView().controlSize(.small)
        } else {
            let status = gallery.status(of: listing)
            HStack(spacing: 6) {
                switch status {
                case .available:
                    Button("Install") { Task { await gallery.install(listing, replacing: false) } }
                case .otherCopy:
                    Button("Replace…") { gallery.confirming = listing }
                case .update:
                    Button("Update") { Task { await gallery.update(listing) } }
                case .installed:
                    if !gallery.isActive(listing.name) {
                        Button("Use Style") { Task { await gallery.use(listing.name) } }
                    }
                }
                if showsRemove, status != .available {
                    Button("Remove") { Task { await gallery.remove(listing.name) } }
                }
            }
        }
    }
}

private struct ShellStylePicture: View {
    let url: URL?

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.background.tertiary)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.error != nil {
                            placeholder
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipShape(.rect(cornerRadius: 8))
    }

    private var placeholder: some View {
        Image(systemName: "paintpalette").font(.title2).foregroundStyle(.tertiary)
    }
}

extension ShellStyleListing {
    fileprivate var byline: String {
        [manifest.author, manifest.version, manifest.license].compactMap(\.self).joined(separator: " · ")
    }
}
