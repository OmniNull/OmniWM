// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import GhosttyKit

@MainActor
final class QuakeClipboardPromptCoordinator {
    private final class ActivePrompt {
        private(set) weak var origin: AnyObject?
        let isOriginAttached: @MainActor () -> Bool
        let dismiss: @MainActor () -> Void
        let resolve: @MainActor (Bool) -> Void

        init(
            origin: AnyObject,
            isOriginAttached: @escaping @MainActor () -> Bool,
            dismiss: @escaping @MainActor () -> Void,
            resolve: @escaping @MainActor (Bool) -> Void
        ) {
            self.origin = origin
            self.isOriginAttached = isOriginAttached
            self.dismiss = dismiss
            self.resolve = resolve
        }
    }

    private var activePrompt: ActivePrompt?
    private weak var controller: QuakeTerminalController?

    func attach(to controller: QuakeTerminalController) {
        precondition(self.controller == nil)
        self.controller = controller
    }

    var hasActivePrompt: Bool {
        activePrompt != nil
    }

    func request(
        origin: AnyObject,
        isOriginAttached: @escaping @MainActor () -> Bool,
        present: (@escaping @MainActor (Bool) -> Void) -> Void,
        dismiss: @escaping @MainActor () -> Void,
        resolve: @escaping @MainActor (Bool) -> Void
    ) {
        guard activePrompt == nil, isOriginAttached() else {
            resolve(false)
            return
        }

        let prompt = ActivePrompt(
            origin: origin,
            isOriginAttached: isOriginAttached,
            dismiss: dismiss,
            resolve: resolve
        )
        activePrompt = prompt
        present { [weak self] allowed in
            self?.finish(prompt, allowed: allowed)
        }
    }

    func cancelPrompt(for origin: AnyObject) {
        guard let activePrompt, activePrompt.origin === origin else { return }
        cancelActivePrompt()
    }

    func cancelActivePrompt() {
        guard let prompt = activePrompt else { return }
        activePrompt = nil
        prompt.dismiss()
        prompt.resolve(false)
    }

    private func finish(_ prompt: ActivePrompt, allowed: Bool) {
        guard activePrompt === prompt else { return }
        activePrompt = nil
        prompt.resolve(allowed && prompt.isOriginAttached())
    }

    func readClipboard(
        for view: GhosttySurfaceView,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer,
        mimes: UnsafeBufferPointer<UnsafePointer<CChar>>?,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let surface = view.ghosttySurface,
              let pasteboard = NSPasteboard.ghostty(location)
        else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        guard let payload = pasteboard.ghosttyReadPayload(forMIMEs: mimes, list: list) else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        payload.complete(on: surface, state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    func promptForProtectedClipboardRead(
        on view: GhosttySurfaceView,
        payload: GhosttyClipboardPayload,
        state: UnsafeMutableRawPointer,
        kind: QuakeClipboardAlert.Kind
    ) {
        let request = GhosttyProtectedClipboardRequest(payload: payload, state: state)
        view.registerProtectedClipboardRequest(request)
        presentClipboardPrompt(
            for: view,
            kind: kind,
            contents: payload.preview,
            programName: payload.programName,
            canRemember: payload.canRemember,
            previewImage: payload.previewImage
        ) { [weak view] allowed, remember in
            view?.resolveProtectedClipboardRequest(request, allowing: allowed, remember: remember)
        }
    }

    func writeClipboard(location: ghostty_clipboard_e, contents: [GhosttyClipboardContent]) {
        NSPasteboard.ghostty(location)?.replaceGhosttyContents(contents)
    }

    func promptForProtectedClipboardWrite(
        on view: GhosttySurfaceView,
        location: ghostty_clipboard_e,
        contents: [GhosttyClipboardContent]
    ) {
        guard let text = GhosttyClipboardContent.firstPlainText(in: contents) else { return }
        presentClipboardPrompt(
            for: view,
            kind: .write,
            contents: text
        ) { [weak self] allowed, _ in
            guard allowed else { return }
            self?.writeClipboard(location: location, text: text)
        }
    }

    private func writeClipboard(location: ghostty_clipboard_e, text: String) {
        guard let pasteboard = NSPasteboard.ghostty(location) else { return }
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }

    private func presentClipboardPrompt(
        for view: GhosttySurfaceView,
        kind: QuakeClipboardAlert.Kind,
        contents: String,
        programName: String? = nil,
        canRemember: Bool = false,
        previewImage: NSImage? = nil,
        resolve: @escaping @MainActor (Bool, Bool) -> Void
    ) {
        let alert = QuakeClipboardAlert.make(
            kind: kind,
            contents: contents,
            programName: programName,
            canRemember: canRemember,
            previewImage: previewImage
        )
        let rememberButton = alert.accessoryView as? NSButton
        request(
            origin: view,
            isOriginAttached: { [weak self, weak view] in
                guard let self, let view else { return false }
                return self.canPromptForClipboard(from: view)
            },
            present: { [weak self] completion in
                guard let self, let window = self.controller?.window else {
                    completion(false)
                    return
                }
                alert.beginSheetModal(for: window) { response in
                    MainActor.assumeIsolated {
                        completion(QuakeClipboardAlert.responseAllows(response))
                    }
                }
            },
            dismiss: {
                guard let sheetParent = alert.window.sheetParent else { return }
                sheetParent.endSheet(alert.window, returnCode: .cancel)
            },
            resolve: { allowed in
                resolve(allowed, allowed && rememberButton?.state == .on)
            }
        )
    }

    private func canPromptForClipboard(from view: GhosttySurfaceView) -> Bool {
        guard let controller, let window = controller.window, controller.visible, window.isVisible else { return false }
        return view.ghosttySurface != nil && view.window === window && controller.isActiveSurface(view)
    }

    static var readCallback: ghostty_runtime_read_clipboard_cb {
        { userdata, location, state, mimes, mimesLength, list in
            guard let userdata else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
            return MainActor.assumeIsolated {
                let context = Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                guard let controller = context.controller, let view = context.view else {
                    return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
                }
                return controller.clipboardPrompts.readClipboard(
                    for: view,
                    location: location,
                    state: state,
                    mimes: UnsafeBufferPointer(start: mimes, count: mimesLength),
                    list: list
                )
            }
        }
    }

    static var confirmationCallback: ghostty_runtime_confirm_read_clipboard_cb {
        { userdata, confirmation, state, kind in
            guard let userdata else { return }
            MainActor.assumeIsolated {
                let context = Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                guard let view = context.view, let surface = view.ghosttySurface else { return }
                guard let controller = context.controller,
                      let promptKind = QuakeClipboardAlert.Kind(kind)
                else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                    return
                }
                controller.clipboardPrompts.promptForProtectedClipboardRead(
                    on: view,
                    payload: GhosttyClipboardPayload(confirmation.pointee),
                    state: state,
                    kind: promptKind
                )
            }
        }
    }

    static var writeCallback: ghostty_runtime_write_clipboard_cb {
        { userdata, location, content, len, confirm in
            guard let userdata, len > 0 else { return }
            let contents = (0 ..< len).map { GhosttyClipboardContent(content[$0]) }
            guard !contents.isEmpty else { return }
            MainActor.assumeIsolated {
                let context = Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
                guard let controller = context.controller, let view = context.view else { return }
                if confirm {
                    controller.clipboardPrompts.promptForProtectedClipboardWrite(
                        on: view,
                        location: location,
                        contents: contents
                    )
                } else {
                    controller.clipboardPrompts.writeClipboard(location: location, contents: contents)
                }
            }
        }
    }
}
