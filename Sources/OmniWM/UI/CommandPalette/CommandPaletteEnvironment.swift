// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

private final class CommandPaletteActionBox: @unchecked Sendable {
    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }
}

private enum CommandPalettePasteKeyCode {
    static func current() -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }
        return withExtendedLifetime(source) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { return nil }
            return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                for keyCode in UInt16(0) ..< 128 {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = characters.withUnsafeMutableBufferPointer { buffer in
                        guard let baseAddress = buffer.baseAddress else { return OSStatus(paramErr) }
                        return UCKeyTranslate(
                            layout,
                            keyCode,
                            UInt16(kUCKeyActionDown),
                            UInt32(cmdKey >> 8),
                            UInt32(LMGetKbdType()),
                            OptionBits(kUCKeyTranslateNoDeadKeysBit),
                            &deadKeyState,
                            buffer.count,
                            &length,
                            baseAddress
                        )
                    }
                    if status == noErr,
                       String(decoding: characters.prefix(Int(length)), as: UTF16.self).lowercased() == "v"
                    {
                        return keyCode
                    }
                }
                return nil
            }
        }
    }
}

@MainActor
struct CommandPaletteEnvironment {
    var frontmostApplication: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    var runningApplication: (pid_t) -> NSRunningApplication? = { NSRunningApplication(processIdentifier: $0) }
    var ownBundleIdentifier: () -> String? = { Bundle.main.bundleIdentifier }
    var ownProcessIdentifier: () -> pid_t = { NSRunningApplication.current.processIdentifier }
    var fetchMenuItems: (pid_t) -> [MenuItemModel] = { MenuAnywhereFetcher().fetchMenuItemsSync(for: $0) }
    var applicationActivationNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    var performCommand: (WMController, HotkeyCommand) -> ExternalCommandResult = { controller, command in
        controller.commandHandler.performCommand(command)
    }

    var presentCommandFailure: (String) -> Void = { message in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Command Palette")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    var restoreCommandFocus: ((CommandPaletteFocusTarget) -> Bool)?
    var navigateToWindow: (WMController, WindowHandle) -> Void = { controller, handle in
        controller.navigateToCommandPaletteWindow(handle)
    }

    var summonWindowRight: (WMController, WindowHandle, WindowToken, WorkspaceDescriptor.ID) -> Void = {
        controller,
        handle,
        anchorToken,
        anchorWorkspaceId in
        controller.summonCommandPaletteWindowRight(
            handle,
            anchorToken: anchorToken,
            anchorWorkspaceId: anchorWorkspaceId
        )
    }

    var scheduleMenuAction: (@escaping () -> Void) -> Void = { action in
        let box = CommandPaletteActionBox(action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            box.action()
        }
    }

    var performMenuAction: (AXUIElement) -> Void = { element in
        performAXAction(element, kAXPressAction as CFString, noteKey: "performPressFailed")
    }

    var clipboardItems: (WMController) -> [ClipboardPaletteItem] = { controller in
        controller.clipboardPaletteItems()
    }

    var isClipboardHistoryEnabled: (WMController) -> Bool = { controller in
        controller.settings.clipboard.historyEnabled
    }

    var setClipboardHistoryEnabled: (WMController, Bool) -> Void = { controller, isEnabled in
        controller.setClipboardHistoryEnabled(isEnabled)
    }

    var copyClipboardItem: (WMController, UUID) async -> Bool = { controller, id in
        await controller.copyClipboardItem(id: id)
    }

    var copyClipboardItemPlainText: (WMController, UUID) async -> Bool = { controller, id in
        await controller.copyClipboardItem(id: id, plainText: true)
    }

    var clipboardItemPreview: (WMController, UUID) async -> ClipboardPalettePreview? = { controller, id in
        await controller.clipboardItemPreview(id: id)
    }

    var setClipboardItemPinned: (WMController, UUID, Bool) async -> [ClipboardPaletteItem] = {
        controller,
        id,
        pinned in
        await controller.setClipboardItemPinned(pinned, id: id)
    }

    var observeClipboardItems: (WMController, (@MainActor @Sendable ([ClipboardPaletteItem]) -> Void)?) -> Void = {
        controller,
        observer in
        controller.clipboardHistoryService.onPaletteItemsChanged = observer
    }

    var deleteClipboardItem: (WMController, UUID) async -> [ClipboardPaletteItem] = { controller, id in
        await controller.deleteClipboardItem(id: id)
    }

    var clearClipboardHistory: (WMController) async throws -> [ClipboardPaletteItem] = { controller in
        try await controller.clearClipboardHistory()
    }

    var confirmClearClipboardHistory: () -> Bool = {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Clear Clipboard History?")
        alert
            .informativeText =
            String(
                localized: "This removes unpinned clipboard history. Pinned items and the current system clipboard are unchanged."
            )
        alert.addButton(withTitle: String(localized: "Clear"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    var postPasteShortcut: () -> Bool = {
        guard let keyCode = CommandPalettePasteKeyCode.current() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }

    var isSecureInputActive: () -> Bool = {
        IsSecureEventInputEnabled()
    }

    var isAccessibilityTrusted: () -> Bool = {
        AXIsProcessTrusted()
    }

    var isOwnWindowKey: () -> Bool = {
        NSApp.keyWindow != nil
    }

    var focusedInputProcessIdentifier: () -> pid_t? = {
        let system = AXUIElementCreateSystemWide()
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(unsafeDowncast(value, to: AXUIElement.self), &pid) == .success else {
            return nil
        }
        return pid
    }

    var isLockScreenActive: (WMController) -> Bool = { controller in
        controller.isLockScreenActive
    }

    var focusedWindowID: (pid_t) -> CGWindowID? = { pid in
        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
            let windowValue,
            CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return getWindowId(from: unsafeDowncast(windowValue, to: AXUIElement.self))
    }
}
