// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellWidgetHost {
    func syncComponents() {
        guard let root = config.island?.root, let state = widgets[root], state.package != nil else { return }
        do {
            let source = try widgetSource(of: state)
            applyComponentSource(source, fingerprint: fingerprint(of: state.sourceURL), to: state)
        } catch let failure as ShellScriptFailure {
            report(state, failure)
        } catch {
            report(state, ShellScriptFailure(kind: .compile, message: error.localizedDescription))
        }
    }

    func applyComponentSource(
        _ source: ShellWidgetSource, fingerprint: [String: SettingsFileAccess.Fingerprint], to state: WidgetState
    ) {
        state.assetPackages = source.assetPackages
        state.componentDescriptors = source.componentDescriptors
        state.fingerprint = fingerprint
        for instance in state.instances.values { instance.surface?.assetFolders = source.assetPackages }
        if popout?.widget == state.name { popout?.surface.assetFolders = source.assetPackages }
        for section in drawer?.sections ?? [] where section.widget == state.name {
            section.surface.assetFolders = source.assetPackages
        }
        state.mailbox?.yield(.components(source))
    }

    func refreshAssets(at url: URL) {
        for state in widgets.values {
            for instance in state.instances.values {
                instance.surface?.refreshAssets(at: url)
            }
        }
        popout?.surface.refreshAssets(at: url)
        closingPopout?.surface.refreshAssets(at: url)
        for section in drawer?.sections ?? [] { section.surface.refreshAssets(at: url) }
        for section in closingDrawer?.sections ?? [] { section.surface.refreshAssets(at: url) }
    }
}
