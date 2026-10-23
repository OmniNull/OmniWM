// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

extension ShellWidgetPackage {
    func configureComponents(_ source: ShellWidgetSource, in vm: OpaquePointer) -> ShellScriptFailure? {
        for module in source.modules where !loadedModules.contains(module.path) {
            let status = omni_vm_add_module(
                vm,
                module.path,
                module.path.utf8.count,
                module.source,
                module.source.utf8.count
            )
            guard status == OMNI_OK else {
                return ShellScriptFailure(status: status, message: "could not load component module \(module.path)")
            }
            loadedModules.insert(module.path)
        }
        let providers: [String: ShellProviderConfiguration]
        do { providers = try prepareProviderConfigurations(source) }
        catch { return ShellScriptFailure(kind: .internalError, message: error.localizedDescription) }
        let configuration = ShellComponentCatalog.configurationBytes(
            instances: source.components,
            descriptors: source.componentDescriptors
        )
        let status = configuration.withUnsafeBufferPointer {
            omni_vm_configure_components(vm, $0.baseAddress, $0.count, Self.loadBudget, &errorBuffer, errorBuffer.count)
        }
        let failure = status == OMNI_OK ? nil : ShellScriptFailure(status: status, message: lastError())
        componentConfigurationValid = status == OMNI_OK
        if status == OMNI_OK {
            hasComponents = source.components.contains(where: \.enabled)
            configuredComponents = Dictionary(uniqueKeysWithValues: source.components.filter(\.enabled).map {
                ($0.id, $0)
            })
            componentDescriptors = source.componentDescriptors
            rootNetwork = Set(source.network.map(ShellHTTPPolicy.canonicalHost))
        }
        updateProviderConfigurations(providers)
        if let script { drainServices(in: script) }
        if let failure { return failure }
        return nil
    }
}
