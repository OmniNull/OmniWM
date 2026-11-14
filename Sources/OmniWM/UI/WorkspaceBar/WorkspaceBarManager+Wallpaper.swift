// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceBarManager {
    func attachWallpaper(to host: ShellWidgetHost) {
        host.onWallpaperCommand = { [weak self] command in
            self?.performWallpaperCommand(command)
        }
        host.setWallpaperManager(controller?.wallpaperManager)
    }

    func offerWallpaper(_ manager: WallpaperManager?) {
        shellHost?.setWallpaperManager(manager)
    }

    func performWallpaperCommand(_ command: ShellWallpaperCommand) {
        guard let controller else { return }
        switch command {
        case let .scheme(scheme):
            selectWallpaperScheme(scheme) { [weak controller] problem in
                guard let problem, let manager = controller?.wallpaperManager else { return }
                manager.report(problem)
                manager.onChange?()
            }
        case .settings:
            controller.statusBarController?.openSettings(section: .wallpaper)
        default:
            controller.wallpaperManager?.perform(command, chooseFolder: WallpaperManager.chooseFolder(startingAt:))
        }
    }

    var wallpaperPaletteState: WallpaperPaletteState {
        let config = shellHost?.config ?? shellConfiguration.config
        return WallpaperPaletteState(
            active: config.themeName == ShellWallpaperPalette.themeName,
            scheme: config.wallpaperScheme
        )
    }

    @discardableResult
    func selectWallpaperScheme(
        _ scheme: ShellWallpaperScheme,
        completion: @escaping @MainActor (String?) -> Void = { _ in }
    ) -> Task<Void, Never> {
        paletteRequests &+= 1
        let request = paletteRequests
        let manager = controller?.wallpaperManager
        let pixels = manager?.palettePixels() ?? manager?.mainPixels()
        let destination = shellDirectory?.appendingPathComponent("themes/\(ShellWallpaperPalette.themeName).toml")
        let writer = shellHost?.wallpaperPalette
        return Task { @MainActor [weak self] in
            if let pixels, let destination {
                do {
                    if let writer {
                        _ = try await writer.publish(pixels, scheme: scheme)
                    } else {
                        _ = try await ShellWallpaperPaletteWriter.publish(pixels, scheme: scheme, to: destination)
                    }
                } catch {
                    guard self?.paletteRequests == request else { return }
                    completion(
                        String(localized: "The wallpaper colors can’t be written: \(error.localizedDescription)")
                    )
                    return
                }
            }
            await self?.useShellTheme(
                ShellWallpaperPalette.themeName, scheme: scheme, request: request, completion: completion
            )
        }
    }

    @discardableResult
    func useStylePalette(completion: @escaping @MainActor (String?) -> Void = { _ in }) -> Task<Void, Never> {
        paletteRequests &+= 1
        let request = paletteRequests
        let style = (shellHost?.config ?? shellConfiguration.config).styleThemeName
        let theme = style == ShellWallpaperPalette.themeName ? "native" : style
        return Task { @MainActor [weak self] in
            await self?.useShellTheme(theme, scheme: nil, request: request, completion: completion)
        }
    }

    private func useShellTheme(
        _ name: String, scheme: ShellWallpaperScheme?, request: UInt64, completion: @MainActor (String?) -> Void
    ) async {
        guard request == paletteRequests else { return }
        let result = await applyShellFileRequest(.theme(name: name, scheme: scheme?.rawValue))
        guard request == paletteRequests else { return }
        switch result {
        case .executed,
             .noChange:
            shellHost?.wallpaperPaletteDidChange()
            completion(nil)
        default:
            completion(String(localized: "OmniWM can’t change its colors. Check the Styles & Widgets folder."))
        }
    }

    func setShellPalette(_ palette: ShellTheme?) {
        guard shellPalette != palette else { return }
        shellPalette = palette
        guard let controller, controller.settings.borders.colorSource == .palette else { return }
        controller.cachedBorderConfig = nil
        controller.surfaceReconciler.noteBorderChanged()
    }
}
