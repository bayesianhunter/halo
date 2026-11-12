// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

/// macOS's explicit UC connection list, not its temporary lent HID services or possible activation edges.
public enum UniversalControlLog {
    public enum Snapshot: Equatable { case unchanged, known(Bool, session: String), unknown }
    public static let predicate = #"process == "UniversalControl" AND category == "EVNT" AND eventMessage BEGINSWITH "Connected Devices IDS: ""#

    /// Unknown/redacted/new formats stay unknown; only a well-formed empty list proves disconnection.
    public static func connected(_ message: String) -> Bool? {
        identifiers(message).map { !$0.isEmpty }
    }

    private static func identifiers(_ message: String) -> [String]? {
        let prefix = "Connected Devices IDS: ["
        guard message.hasPrefix(prefix), message.hasSuffix("]") else { return nil }
        let body = message.dropFirst(prefix.count).dropLast().trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return [] }
        let ids = body.split(separator: ",", omittingEmptySubsequences: false)
        guard ids.allSatisfy({ id in
            let value = id.trimmingCharacters(in: .whitespaces)
            return value.utf8.count == 8 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        }) else { return nil }
        return Array(Set(ids.map { $0.trimmingCharacters(in: .whitespaces).uppercased() })).sorted()
    }

    /// A snapshot can contain many transitions. Keep the newest event rather than depend on JSON line order.
    public static func latest(_ data: Data) -> Bool? {
        if case .known(let value, _) = snapshot(data) { return value }
        return nil
    }

    public static func snapshot(_ data: Data) -> Snapshot {
        var latest: (time: UInt64, ids: [String]?)?
        for line in data.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  let time = (object["machTimestamp"] as? NSNumber)?.uint64Value else { continue }
            // A newer unknown format invalidates older evidence instead of reviving an old connection.
            if time >= (latest?.time ?? 0), message.hasPrefix("Connected Devices IDS: ") {
                latest = (time, identifiers(message))
            }
        }
        guard let latest else { return .unchanged }
        guard let ids = latest.ids else { return .unknown }
        // A peer-set change ends the old presentation cache, even if at least one UC peer stays connected.
        // Keep only an opaque fingerprint in memory; raw system identifiers are not retained or exported.
        let session = SHA256.hash(data: Data(ids.joined(separator: ",").utf8)).map { String(format: "%02x", $0) }.joined()
        return .known(!ids.isEmpty, session: session)
    }
}

/// Presentation only: remember uniquely identified lent inputs during a UC session, never add their old sender IDs
/// to the live scroll-source catalog. A fresh service replaces its old presentation, not an additional row.
public struct UniversalControlDevices {
    private var remembered: [String: Device] = [:]
    private var ambiguous = Set<String>()
    private var retiredSenders = Set<UInt64>()
    private var session: String?
    public init() {}

    public mutating func update(_ registered: [Device], connected: Bool?, session: String?) {
        if self.session != session, self.session != nil {
            retiredSenders.formUnion(remembered.values.map(\.sender))
            remembered.removeAll()
            ambiguous.removeAll()
        }
        self.session = session
        if connected == false {
            remembered.removeAll()
            ambiguous.removeAll()
            retiredSenders.removeAll()
            return
        }
        let groups = Dictionary(grouping: registered.filter(\.lent), by: \.profileKey)
        for (profile, services) in groups {
            if services.count != 1 { ambiguous.insert(profile); remembered[profile] = nil }
            else if !ambiguous.contains(profile), !retiredSenders.contains(services[0].sender) { remembered[profile] = services[0] }
        }
    }

    public func displayed(alongside registered: [Device], connected: Bool?) -> [Device] {
        guard connected == true else { return registered }
        let present = Set(registered.map(\.profileKey))
        return registered + remembered.values.filter { !present.contains($0.profileKey) }
    }
}
