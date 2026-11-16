// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A peripheral's reported charge, from the registry or a connected device's battery service.
public struct Battery: Equatable {
    public static let lowPercent = 20
    public let name: String
    public let serial: String
    public let percent: Int
    /// Taking charge, explicitly reported by the device (Apple's registry flags or Logitech's battery status).
    public let charging: Bool
    /// Explicit charge-complete report while external power remains connected. Never inferred from 100% alone.
    public let chargedOnCable: Bool
    /// The socket the charging cable goes into, when the model is known.
    public let connector: Connector?

    public enum Connector: Equatable { case lightning, usbC }

    /// Apple's Magic accessories moved from Lightning to USB-C in October 2024; the USB-C models' product IDs start
    /// at 0x0320 (Magic Keyboard 0x0320, Magic Mouse 0x0323, Magic Trackpad 0x0324, as the Linux HID drivers list
    /// them), the Lightning ones are below. Apple's vendor ID is 0x004C over Bluetooth and 0x05AC over USB.
    public static func connector(vendor: Int?, product: Int?) -> Connector? {
        guard let vendor, [0x004C, 0x05AC].contains(vendor), let product, product > 0 else { return nil }
        return product >= 0x0320 ? .usbC : .lightning
    }

    public init?(properties p: [String: Any]) {
        guard let percent = (p["percent"] as? NSNumber)?.intValue, (0...100).contains(percent) else { return nil }
        self.percent = percent
        charging = (p["charging"] as? NSNumber)?.boolValue ?? false
        // The registry flags read here do not yet establish this state reliably.
        chargedOnCable = false
        connector = Self.connector(vendor: (p["VendorID"] as? NSNumber)?.intValue, product: (p["ProductID"] as? NSNumber)?.intValue)
        serial = p["SerialNumber"] as? String ?? ""
        name = p["Product"] as? String ?? Device.unnamed
    }

    public init(name: String, serial: String, percent: Int, charging: Bool = false, chargedOnCable: Bool = false) {
        self.name = name
        self.serial = serial
        self.percent = min(max(percent, 0), 100)
        self.charging = charging
        self.chargedOnCable = chargedOnCable && !charging && self.percent == 100
        connector = nil
    }

    /// Registry readings win over Bluetooth LE readings of the same device, which carry no serial.
    public static func merge(_ registry: [Battery], _ ble: [Battery]) -> [Battery] {
        let names = Set(registry.map { $0.name.lowercased() })
        return (registry + ble.filter { !names.contains($0.name.lowercased()) })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var isLow: Bool { percent <= Battery.lowPercent }
    /// Low and not on a cable: shown in red, as iOS does. One that is charging is already being seen to.
    public var needsCharge: Bool { isLow && !charging }

    /// The device to show charging in the menu bar: the emptiest one on a cable.
    public static func charging(_ batteries: [Battery]) -> Battery? {
        batteries.filter(\.charging).min { $0.percent < $1.percent }
    }

    /// The lowest charge worth surfacing in the menu bar, if any device is low.
    public static func lowest(_ batteries: [Battery]) -> Battery? {
        batteries.filter(\.needsCharge).min { $0.percent < $1.percent }
    }

    /// Unattended low batteries, then charging, then full but still plugged in. Equal readings keep the selection.
    public static func indicator(_ batteries: [Battery], keeping previous: Battery? = nil) -> Battery? {
        let unattended = batteries.filter(\.needsCharge)
        let charging = batteries.filter(\.charging)
        let candidates = !unattended.isEmpty ? unattended : !charging.isEmpty ? charging : batteries.filter(\.chargedOnCable)
        guard let lowest = candidates.min(by: { $0.percent < $1.percent }) else { return nil }
        if let previous, let same = candidates.first(where: {
            $0.percent == lowest.percent && $0.name == previous.name && $0.serial == previous.serial
        }) { return same }
        return lowest
    }

    public enum IndicatorPoint: Equatable { case ordinary, charged, update }

    /// Updates own the point first; after attention to the update, a full plugged-in device gets its green point back.
    public static func indicatorPoint(for battery: Battery?, updateAvailable: Bool) -> IndicatorPoint {
        if updateAvailable { return .update }
        return battery?.chargedOnCable == true ? .charged : .ordinary
    }
}

/// What tells one battery's lines apart in the event log, so two devices of the same name (two Magic Mice) keep
/// separate histories and forecasts. The serial does; a Bluetooth LE reading carries none, so it takes the serial of
/// the registry's current reading of the same name, when exactly one has that name, and otherwise its name.
public struct BatterySerials {
    private var byName: [String: Set<String>] = [:]

    public init() {}

    /// The registry's latest readings; a device it no longer lists lends its serial to nothing.
    public mutating func update(_ registry: [Battery]) {
        byName = [:]
        for battery in registry {
            let serial = Self.normalize(battery.serial)
            if !serial.isEmpty { byName[battery.name.lowercased(), default: []].insert(serial) }
        }
    }

    public func key(for battery: Battery) -> String {
        let serial = Self.normalize(battery.serial)
        if !serial.isEmpty { return "battery-serial|" + serial }
        let name = battery.name.lowercased()
        if let serials = byName[name], serials.count == 1, let serial = serials.first { return "battery-serial|" + serial }
        return Self.nameKey(battery)
    }

    /// Every key whose lines describe this battery: its own, and the name it is logged under while its serial is not
    /// yet read, while it is the only one of `batteries` with that name.
    public func keys(for battery: Battery, among batteries: [Battery]) -> [String] {
        let own = key(for: battery), name = Self.nameKey(battery)
        let alone = batteries.filter { $0.name.lowercased() == battery.name.lowercased() }.count <= 1
        return own != name && alone ? [own, name] : [own]
    }

    static func nameKey(_ battery: Battery) -> String { "battery|" + battery.name.lowercased() }
    static func normalize(_ serial: String) -> String { serial.trimmingCharacters(in: .whitespaces).lowercased() }
}
