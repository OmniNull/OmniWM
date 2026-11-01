// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Observation
import SwiftUI

@MainActor
@Observable
final class ShellStyleGitHubBrowser {
    let editor: ShellDesktopEditor
    var address = ""
    var adding = false
    private(set) var loading = false
    private(set) var problem: String?
    private(set) var gallery: ShellStyleGallery?
    private var request: UUID?
    private var task: Task<ShellGitHubStyleSource.Browse, Error>?

    init(editor: ShellDesktopEditor) {
        self.editor = editor
    }

    func open(_ repository: ShellGitHubStyleSource.Repository, session: URLSession = .shared) async {
        address = repository.url.absoluteString
        adding = true
        await load(session: session)
    }

    func load(session: URLSession = .shared) async {
        task?.cancel()
        let request = UUID()
        self.request = request
        let address = address
        let task = Task { try await ShellGitHubStyleSource.browse(address, session: session) }
        self.task = task
        loading = true
        problem = nil
        defer {
            if self.request == request {
                self.task = nil
                loading = false
            }
        }
        do {
            let browse = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard self.request == request, !Task.isCancelled else { return }
            gallery = ShellStyleGallery(editor: editor, browse: browse)
            adding = false
        } catch {
            guard self.request == request, !Task.isCancelled else { return }
            problem = error.localizedDescription
        }
    }

    func back() {
        request = nil
        task?.cancel()
        task = nil
        loading = false
        gallery = nil
        problem = nil
        adding = false
    }
}

struct ShellStyleGitHubForm: View {
    @Bindable var browser: ShellStyleGitHubBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Public GitHub repository").font(.headline)
            Text("Paste the repository’s main page, such as https://github.com/owner/repository.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("https://github.com/owner/repository", text: $browser.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { load() }
                Button("Load") { load() }
                    .disabled(browser.loading || browser.address.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty)
                if browser.loading { ProgressView().controlSize(.small) }
            }
            if let problem = browser.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private func load() {
        guard !browser.loading else { return }
        Task { await browser.load() }
    }
}
