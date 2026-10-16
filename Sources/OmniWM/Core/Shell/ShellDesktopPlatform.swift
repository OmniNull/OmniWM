// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellDesktopSource {
    typealias FocusEnd = @MainActor @Sendable (Bool) -> Void
    weak var window: NSWindow?
    let isCurrent: @MainActor () -> Bool
    let beginFocus: @MainActor (NSWindow?) throws -> FocusEnd

    init(
        window: NSWindow?,
        isCurrent: @escaping @MainActor () -> Bool,
        beginFocus: @escaping @MainActor (NSWindow?) throws -> FocusEnd
    ) {
        self.window = window
        self.isCurrent = isCurrent
        self.beginFocus = beginFocus
    }
}

@MainActor
struct ShellDesktopPlatform {
    struct Presentation {
        let start: @MainActor () throws -> Void
        let cancel: CancelPresentation
    }

    typealias CancelPresentation = @MainActor () -> Void
    typealias PickCompletion = @MainActor @Sendable (Result<[URL], ShellResourceFailure>) -> Void
    let pick: @MainActor (Bool, ShellDesktopSource, @escaping PickCompletion) throws -> CancelPresentation
    let open: @MainActor (URL, @escaping @Sendable (String?) -> Void) -> Void
    let reveal: @MainActor (URL) -> Bool
    var clipboardCopy: @MainActor (ShellClipboardContent) -> Bool = { _ in false }
    var clipboardRead: @MainActor () throws -> [ShellDropItem] = { throw ShellResourceFailure("clipboard_unavailable") }
    var quicklook: @MainActor ([URL], Int, ShellDesktopSource, @escaping PresentationCompletion) throws
        -> Presentation = { _, _, _, _ in
            throw ShellResourceFailure("preview_unavailable")
        }

    var share: @MainActor (
        [ShellResourceStore.Value],
        String?,
        ShellDesktopSource,
        ShellDesktopAnchor,
        @escaping PresentationCompletion
    ) throws -> Presentation = { _, _, _, _, _ in
        throw ShellResourceFailure("share_unavailable")
    }

    typealias PresentationCompletion = @MainActor @Sendable (String?) -> Void

    static var appKit: Self {
        Self(pick: { multiple, source, completion in
            guard source.isCurrent(), let parent = source.window, parent.isVisible, parent.attachedSheet == nil else {
                throw ShellResourceFailure("source_surface_unavailable")
            }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = multiple
            panel.resolvesAliases = true
            panel.isReleasedWhenClosed = false
            let endFocus = try source.beginFocus(panel)
            let receive: @Sendable (NSApplication.ModalResponse) -> Void = { response in
                Task { @MainActor in
                    let result: Result<[URL], ShellResourceFailure>
                    switch response {
                    case .OK: result = .success(panel.urls)
                    case .cancel: result = .failure(ShellResourceFailure("cancelled"))
                    default: result = .failure(ShellResourceFailure("picker_unavailable"))
                    }
                    panel.orderOut(nil)
                    endFocus(true)
                    completion(result)
                }
            }
            panel.beginSheetModal(for: parent, completionHandler: receive)
            return { panel.cancel(nil) }
        }, open: { url, completion in
            let receive: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { application, error in
                completion(error
                    .map { String($0.localizedDescription.prefix(1024)) } ?? (application == nil ? "open_failed" : nil))
            }
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: receive)
        }, reveal: { url in
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        }, clipboardCopy: { ShellClipboard.copy($0) }, clipboardRead: { try ShellClipboard.read()
        }, quicklook: { urls, index, source, completion in
            let session = ShellQuickLookSession(urls: urls, index: index, source: source, completion: completion)
            return Presentation(start: { try session.present() }, cancel: { session.cancel() })
        }, share: { values, service, source, anchor, completion in
            let session = ShellSharingSession(
                values: values,
                service: service,
                source: source,
                anchor: anchor,
                completion: completion
            )
            return Presentation(start: { try session.present() }, cancel: { session.cancel() })
        })
    }
}
