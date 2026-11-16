// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Battery-only HID++ 2.0 queries, implemented from Logitech's published protocol, not another driver's code.
/// Packet/root format: https://github.com/Logitech/cpg-docs/tree/master/hidpp20
/// Battery feature 0x1000: Logitech HID++ 2.0 Draft Specification, 2012-06-04, section 0x1000.
public struct HIDPPBattery {
    public struct Reading: Equatable {
        /// This protocol's zero means unknown, unlike the standard BLE battery percentage.
        public let percent: Int?
        public let status: UInt8
        public var charging: Bool { [1, 2, 4].contains(status) }
        public var chargedOnCable: Bool { status == 3 }
    }
    public struct Update {
        public var request: Data?
        public var reading: Reading?
        public var capability: Capability?
    }
    public struct Capability: Equatable {
        public let levels: UInt8
        public let flags: UInt8
        public var rechargeable: Bool { flags & 4 != 0 }
        public var coarse: Bool { levels < 10 || flags & 2 == 0 }
    }
    public private(set) var featureIndex: UInt8?
    public private(set) var reading: Reading?
    public private(set) var capability: Capability?
    private var capabilityRequested = false
    private static let software: UInt8 = 0x0D
    public init() {}

    /// A charge-complete report is stronger evidence than a coarse or delayed standard percentage. Once the
    /// device reports discharging again, subsequent standard readings are taken normally.
    public func percent(forStandardReading reported: Int) -> Int {
        reading?.status == 3 ? 100 : reported
    }

    /// Resolve only the battery feature; no configuration or charging-control commands are sent.
    public static var discovery: Data { request(feature: 0, parameters: [0x10, 0x00]) }
    /// The MX's GATT value is the 18-byte feature/function payload. Report ID and device index are implicit.
    public static var discoveryGATT: Data { Data(discovery.dropFirst(2)) }

    public mutating func receiveGATT(_ value: Data) -> Update {
        guard value.count == 18 else { return Update() }
        var result = receive(Data([0x11, 0xFF]) + value)
        if let request = result.request { result.request = Data(request.dropFirst(2)) }
        return result
    }

    private static func request(feature: UInt8, function: UInt8 = 0, parameters: [UInt8] = []) -> Data {
        let header: [UInt8] = [0x11, 0xFF, feature, function << 4 | software]
        return Data(header + parameters + Array(repeating: 0, count: 16 - parameters.count))
    }

    public mutating func receive(_ data: Data) -> Update {
        let packet = [UInt8](data)
        guard (packet.count == 20 && packet.first == 0x11) || (packet.count == 7 && packet.first == 0x10),
              packet[1] == 0xFF else { return Update() }
        let function = packet[3] >> 4
        let software = packet[3] & 0x0F
        if packet[2] == 0, function == 0, software == Self.software, featureIndex == nil {
            guard packet[4] != 0 else { return Update() } // unsupported: keep the standard battery reading
            featureIndex = packet[4]
            return Update(request: Self.request(feature: packet[4]))
        }
        // Zero software ID is the battery's unsolicited change notification; other clients' replies are ignored.
        guard let featureIndex, packet[2] == featureIndex else { return Update() }
        if function == 1, software == Self.software, capabilityRequested,
           (2...100).contains(packet[4]), packet[5] & 0xF8 == 0 {
            let next = Capability(levels: packet[4], flags: packet[5])
            capability = next
            return Update(capability: next)
        }
        guard function == 0, [0, Self.software].contains(software),
              packet[4] <= 100, packet[6] <= 7 else { return Update() }
        let percent = packet[6] == 3 ? 100 : packet[4] > 0 ? Int(packet[4]) : nil
        let next = Reading(percent: percent, status: packet[6])
        reading = next
        // Static metadata is read once per connection, after the first status. No timer or retry loop.
        let request = capabilityRequested ? nil : Self.request(feature: featureIndex, function: 1)
        capabilityRequested = true
        return Update(request: request, reading: next)
    }
}
