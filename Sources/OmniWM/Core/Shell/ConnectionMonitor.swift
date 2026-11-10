// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Network

struct ShellConnection: Equatable, Sendable, ShellValueWritable {
    enum InterfaceType: Equatable, Sendable {
        case wifi
        case wiredEthernet
        case cellular
        case loopback
        case other

        init(_ type: NWInterface.InterfaceType) {
            switch type {
            case .wifi: self = .wifi
            case .wiredEthernet: self = .wiredEthernet
            case .cellular: self = .cellular
            case .loopback: self = .loopback
            case .other: self = .other
            @unknown default: self = .other
            }
        }

        var kind: String {
            switch self {
            case .wifi: "wifi"
            case .wiredEthernet: "ethernet"
            case .cellular: "cellular"
            case .loopback,
                 .other: "other"
            }
        }
    }

    struct Interface: Equatable, Sendable {
        let type: InterfaceType
        let name: String
        let inUse: Bool
    }

    var kind: String
    var interface: String?

    init(kind: String, interface: String?) {
        self.kind = kind
        self.interface = interface
    }

    init(interfaces: [Interface], satisfied: Bool) {
        let link = Self.physicalLink(in: interfaces, satisfied: satisfied)
        self.init(kind: link?.type.kind ?? "none", interface: link?.name)
    }

    init(path: NWPath) {
        self.init(
            interfaces: path.availableInterfaces.map {
                Interface(type: InterfaceType($0.type), name: $0.name, inUse: path.usesInterfaceType($0.type))
            },
            satisfied: path.status == .satisfied
        )
    }

    private static func physicalLink(in interfaces: [Interface], satisfied: Bool) -> Interface? {
        let used = interfaces.filter { $0.inUse && $0.type != .loopback }
        guard satisfied, let first = used.first else { return nil }
        guard first.type == .other else { return first }
        return used.first { $0.type == .wifi || $0.type == .wiredEthernet } ?? first
    }

    func write(into writer: inout ShellValueWriter) {
        writer.map(2)
        writer.key("kind")
        writer.string(kind)
        writer.key("interface")
        interface.map { writer.string($0) } ?? writer.null()
    }
}

@MainActor
final class ConnectionMonitor: ShellDeviceSource {
    private static let queue = DispatchQueue(label: "com.barut.OmniWM.shell.connection", qos: .utility)

    private(set) var value: ShellConnection?
    var onChange: ((ShellConnection?) -> Void)?
    private var monitor: NWPathMonitor?
    private var generation = 0

    var isListening: Bool {
        monitor != nil
    }

    func setListening(_ listening: Bool) {
        guard listening != isListening else { return }
        generation += 1
        guard listening else {
            monitor?.cancel()
            monitor = nil
            value = nil
            return
        }
        let monitor = NWPathMonitor()
        let generation = generation
        monitor.pathUpdateHandler = { [weak self] path in
            let connection = ShellConnection(path: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.publish(connection, generation: generation)
                }
            }
        }
        monitor.start(queue: Self.queue)
        self.monitor = monitor
    }

    private func publish(_ connection: ShellConnection, generation: Int) {
        guard generation == self.generation, isListening, connection != value else { return }
        value = connection
        onChange?(connection)
    }
}
