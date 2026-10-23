// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMScriptHost
import Synchronization

struct ShellScriptFailure: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case compile
        case runtime
        case memory
        case timeout
        case internalError
    }

    let kind: Kind
    let message: String

    init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    init(status: omni_status, message: String) {
        kind = switch status {
        case OMNI_ERR_COMPILE: .compile
        case OMNI_ERR_MEMORY: .memory
        case OMNI_ERR_TIMEOUT: .timeout
        case OMNI_ERR_RUNTIME: .runtime
        default: .internalError
        }
        self.message = message
    }
}

enum ShellWidgetView: Int, Sendable {
    case bar
    case popout

    var wire: omni_view {
        switch self {
        case .bar: OMNI_VIEW_BAR
        case .popout: OMNI_VIEW_POPOUT
        }
    }
}

enum ShellWidgetMessage: Sendable {
    case update(ShellWidgetData)
    case dataChanged
    case settings([UInt8])
    case components(ShellWidgetSource)
    case catalog(enabled: Bool, catalog: [UInt8], schema: [UInt8])
    case bars([ShellBarKey: ShellBarData])
    case invoke(ShellBarKey, ShellWidgetView, action: UInt32, sequence: Int, event: ShellEvent)
    case gesture(ShellGestureBox.Pending)
    case popout(ShellBarKey, Bool, trace: ShellFrameTraceContext? = nil)
    case interval(Double?)
    case trigger(name: String, value: String?)
    case log(String)
    case services
    case providers
    case resources
    case nativeInput(ShellNativeInput)
    case capture(ShellCaptureRequest)
}

struct ShellWidgetDeclaration: Equatable, Sendable {
    var interval: Double?
    var spansIslands = false
    var hasPopout = false
    var hasTrigger = false
}

extension ShellWidgetDeclaration {
    static let maximumInterval: Double = 86400

    static func validInterval(_ seconds: Double) -> Double? {
        seconds > 0 ? min(seconds, maximumInterval) : nil
    }

    init(vm: OpaquePointer) {
        var interval = 0.0
        var spans = false
        self.init(
            interval: omni_vm_global_number(vm, "interval", &interval) == OMNI_OK ? Self.validInterval(interval) : nil,
            spansIslands: omni_vm_global_boolean(vm, "spanIslands", &spans) == OMNI_OK && spans,
            hasPopout: omni_vm_global_function(vm, "popout") == OMNI_OK,
            hasTrigger: omni_vm_global_function(vm, "trigger") == OMNI_OK
        )
    }
}

struct ShellTreeKey: Hashable, Sendable {
    let bar: ShellBarKey
    let view: ShellWidgetView
}

final class ShellScript {
    let vm: OpaquePointer
    var instances: [ShellBarKey: OpaquePointer] = [:]

    init(vm: OpaquePointer) {
        self.vm = vm
    }

    deinit {
        for instance in instances.values {
            omni_instance_destroy(instance)
        }
        _ = omni_vm_destroy(vm)
    }
}

actor ShellWidgetPackage {
    private static let nextServiceGeneration = Mutex<UInt64>(0)
    static let memoryLimit = 32 << 20
    static let loadBudget: UInt64 = 100_000_000
    static let renderBudget: UInt64 = 8_000_000
    static let handlerBudget: UInt64 = 25_000_000
    static let stringLimit: UInt32 = 4096
    static let stringByteLimit = memoryLimit / 4
    static let logLimit = 20
    static let logWindow = Duration.seconds(10)

    final class InstanceState {
        var pendingData: UInt64 = .max
        var backgroundDemand: UInt64 = 0
        var invalidations = InlineArray<2, UInt64>(repeating: 0)
        var bar: ShellBarData?
        var sequences = InlineArray<2, Int>(repeating: 0)
        var deps = InlineArray<2, UInt64>(repeating: .max)
    }

    nonisolated let name: String
    nonisolated let generation: Int
    nonisolated let gestures = ShellGestureBox()
    nonisolated let services: ShellServiceLedger
    nonisolated let providerInbox = ShellProviderInbox()
    nonisolated let resourceInbox = ShellResourceInbox()
    nonisolated let nativeInput = ShellNativeInputPort()
    nonisolated let capture: ShellCapturePort
    var captureContext: ShellFrameTraceContext?
    var captureBeginTask: Task<Void, Never>?
    var captureEndTask: Task<UInt64, Never>?
    var captureVMStarted = false
    let resourceStore: ShellResourceStore
    let retireResourceImages: @Sendable (ShellServiceOwner) async -> Void
    var preparedResources: [ShellStoreNamespace: ShellResourceStore.PreparedTokens] = [:]
    var resourceOwners: Set<ShellServiceOwner> = []
    var finalResourceStores: [ShellStoreNamespace: ShellStore.Write] = [:]
    var resourceRestores: [ShellServiceID: ShellResourceID] = [:]
    var resourceWork: [ResourceWork] = []
    var resourceWorker: Task<Void, Never>?
    let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.package", qos: .userInitiated)
    let outbox: ShellWidgetOutbox
    let store: ShellStore
    var storeProfile = ShellDefaults.profile
    var storeOwners: [ShellStoreNamespace: ShellServiceOwner] = [:]
    var configuredComponents: [String: ShellComponentInstance] = [:]
    var componentConfigurationValid = false
    var http: ShellHTTPService?
    var providerConfigurations: [String: ShellProviderConfiguration] = [:]
    var providerSlots: [String: ProviderSlot] = [:]
    var pendingProviderRequests: [PendingProviderRequest] = []
    var providerActions: [ShellServiceID: ProviderActionRoute] = [:]
    var providerReconciliation: Task<Void, Never>?
    var providerDeadline: (any DispatchSourceTimer)?
    var closing = false
    var closeTask: Task<[ShellStoreFailure], Never>?
    var script: ShellScript?
    var loadedModules: Set<String> = []
    var loadedChunk = ""
    var loadedMain = ""
    var componentDescriptors: [ShellComponentDescriptor] = []
    var rootNetwork: Set<String> = []
    var hasComponents = false
    var reloadRequested = false
    var states: [ShellBarKey: InstanceState] = [:]
    let latestData: ShellLatestWidgetData?
    var dataRevision: UInt64 = 0
    var current = ShellWidgetData()
    var popout: ShellBarKey?
    var settings: [UInt8] = []
    var configurationCatalog: [UInt8] = []
    var configurationSchema: [UInt8] = []
    var pendingConfigurations: [ShellConfigurationRequest] = []
    var liveAfterCollect = 0
    var publishedBackgroundDemand: UInt64 = 0
    private(set) var declaration = ShellWidgetDeclaration()
    var interval: Double?
    var lastTimedRender: ContinuousClock.Instant?
    var logWindowStart = ContinuousClock.now
    var logsInWindow = 0
    var droppedLogs = 0
    var errorBuffer = [CChar](repeating: 0, count: 512)
    var valueWriter = ShellValueWriter()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(
        name: String, generation: Int, outbox: ShellWidgetOutbox, store: ShellStore = .shared,
        latestData: ShellLatestWidgetData? = nil, resourceStore: ShellResourceStore? = nil,
        retireResourceImages: @escaping @Sendable (ShellServiceOwner) async -> Void = { _ in }
    ) {
        self.name = name
        self.generation = generation
        self.outbox = outbox
        self.store = store
        self.latestData = latestData
        self.retireResourceImages = retireResourceImages
        self
            .resourceStore = resourceStore ??
            ShellResourceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "omnishell-resources-\(UUID().uuidString)",
                isDirectory: true
            ))
        services = ShellServiceLedger(generation: Self.nextServiceGeneration.withLock { value in
            value += 1
            return value
        })
        capture = ShellCapturePort(serviceGeneration: services.generation)
    }

    func validateReload(_ source: ShellWidgetSource) async -> ShellScriptFailure? {
        defer { script = nil }
        return await load(source, validateOnly: true)
    }

    func load(_ source: ShellWidgetSource, validateOnly: Bool = false) async -> ShellScriptFailure? {
        guard !closing else { return ShellScriptFailure(kind: .internalError, message: "package is closed") }
        guard let vm = ShellVM.make(memoryLimit: Self.memoryLimit) else {
            return ShellScriptFailure(kind: .internalError, message: "the script VM could not be created")
        }
        let loaded = ShellScript(vm: vm)
        script = loaded
        storeProfile = source.profile
        rootNetwork = Set(source.network.map(ShellHTTPPolicy.canonicalHost))
        guard omni_vm_set_service_generation(vm, services.generation) == OMNI_OK else {
            script = nil
            return ShellScriptFailure(kind: .internalError, message: "service generation could not be initialized")
        }
        _ = omni_vm_set_configuration_enabled(vm, source.isIslandRoot)
        await seedStore(nil, in: loaded)
        guard !closing, script === loaded else {
            return ShellScriptFailure(kind: .internalError, message: "package was closed while loading")
        }
        await seedResources(nil, in: loaded, validateOnly: validateOnly)
        guard !closing, script === loaded else {
            return ShellScriptFailure(kind: .internalError, message: "package was closed while loading")
        }
        if let failure = installModules(source, in: vm) { return failure }
        let status = omni_vm_load(
            vm,
            source.chunk,
            source.main,
            source.main.utf8.count,
            Self.loadBudget,
            &errorBuffer,
            errorBuffer.count
        )
        if !validateOnly { drainServices(in: loaded) }
        guard status == OMNI_OK else {
            return ShellScriptFailure(status: status, message: lastError())
        }
        guard omni_vm_global_function(vm, "render") == OMNI_OK else {
            return ShellScriptFailure(kind: .compile, message: "the widget does not define a render function")
        }
        if validateOnly { return nil }
        return await finishLoad(source, in: loaded)
    }

    private func finishLoad(_ source: ShellWidgetSource, in loaded: ShellScript) async -> ShellScriptFailure? {
        let vm = loaded.vm
        loadedModules = Set(source.modules.map(\.path))
        loadedChunk = source.chunk
        loadedMain = source.main
        await seedComponents(source, in: loaded)
        guard !closing, script === loaded else {
            return ShellScriptFailure(kind: .internalError, message: "package was closed while loading")
        }
        if let failure = configureComponents(source, in: vm) {
            loadedModules.removeAll()
            return failure
        }
        declaration = ShellWidgetDeclaration(vm: vm)
        omni_vm_collect(vm)
        liveAfterCollect = omni_vm_bytes_in_use(vm)
        return nil
    }

    private func installModules(_ source: ShellWidgetSource, in vm: OpaquePointer) -> ShellScriptFailure? {
        guard omni_vm_set_module_limit(vm, source.moduleLimit) == OMNI_OK else {
            script = nil
            return ShellScriptFailure(kind: .compile, message: "invalid module limit")
        }
        for module in source.modules {
            guard omni_vm_add_module(vm, module.path, module.path.utf8.count, module.source, module.source.utf8.count)
                == OMNI_OK
            else {
                script = nil
                return ShellScriptFailure(
                    kind: .memory,
                    message: "could not load module \(module.path) within the \(source.moduleLimit)-module limit"
                )
            }
        }
        return nil
    }

    func close() async {
        if let closeTask { _ = await closeTask.value
            return
        }
        closing = true
        nativeInput.close()
        let task = Task { await finishClose() }
        closeTask = task
        for failure in await task.value {
            log(1) { _ in "store: \(failure.message)" }
        }
    }

    private func finishClose() async -> [ShellStoreFailure] {
        let captured = await finishTraceCapture(retired: true)
        capture.close(completedCapture: captured)
        if let script {
            _ = configureComponents(ShellWidgetSource(chunk: "", main: "", modules: []), in: script.vm)
            _ = omni_vm_close_services(script.vm)
            drainServices(in: script)
        }
        services.close()
        resourceInbox.close()
        http = nil
        pendingConfigurations.removeAll()
        script = nil
        loadedModules.removeAll()
        states.removeAll()
        let owners = storeOwners
        await closeProviders()
        await retireResources()
        return await store.close(owners)
    }
}
