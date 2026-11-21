// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import GhosttyKit

extension GhosttySurfaceView {
    static func makeLaunchSurface(
        app: ghostty_app_t,
        config: inout ghostty_surface_config_s,
        launch: LauncherLaunchRequest
    ) -> ghostty_surface_t? {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        var variables: [ghostty_env_var_s] = []
        for (key, value) in launch.terminalEnvironment {
            guard let keyPointer = strdup(key) else { return nil }
            strings.append(keyPointer)
            guard let valuePointer = strdup(value) else { return nil }
            strings.append(valuePointer)
            variables.append(ghostty_env_var_s(key: UnsafePointer(keyPointer), value: UnsafePointer(valuePointer)))
        }
        let transfer: LauncherEnvironmentTransfer
        do {
            transfer = try LauncherEnvironmentTransfer(
                request: launch, isolateEnvironment: false, holdOutput: false
            )
        } catch {
            Log.terminal.error("Failed to prepare the terminal command: \(error.localizedDescription)")
            return nil
        }
        let surface = transfer.command.withCString { command in
            launch.directory.withCString { directory in
                variables.withUnsafeMutableBufferPointer { variables in
                    config.command = command
                    config.working_directory = directory
                    config.env_vars = variables.baseAddress
                    config.env_var_count = variables.count
                    config.wait_after_command = true
                    return ghostty_surface_new(app, &config)
                }
            }
        }
        if surface == nil { transfer.cancel() }
        return surface
    }
}
