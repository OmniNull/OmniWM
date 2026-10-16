// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellDesktopServices {
    func dispatch(
        _ operation: Operation,
        source: ShellDesktopSource?,
        anchor: ShellDesktopAnchor?,
        resolveAnchor: (@MainActor () async throws -> ShellDesktopAnchor)?
    ) {
        let request = operation.request
        switch request.action {
        case let .pick(multiple):
            pick(operation, multiple: multiple, source: source)
        case let .openURL(url):
            if let error = Self.urlError(url) { finish(operation, result: ShellDesktopResult(error: error)) }
            else { open(url, operation: operation) }
        case let .clipboardText(text):
            let copied = text.utf8.count <= 1 << 20 && platform.clipboardCopy(.text(text))
            finish(operation, result: ShellDesktopResult(error: copied ? nil : "clipboard_copy_failed"))
        case let .clipboardCopy(resource):
            copyClipboard(resource, operation: operation)
        case .clipboardRead:
            do { readClipboard(try platform.clipboardRead(), operation: operation) }
            catch { finish(operation, result: ShellDesktopResult(error: String(describing: error))) }
        case let .quicklook(ids, index):
            quicklook(operation, ids: ids, index: index, source: source)
        case let .share(ids, service):
            guard !ids.isEmpty, ids.count <= 32, service == nil || service == "airdrop" else {
                finish(operation, result: ShellDesktopResult(error: "unsupported_service"))
                return
            }
            present(operation, ids: ids, source: source, anchor: anchor, resolveAnchor: resolveAnchor)
        case let .open(resource),
             let .reveal(resource):
            openResource(resource, operation: operation)
        }
    }

    private func quicklook(
        _ operation: Operation,
        ids: [ShellResourceID],
        index: Int,
        source: ShellDesktopSource?
    ) {
        let request = operation.request
        guard preview == nil else {
            finish(operation, result: ShellDesktopResult(error: "quicklook_busy"))
            return
        }
        guard !ids.isEmpty, ids.count <= 32, index > 0, index <= ids.count else {
            finish(operation, result: ShellDesktopResult(error: "invalid_preview"))
            return
        }
        preview = request.id
        present(operation, ids: ids, source: source, anchor: nil, resolveAnchor: nil)
    }

    private func pick(_ operation: Operation, multiple: Bool, source: ShellDesktopSource?) {
        let request = operation.request
        let fence = operation.fence
        guard picker == nil else {
            finish(operation, result: ShellDesktopResult(error: "picker_busy"))
            return
        }
        guard let source, source.isCurrent() else {
            finish(operation, result: ShellDesktopResult(error: "source_surface_unavailable"))
            return
        }
        picker = request.id
        do {
            let cancel = try platform.pick(multiple, source) { [self] result in
                picked(operation, result: result)
            }
            if picker == request.id {
                operation.cancelPresentation = cancel
                if !fence.isActive { cancel() }
            }
        } catch {
            picker = nil
            finish(operation, result: ShellDesktopResult(error: String(describing: error)))
        }
    }

    private func copyClipboard(_ resource: ShellResourceID, operation: Operation) {
        let request = operation.request
        let fence = operation.fence
        Task { [self] in
            do {
                let content = try await resources.clipboardContent(
                    resource,
                    owner: request.id.owner,
                    operation: fence
                )
                guard current(operation) else { throw ShellResourceFailure("cancelled") }
                finish(
                    operation,
                    result: ShellDesktopResult(error: platform
                        .clipboardCopy(content) ? nil : "clipboard_copy_failed")
                )
            } catch { finish(operation, result: ShellDesktopResult(error: String(describing: error))) }
        }
    }

    private func openResource(_ resource: ShellResourceID, operation: Operation) {
        let request = operation.request
        Task { [self] in
            do {
                operation.pin = try await resources.retain([resource], owner: request.id.owner)
                guard current(operation), let value = operation.pin?.values.first else {
                    finish(operation, result: ShellDesktopResult(error: "cancelled"))
                    return
                }
                switch (request.action, value) {
                case let (.reveal, .file(url)):
                    finish(
                        operation,
                        result: ShellDesktopResult(error: platform.reveal(url) ? nil : "reveal_failed")
                    )
                case let (.open, .file(url)):
                    open(url, operation: operation)
                case let (.open, .url(url)):
                    if let error = Self
                        .urlError(url) { finish(operation, result: ShellDesktopResult(error: error)) }
                    else { open(url, operation: operation) }
                default:
                    finish(operation, result: ShellDesktopResult(error: "unsupported_resource"))
                }
            } catch {
                finish(operation, result: ShellDesktopResult(error: String(describing: error)))
            }
        }
    }
}
