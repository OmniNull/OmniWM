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
    let repositoryName: String?
    let listingProblems: [String]
    private(set) var listings: [ShellStyleListing] = []
    private(set) var busy: Set<String> = []
    private(set) var notice: String?
    var confirming: ShellStyleListing?
    var problem: String?

    init(editor: ShellDesktopEditor, source: any ShellStyleSource) {
        self.editor = editor
        self.source = source
        repositoryName = nil
        listingProblems = []
    }

    init(editor: ShellDesktopEditor, browse: ShellGitHubStyleSource.Browse) {
        self.editor = editor
        source = browse.source
        repositoryName = browse.source.repositoryName
        listingProblems = browse.problems
        listings = browse.listings
    }

    private var configuration: ShellConfigurationCoordinator {
        editor.configuration
    }

    var addedRepositories: [ShellGitHubStyleSource.Repository] {
        Set(configuration.styles.compactMap { style in
            style.receipt.flatMap { ShellGitHubStyleSource.Repository(source: $0.source) }
        }).filter {
            $0.id.caseInsensitiveCompare(ShellGitHubStyleSource.officialRepositoryName) != .orderedSame
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    var sourceName: String {
        Self.sourceName(source.source)
    }

    func installedSource(of name: String) -> String {
        configuration.style(name).receipt.map { Self.sourceName($0.source) } ?? String(localized: "Local copy")
    }

    func confirmationMessage(for listing: ShellStyleListing) -> String {
        let status = status(of: listing)
        var lines: [String] = []
        if status == .otherCopy {
            lines.append(String(localized: "Replace \(installedSource(of: listing.name)) with \(sourceName)."))
        }
        if let repositoryName, status != .update {
            lines
                .append(
                    String(localized: "This style runs code in OmniWM. Install only if you trust \(repositoryName).")
                )
        }
        if status != .available {
            lines.append(String(localized: "Your current copy moves to the .backups folder in your shell folder."))
        }
        return lines.joined(separator: "\n\n")
    }

    private static func sourceName(_ source: String) -> String {
        if let repository = ShellGitHubStyleSource.Repository(source: source) { return repository.id }
        if source.hasPrefix("checkout:") {
            let path = String(source.dropFirst("checkout:".count))
            return String(localized: "Checkout at \(path)")
        }
        return source
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
        if let repository = ShellGitHubStyleSource.Repository(source: source.source) {
            guard repository == ShellGitHubStyleSource.Repository(source: receipt.source) else { return .otherCopy }
        } else if receipt.source != source.source {
            return .otherCopy
        }
        guard let installed = ReleaseVersion(receipt.version), let offered = ReleaseVersion(listing.manifest.version),
              offered > installed
        else { return .installed }
        return .update
    }

    func isActive(_ name: String) -> Bool {
        configuration.config.profile == name
    }

    func requestInstall(_ listing: ShellStyleListing) async {
        if repositoryName != nil {
            confirming = listing
        } else {
            await install(listing, replacing: false)
        }
    }

    func install(_ listing: ShellStyleListing, replacing: Bool) async {
        let source = source
        await perform(listing.name) { [configuration] in
            let payload = try await Task.detached { try await source.payload(for: listing) }.value
            return try await configuration.installStyle(payload, replacing: replacing)
        }
    }

    func update(_ listing: ShellStyleListing) async {
        guard status(of: listing) == .update, let receipt = configuration.style(listing.name).receipt else { return }
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
    @State private var browser: ShellStyleGitHubBrowser

    init(gallery: ShellStyleGallery) {
        self.gallery = gallery
        _browser = State(initialValue: ShellStyleGitHubBrowser(editor: gallery.editor))
    }

    private var current: ShellStyleGallery {
        browser.gallery ?? gallery
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if selected != nil || browser.gallery != nil || browser.adding {
                    Button("Back", systemImage: "chevron.left") {
                        if selected != nil { selected = nil } else { browser.back() }
                    }
                }
                Text(selected?.manifest.title ?? String(localized: "Get Styles")).font(.title2.weight(.semibold))
                Spacer()
                if selected == nil, browser.gallery == nil, !browser.adding {
                    Button("Add from GitHub…") { browser.adding = true }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let repositoryName = current.repositoryName {
                Text(verbatim: repositoryName).font(.callout).foregroundStyle(.secondary)
            }
            if let problem = current.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if let notice = current.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            } else if selected == nil, !browser.adding {
                Text("Styles change how the bar, island and drawers look.").font(.callout).foregroundStyle(.secondary)
            }
            if browser.adding {
                ShellStyleGitHubForm(browser: browser)
            } else if let selected {
                ShellStyleDetail(gallery: current, listing: selected)
            } else {
                ScrollView {
                    if browser.gallery == nil {
                        addedRepositories
                    }
                    ForEach(current.listingProblems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(current.listings) { listing in
                            ShellStyleCard(gallery: current, listing: listing).onTapGesture { selected = listing }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 700, height: 520)
        .task { await gallery.load() }
        .onDisappear { browser.back() }
        .confirmationDialog(
            confirmation(current.confirming),
            isPresented: Binding(get: { current.confirming != nil }, set: { if !$0 { current.confirming = nil } }),
            presenting: current.confirming
        ) { listing in
            let status = current.status(of: listing)
            Button(status == .available ? "Install" : status == .update ? "Back Up and Update" : "Replace") {
                let target = current
                Task { await target.install(listing, replacing: status != .available) }
            }
        } message: { listing in
            Text(current.confirmationMessage(for: listing))
        }
    }

    @ViewBuilder
    private var addedRepositories: some View {
        let repositories = gallery.addedRepositories
        if !repositories.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Added from GitHub").font(.headline)
                ForEach(repositories) { repository in
                    Button {
                        Task { await browser.open(repository) }
                    } label: {
                        Text(verbatim: repository.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        }
    }

    private func confirmation(_ listing: ShellStyleListing?) -> String {
        guard let listing else { return "" }
        if current.status(of: listing) == .available {
            return String(localized: "Install \(listing.manifest.title)?")
        }
        return current.status(of: listing) == .update
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
            if gallery.status(of: listing) != .otherCopy, gallery.isActive(listing.name) {
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
                    Button("Install") { Task { await gallery.requestInstall(listing) } }
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
