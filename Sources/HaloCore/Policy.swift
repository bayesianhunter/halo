// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

public enum ScrollRule: String, Codable, CaseIterable {
    case unchanged, reverse
}

public struct Device: Equatable {
    /// What a device without a product name is called. The app sets its localized text before listing devices;
    /// the identity hash never uses it, so saved rules do not depend on the language.
    public static var unnamed = "未命名设备"
    /// The transport of a device that reports none. Part of the identity hash, so it never changes;
    /// the app shows its own text in its place.
    public static let unknownTransport = "未知连接"
    public let sender: UInt64
    public let name: String
    public let transport: String
    /// Attached to this Mac, rather than virtual or mirrored from another Mac by Universal Control.
    public let local: Bool
    public let trackpad: Bool
    public let key: String
    public let profileKey: String
    public let sessionOnly: Bool
    public let serial: String

    public init(properties p: [String: Any]) {
        sender = (p["sender"] as? NSNumber)?.uint64Value ?? 0
        let product = p["Product"] as? String
        name = product ?? Device.unnamed
        transport = p["Transport"] as? String ?? Device.unknownTransport
        let local = (p["local"] as? NSNumber)?.boolValue ?? false
        self.local = local
        // Display metadata; it never selects the reversing rule.
        trackpad = (p["touchpad"] as? NSNumber)?.boolValue == true ||
            p["HIDScrollAccelerationType"] as? String == "HIDTrackpadScrollAcceleration"
        let serial = p["SerialNumber"] as? String ?? ""
        self.serial = serial
        let builtIn = (p["Built-In"] as? NSNumber)?.boolValue == true
        sessionOnly = serial.isEmpty && !(local && builtIn)
        // A missing name hashes as the placeholder saved rules were made with, whatever `unnamed` shows.
        let identity = [local ? "local" : "virtual", transport, product ?? "未命名设备",
                        String(describing: p["VendorID"] ?? ""), String(describing: p["ProductID"] ?? ""),
                        p["HIDScrollAccelerationType"] as? String ?? "", serial,
                        sessionOnly ? String(sender) : ""]
        let data = try! JSONEncoder().encode(identity)
        key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let profileData = try! JSONEncoder().encode(Array(identity.dropLast()))
        profileKey = "profile:" + SHA256.hash(data: profileData).map { String(format: "%02x", $0) }.joined()
    }

    public func sourceKey(continuous: Bool) -> String {
        key + (continuous ? ":continuous" : ":wheel")
    }

    public func profileSourceKey(continuous: Bool) -> String {
        profileKey + (continuous ? ":continuous" : ":wheel")
    }

    /// One another Mac lends this one through Universal Control, which names them with a "V-" prefix; its own helper
    /// ("UC Automouse", transport UniversalControl) is not a device anyone would recognise.
    public var lent: Bool { !local && name.hasPrefix("V-") && transport != "UniversalControl" }

    /// Whether it gets a row with a switch: this Mac's own and lent ones at once, other virtual ones only once they
    /// scrolled here or carry a rule.
    public func listed(scrolled: Bool, ruled: Bool) -> Bool { local || lent || scrolled || ruled }

    /// Where its row goes among a Mac's devices: built in, then attached, then lent by the other Mac, then other
    /// virtual ones. Fixed, so a name never moves a device out of its group.
    public var listGroup: Int { local ? (name.hasPrefix("Apple Internal") ? 0 : 1) : (lent ? 2 : 3) }

    /// By group, then by the name the row shows (`shown`: the app's, which drops "V-" and calls built-in ones by their
    /// kind, in the person's language).
    public static func listOrder(shown: @escaping (Device) -> String) -> (Device, Device) -> Bool {
        { a, b in
            if a.listGroup != b.listGroup { return a.listGroup < b.listGroup }
            let byName = shown(a).localizedStandardCompare(shown(b))
            return byName == .orderedSame ? a.key < b.key : byName == .orderedAscending
        }
    }
}

public struct Policy {
    public var enabled = false
    public var rules: [String: ScrollRule] = [:]
    /// Wheel speed per device, by the same keys as `rules`; absent means 1×.
    public var speeds: [String: Double] = [:]
    /// The speeds the menu and settings offer.
    public static let speedSteps: [Double] = [0.5, 1, 1.5, 2, 3, 4]
    private var profileCounts: [String: Int] = [:]
    public init() {}

    @discardableResult
    public mutating func updateDevices(_ devices: [Device]) -> Bool {
        let connected = Dictionary(devices.filter { $0.sender != 0 }.map { ($0.sender, $0) },
                                   uniquingKeysWith: { first, _ in first })
        profileCounts = Dictionary(grouping: connected.values, by: \.profileKey).mapValues(\.count)
        let previous = (rules, speeds)
        // Preserve existing session selections while teaching the reconnect profile.
        // A profile describes matching metadata, not a guaranteed physical identity.
        for device in connected.values where device.sessionOnly && profileCounts[device.profileKey] == 1 {
            for continuous in [false, true] {
                if let rule = rules[device.sourceKey(continuous: continuous)] {
                    rules[device.profileSourceKey(continuous: continuous)] = rule
                }
            }
            if let speed = speeds[device.sourceKey(continuous: false)] {
                speeds[device.profileSourceKey(continuous: false)] = speed
            }
        }
        return previous.0 != rules || previous.1 != speeds
    }

    public func rule(for device: Device, continuous: Bool) -> ScrollRule {
        if let explicit = rules[device.sourceKey(continuous: continuous)] { return explicit }
        guard device.sessionOnly, Self.sole(profileCounts[device.profileKey]) else { return .unchanged }
        return rules[device.profileSourceKey(continuous: continuous)] ?? .unchanged
    }

    public mutating func setRule(_ rule: ScrollRule, for device: Device, continuous: Bool) {
        rules[device.sourceKey(continuous: continuous)] = rule
        if device.sessionOnly, profileCounts[device.profileKey] == 1 {
            rules[device.profileSourceKey(continuous: continuous)] = rule
        }
    }

    /// How fast a device's wheel scrolls. Trackpads and smooth-scrolling devices keep their own feel.
    public func speed(for device: Device) -> Double {
        if let explicit = speeds[device.sourceKey(continuous: false)] { return explicit }
        guard device.sessionOnly, Self.sole(profileCounts[device.profileKey]) else { return 1 }
        return speeds[device.profileSourceKey(continuous: false)] ?? 1
    }

    public mutating func setSpeed(_ speed: Double, for device: Device) {
        let value: Double? = speed == 1 ? nil : speed
        speeds[device.sourceKey(continuous: false)] = value
        if device.sessionOnly, profileCounts[device.profileKey] == 1 {
            speeds[device.profileSourceKey(continuous: false)] = value
        }
    }

    /// Whether a profile's rule may stand in for a device without a serial number: it is the only one connected with
    /// that profile, or not yet listed at all, as when the scroll tap looks a new sender up before the next listing.
    private static func sole(_ count: Int?) -> Bool { (count ?? 1) == 1 }

    /// What to multiply a scroll's vertical delta by: -1 to reverse, the wheel speed for wheels, 1 to leave it.
    public func factor(device: Device?, continuous: Bool) -> Double {
        guard enabled, let device, device.sender != 0 else { return 1 }
        let sign: Double = rule(for: device, continuous: continuous) == .reverse ? -1 : 1
        return sign * (continuous ? 1 : speed(for: device))
    }

    public func shouldReverse(device: Device?, continuous: Bool) -> Bool {
        guard enabled, let device, device.sender != 0 else { return false }
        return rule(for: device, continuous: continuous) == .reverse
    }
}
