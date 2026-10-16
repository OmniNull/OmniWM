// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC
import OmniWMScriptHost

extension ShellWidgetHost {
    func load(_ state: WidgetState) {
        guard let outbox else { return }
        let source: ShellWidgetSource
        do {
            source = try widgetSource(of: state)
        } catch let failure as ShellScriptFailure {
            report(state, failure)
            return
        } catch {
            report(state, ShellScriptFailure(kind: .compile, message: error.localizedDescription))
            return
        }
        Self.close(state.loadingPackage)
        let retiring = Array(Self.retiringTasks.values)
        nextGeneration += 1
        state.loadingGeneration = nextGeneration
        let package = ShellWidgetPackage(
            name: state.name, generation: nextGeneration, outbox: outbox, latestData: latestData,
            resourceStore: resourceStore, retireResourceImages: { [images = resources.resourceImages] owner in
                await images?.retire(owner)
            }
        )
        state.loadingPackage = package
        Task { [weak self] in
            for task in retiring { await task.value }
            guard let self, self.widgets[state.name] === state,
                  state.loadingGeneration == package.generation
            else {
                Self.close(package)
                return
            }
            await self.loadPackage(package, source: source, for: state)
        }
    }

    private func loadPackage(_ package: ShellWidgetPackage, source: ShellWidgetSource, for state: WidgetState) async {
        if state.package != nil {
            let failure = await package.validateReload(source)
            guard self.widgets[state.name] === state, state.loadingGeneration == package.generation else {
                Self.close(package)
                return
            }
            if let failure {
                self.finishLoad(
                    state: state,
                    package: package,
                    source: source,
                    failure: failure,
                    declaration: .init()
                )
                return
            }
            Self.retireTraceCapture(state.package)
            state.mailbox?.finish()
            state.mailbox = nil
            let previous = state.package
            state.package = nil
            self.publishToggleNames()
            Self.close(previous)
            await previous?.close()
            guard self.widgets[state.name] === state, state.loadingGeneration == package.generation else {
                Self.close(package)
                return
            }
        }
        let failure = await package.load(source)
        let declaration = await package.declaration
        self.finishLoad(state: state, package: package, source: source, failure: failure, declaration: declaration)
    }

    func sourceInput(of sourceURL: URL, name: String) -> ShellWidgetSourceLoader.Input {
        ShellWidgetSourceLoader.Input(
            name: name, shellDirectory: shellDirectory, sourceURL: sourceURL,
            directories: config.directories, profile: config.profile,
            components: sourceURL.deletingLastPathComponent().lastPathComponent == config.island?.root
                ? config.island?.components : nil
        )
    }

    func componentResolution(of sourceURL: URL) throws -> ShellComponentCatalog.Resolution? {
        guard sourceURL.deletingLastPathComponent().lastPathComponent == config.island?.root else { return nil }
        return try ShellComponentCatalog.resolve(config.island?.components ?? [], directories: config.directories)
    }

    func packageFiles(of sourceURL: URL) -> [(url: URL, path: String)] {
        ShellWidgetSourceLoader.packageFiles(
            sourceInput(of: sourceURL, name: sourceURL.deletingLastPathComponent().lastPathComponent),
            components: (try? componentResolution(of: sourceURL))?.descriptors ?? []
        )
    }

    func packageDirectories(of sourceURL: URL) -> [URL] {
        ShellWidgetSourceLoader.packageDirectories(
            sourceInput(of: sourceURL, name: sourceURL.deletingLastPathComponent().lastPathComponent),
            components: (try? componentResolution(of: sourceURL))?.descriptors ?? []
        )
    }

    func fingerprint(of sourceURL: URL) -> [String: SettingsFileAccess.Fingerprint] {
        ShellWidgetSourceLoader.fingerprint(
            sourceInput(of: sourceURL, name: sourceURL.deletingLastPathComponent().lastPathComponent),
            components: (try? componentResolution(of: sourceURL))?.descriptors ?? []
        )
    }

    func widgetSource(of state: WidgetState) throws -> ShellWidgetSource {
        try ShellWidgetSourceLoader.build(sourceInput(of: state.sourceURL, name: state.name))
    }

    func finishLoad(
        state: WidgetState,
        package: ShellWidgetPackage,
        source: ShellWidgetSource,
        failure: ShellScriptFailure?,
        declaration: ShellWidgetDeclaration
    ) {
        guard widgets[state.name] === state, package.generation == state.loadingGeneration else {
            Self.close(package)
            return
        }
        state.loadingPackage = nil
        guard source.isIslandRoot == (state.name == config.island?.root) else {
            Self.close(package)
            load(state)
            return
        }
        if let failure {
            Self.close(package)
            if state.package == nil, hasFallback(state) {
                trip(state, failure)
            } else {
                report(state, failure)
            }
            return
        }
        let latest: ShellWidgetSource
        do {
            latest = state.name == config.island?.root ? try widgetSource(of: state) : source
        } catch {
            Self.close(package)
            report(state, ShellScriptFailure(kind: .compile, message: error.localizedDescription))
            return
        }
        installPackage(package, source: source, latest: latest, declaration: declaration, for: state)
    }

    private func installPackage(
        _ package: ShellWidgetPackage,
        source: ShellWidgetSource,
        latest: ShellWidgetSource,
        declaration: ShellWidgetDeclaration,
        for state: WidgetState
    ) {
        let triggerChanged = state.declaration.hasTrigger != declaration.hasTrigger
        state.declaration = declaration
        state.assetPackages = latest.assetPackages
        state.componentDescriptors = latest.componentDescriptors
        for instance in state.instances.values {
            instance.surface?.assetFolders = latest.assetPackages
        }
        let cleared = clearFailure(state)
        if popout?.widget == state.name {
            closePopout()
        }
        if drawer?.sections.contains(where: { $0.widget == state.name }) == true {
            closeDrawer()
        }
        Self.retireTraceCapture(state.package)
        state.mailbox?.finish()
        cancelInput(for: state)
        state.package = package
        state.mailbox = Self.connect(package)
        state.generation = package.generation
        state.backgroundDemand = 0
        publishConfigurationCatalog(to: state)
        state.failures = 0
        if latest.components != source.components || latest.modules.map(\.path) != source.modules.map(\.path) {
            state.mailbox?.yield(.components(latest))
        }
        Log.shell.notice("Loaded widget \(state.name)")
        state.mailbox?.yield(.settings(config.widgetSettings[state.name] ?? []))
        state.mailbox?.yield(.interval(interval(of: state)))
        if place(state) || cleared {
            refreshSlots()
            onLayoutChange()
        }
        publishDemand()
        publishToggleNames(forceWidgetReport: triggerChanged)
    }

    func broadcast(_ data: ShellWidgetData) {
        let changed = latestData.publish(data)
        guard changed != 0 else { return }
        for state in widgets.values where changed & demand(of: state) != 0 {
            state.mailbox?.yield(.dataChanged)
        }
    }

    static func connect(_ package: ShellWidgetPackage) -> AsyncStream<ShellWidgetMessage>.Continuation {
        let (messages, mailbox) = AsyncStream.makeStream(of: ShellWidgetMessage.self)
        package.capture.attach(mailbox)
        joinTraceCapture(package)
        package.services.attachWake { mailbox.yield(.services) }
        package.providerInbox.attachWake { mailbox.yield(.providers) }
        package.resourceInbox.attachWake { mailbox.yield(.resources) }
        package.nativeInput.attach(mailbox)
        Task.detached(priority: .userInitiated) {
            for await message in messages {
                await package.receive(message)
            }
            await package.close()
        }
        return mailbox
    }

    func retire(_ state: WidgetState) {
        for instance in state.instances.values {
            if let surface = instance.surface { releaseShellFocus(from: surface, restore: true) }
        }
        Self.retireTraceCapture(state.package)
        state.mailbox?.finish()
        state.mailbox = nil
        Self.close(state.package)
        Self.close(state.loadingPackage)
        state.package = nil
        state.loadingPackage = nil
    }

    static func close(_ package: ShellWidgetPackage?) {
        guard let package else { return }
        let id = ObjectIdentifier(package)
        guard retiringTasks[id] == nil else { return }
        retireTraceCapture(package)
        retiringTasks[id] = Task {
            await package.close()
            retiringTasks.removeValue(forKey: id)
        }
    }

    static func flushRetiredWork() async {
        while !retiringTasks.isEmpty {
            for task in Array(retiringTasks.values) { await task.value }
        }
        for failure in await ShellStore.shared.flush() {
            Log.shell.error("Could not save shell store for \(failure.namespace.package): \(failure.message)")
        }
    }
}
