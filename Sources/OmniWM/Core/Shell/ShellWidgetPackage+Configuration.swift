// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

extension ShellWidgetPackage {
    func updateConfigurationCatalog(enabled: Bool, catalog: [UInt8], schema: [UInt8], in script: ShellScript) async {
        _ = omni_vm_set_configuration_enabled(script.vm, enabled)
        var changed: UInt64 = 0
        if configurationCatalog != catalog { changed |= ShellDataKey.catalog.bit }
        if configurationSchema != schema { changed |= ShellDataKey.settingsSchema.bit }
        guard changed != 0 else { return }
        configurationCatalog = catalog
        configurationSchema = schema
        for (key, instance) in script.instances {
            guard applyConfigurationCatalog(instance) else { return }
            await renderVisible(key, instance, changed: changed)
            guard !closing, self.script === script else { return }
        }
    }

    func applyConfigurationCatalog(_ instance: OpaquePointer) -> Bool {
        for (key, value) in [(ShellDataKey.catalog, configurationCatalog), (.settingsSchema, configurationSchema)] {
            let bytes = value.isEmpty ? [UInt8(OMNI_VALUE_NIL.rawValue)] : value
            let status = bytes.withUnsafeBufferPointer {
                omni_instance_set_value(instance, key.rawValue, $0.baseAddress, $0.count)
            }
            guard status == OMNI_OK else {
                outbox.fail(
                    name: name,
                    generation: generation,
                    failure: ShellScriptFailure(
                        status: status,
                        message: "Could not install shell \(key.rawValue) metadata"
                    ),
                    deps: key.bit
                )
                return false
            }
        }
        return true
    }

    func enqueueConfiguration(_ id: ShellServiceID, value: [UInt8], cancelled: Bool, in script: ShellScript) {
        if cancelled {
            pendingConfigurations.removeAll { $0.id == id }
            outbox.cancelConfiguration(name: name, generation: generation, id: id)
            return
        }
        guard services.register(id) else {
            _ = omni_vm_cancel_service(script.vm, id.owner.wire, id.request)
            log(1) { _ in "configuration request was rejected by its native owner" }
            return
        }
        do {
            pendingConfigurations.append(try ShellConfigurationRequest(id: id, bytes: value))
        } catch {
            services.complete(ShellConfigurationRequest.completion(id: id, error: "Invalid configuration request"))
        }
    }

    func flushConfigurationRequests() {
        guard !pendingConfigurations.isEmpty else { return }
        outbox.configure(name: name, generation: generation, requests: pendingConfigurations)
        pendingConfigurations.removeAll(keepingCapacity: true)
    }
}
