// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ActionCatalog {
    static var shellAppExampleTitle: LocalizedStringResource {
        LocalizedStringResource(
            "command.shell.appOpenExample", defaultValue: "Open OmniShell Example", table: "Commands", bundle: .omniWM
        )
    }

    static var shellAppNewWindowExampleTitle: LocalizedStringResource {
        LocalizedStringResource(
            "command.shell.appNewWindowExample", defaultValue: "New OmniShell Example Window", table: "Commands",
            bundle: .omniWM
        )
    }

    static let shellTogglePrefix = "toggleShellWidget."
    static let shellAppOpenPrefix = "openShellApp."
    static let shellAppNewWindowPrefix = "newShellAppWindow."
    static let shellAppExampleActionID = "openShellApp.example"
    static let shellAppNewWindowExampleActionID = "newShellAppWindow.example"

    static func shellAppSpec(for id: String) -> ActionSpec? {
        if id.hasPrefix(shellAppOpenPrefix) {
            return shellAppSpec(appID: String(id.dropFirst(shellAppOpenPrefix.count)))
        }
        guard id.hasPrefix(shellAppNewWindowPrefix) else { return nil }
        return shellAppSpec(appID: String(id.dropFirst(shellAppNewWindowPrefix.count)), newWindow: true)
    }

    static func shellAppSpec(appID: String, title: String? = nil, newWindow: Bool = false) -> ActionSpec? {
        guard ShellComponentCatalog.validName(appID) else { return nil }
        if appID == ShellAppWindowManager.exampleID, title == nil {
            return allSpecs()
                .first { $0.id == (newWindow ? shellAppNewWindowExampleActionID : shellAppExampleActionID) }
        }
        let name = title ?? appID
        let resource = newWindow
            ? LocalizedStringResource(
                "command.shell.appNewWindow",
                defaultValue: "New \(name) Window",
                table: "Commands",
                bundle: .omniWM
            )
            : LocalizedStringResource(
                "command.shell.appOpen",
                defaultValue: "Open \(name)",
                table: "Commands",
                bundle: .omniWM
            )
        return action(
            id: (newWindow ? shellAppNewWindowPrefix : shellAppOpenPrefix) + appID,
            command: newWindow ? .shellAppNewWindow(appID) : .shellAppOpen(appID),
            category: .focus, binding: .unassigned, keywords: ["shell", "app", "window", appID, name], title: resource
        )
    }

    static func appendShellAppBindings(_ specs: inout [ActionSpec]) {
        specs.append(action(
            id: shellAppExampleActionID,
            command: .shellAppOpen(ShellAppWindowManager.exampleID),
            category: .focus,
            binding: .unassigned,
            keywords: ["shell", "app", "window", "example"]
        ))
        specs.append(action(
            id: shellAppNewWindowExampleActionID,
            command: .shellAppNewWindow(ShellAppWindowManager.exampleID),
            category: .focus,
            binding: .unassigned,
            keywords: ["shell", "app", "new", "window", "example"]
        ))
    }

    static func shellToggleSpec(for id: String) -> ActionSpec? {
        guard id.hasPrefix(shellTogglePrefix) else { return nil }
        return shellToggleSpec(name: String(id.dropFirst(shellTogglePrefix.count)))
    }

    static func shellToggleSpec(name: String) -> ActionSpec? {
        guard !name.isEmpty, !name.contains(where: \.isWhitespace) else { return nil }
        return action(
            id: shellTogglePrefix + name,
            command: .shellToggle(name),
            category: .focus,
            binding: .unassigned,
            keywords: ["shell", "widget", "drawer", name]
        )
    }
}
