// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

extension ShellWidgetPackage {
    func updateComponents(_ source: ShellWidgetSource, in script: ShellScript) async {
        guard source.profile == storeProfile, let plan = ShellComponentReloadPlan.make(
            source: source, loaded: .init(chunk: loadedChunk, main: loadedMain, modules: loadedModules),
            previousDescriptors: componentDescriptors,
            matches: { module in
                omni_vm_module_matches(
                    script.vm, module.path, module.path.utf8.count, module.source, module.source.utf8.count
                )
            }
        ) else {
            requestReload()
            return
        }
        if !plan.widgets.isEmpty || !plan.modules.isEmpty {
            guard await reloadComponents(plan, source: source, in: script) else { return }
        }
        guard await retireChangedComponentOwners(source, in: script) else { return }
        await seedComponents(source, in: script)
        guard !closing, self.script === script else { return }
        if let failure = configureComponents(source, in: script.vm) {
            outbox.fail(name: name, generation: generation, failure: failure)
            return
        }
        for (key, instance) in script.instances {
            await renderVisible(key, instance)
            guard !closing, self.script === script else { return }
        }
    }

    private func reloadComponents(
        _ plan: ShellComponentReloadPlan,
        source: ShellWidgetSource,
        in script: ShellScript
    ) async -> Bool {
        let status = replaceModules(plan, in: script.vm)
        if status == OMNI_ERR_RELOAD_REQUIRED {
            requestReload()
            return false
        }
        guard status == OMNI_OK || status == OMNI_ERR_COMPONENT else {
            outbox.fail(name: name, generation: generation, failure: ShellScriptFailure(
                status: status, message: lastError()
            ))
            return false
        }
        if status == OMNI_ERR_COMPONENT { log(1) { _ in lastError() } }
        drainServices(in: script)
        let affected = Set(plan.widgets)
        let retired = Set(configuredComponents.compactMap { affected.contains($0.value.widget) ? $0.key : nil })
        let owners = storeOwners.filter { $0.key.instance.map(retired.contains) == true }
        configuredComponents = configuredComponents.filter { !retired.contains($0.key) }
        for namespace in owners.keys { storeOwners.removeValue(forKey: namespace) }
        loadedModules = Set(source.modules.map(\.path))
        await retireProviders()
        guard !closing, self.script === script else { return false }
        await retireResources(components: retired)
        guard !closing, self.script === script else { return false }
        for failure in await store.close(owners) { log(1) { _ in "store: \(failure.message)" } }
        guard !closing, self.script === script else { return false }
        return true
    }

    private func retireChangedComponentOwners(_ source: ShellWidgetSource, in script: ShellScript) async -> Bool {
        let retired = Set(configuredComponents.values.compactMap { previous -> String? in
            let next = source.components.first { $0.id == previous.id }
            return next?.enabled != true || next?.widget != previous.widget ? previous.id : nil
        })
        guard !retired.isEmpty else { return true }
        var retained = ShellWidgetSource(chunk: source.chunk, main: source.main, modules: [])
        retained.components = configuredComponents.values.filter { !retired.contains($0.id) }.sorted { $0.id < $1.id }
        retained.componentDescriptors = componentDescriptors
        if let failure = configureComponents(retained, in: script.vm) {
            outbox.fail(name: name, generation: generation, failure: failure)
            return false
        }
        let owners = storeOwners.filter { $0.key.instance.map(retired.contains) == true }
        for namespace in owners.keys { storeOwners.removeValue(forKey: namespace) }
        await retireProviders()
        guard !closing, self.script === script else { return false }
        await retireResources(components: retired)
        guard !closing, self.script === script else { return false }
        for failure in await store.close(owners) { log(1) { _ in "store: \(failure.message)" } }
        return !closing && self.script === script
    }

    private func requestReload() {
        guard !reloadRequested else { return }
        reloadRequested = true
        outbox.reload(name: name, generation: generation)
    }

    private func replaceModules(_ plan: ShellComponentReloadPlan, in vm: OpaquePointer) -> omni_status {
        struct Span {
            let path: Int
            let pathLength: Int
            let source: Int
            let sourceLength: Int
            let remove: Bool
        }
        var names = ShellValueWriter()
        names.array(plan.widgets.count)
        for widget in plan.widgets { names.string(widget) }
        var storage: [CChar] = []
        let spans = plan.modules.map { module in
            let path = storage.count
            storage.append(contentsOf: module.path.utf8.map { CChar(bitPattern: $0) })
            let source = storage.count
            if let text = module.source { storage.append(contentsOf: text.utf8.map { CChar(bitPattern: $0) }) }
            return Span(
                path: path, pathLength: source - path, source: source, sourceLength: storage.count - source,
                remove: module.source == nil
            )
        }
        return storage.withUnsafeBufferPointer { bytes in
            let changes = spans.map { span in
                omni_module_change(
                    path: bytes.baseAddress?.advanced(by: span.path), path_length: span.pathLength,
                    source: span.remove ? nil : bytes.baseAddress?.advanced(by: span.source),
                    source_length: span.sourceLength, remove: span.remove
                )
            }
            return names.bytes.withUnsafeBufferPointer { encodedNames in
                changes.withUnsafeBufferPointer { changes in
                    omni_vm_reload_components(
                        vm, encodedNames.baseAddress, encodedNames.count, changes.baseAddress, changes.count,
                        Self.loadBudget, &errorBuffer, errorBuffer.count
                    )
                }
            }
        }
    }
}
