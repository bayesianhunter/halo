// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct SourceSighting {
    public let device: Device
    public let continuous: Bool
    public let count: Int
}

public struct SourceCatalog {
    public private(set) var devices: [UInt64: Device] = [:]
    public private(set) var sightings: [String: SourceSighting] = [:]
    public private(set) var revision: UInt64 = 0
    public init() {}

    public mutating func updateDevices(_ list: [Device]) {
        let connected = Dictionary(list.filter { $0.sender != 0 }.map { ($0.sender, $0) },
                                   uniquingKeysWith: { first, _ in first })
        guard connected != devices else { return }
        devices = connected
        revision &+= 1
        // Diagnostics retain historical events; the source table shows connected inputs only.
        sightings = sightings.filter { devices[$0.value.device.sender] == $0.value.device }
    }

    /// Counts a scroll from this sender; true the first time this device is seen scrolling this way.
    @discardableResult
    public mutating func observe(sender: UInt64, continuous: Bool) -> Bool {
        guard let device = devices[sender] else { return false }
        let key = device.sourceKey(continuous: continuous)
        let count = sightings[key]?.count ?? 0
        sightings[key] = SourceSighting(device: device, continuous: continuous, count: count + 1)
        return count == 0
    }
}
