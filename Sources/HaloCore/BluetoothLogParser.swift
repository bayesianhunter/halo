// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Reads the few bluetoothd log lines Halo uses. The wording is not an API and can change with any macOS update;
/// a line that no longer matches is simply not understood, and Halo then says less, never something wrong.
public struct BluetoothLogParser {
    /// Keep both event lines and the device line a battery value depends on. Shared with the reader so the filter
    /// can be checked against the parser. On a sample of real logs it kept about 40% of those categories' lines.
    public static let logPredicate = #"process == "bluetoothd" AND (category == "Server.Audio" OR category == "Server.Handsfree") AND "#
        + #"(eventMessage BEGINSWITH "A2DP LinkQualityReport:" OR eventMessage BEGINSWITH "Received HF indicator event from device " "#
        + #"OR eventMessage BEGINSWITH "Received battery level HF indicator with value: " OR eventMessage BEGINSWITH "Sending ring notification" "#
        + #"OR eventMessage BEGINSWITH "Sending call setup")"#

    public enum Event: Equatable {
        /// One A2DP link quality report: the share of packets that had to be sent again. Reports carry no address;
        /// they belong to whatever is playing.
        case quality(retransmitted: Double)
        /// The Mac rang this device for a call (an iPhone call relayed to the Mac): it is about to enter call mode.
        case ring(address: String)
        /// The battery level the device reported over its hands-free link.
        case battery(address: String, percent: Int)
    }

    /// The device of the last hands-free indicator line, which names the device; the value comes on the next line.
    private var indicatorDevice: String?

    public init() {}

    public mutating func parse(_ message: String) -> Event? {
        if message.hasPrefix("A2DP LinkQualityReport:") {
            return Self.number(after: "ReTx = ", in: message).map { .quality(retransmitted: $0) }
        }
        if message.hasPrefix("Received HF indicator event from device ") {
            indicatorDevice = Self.address(in: message)
            return nil
        }
        if message.hasPrefix("Received battery level HF indicator with value: "), let device = indicatorDevice,
           let value = Self.number(after: "value: ", in: message), (0...100).contains(value) {
            indicatorDevice = nil
            return .battery(address: device, percent: Int(value))
        }
        if message.hasPrefix("Sending ring notification") || message.hasPrefix("Sending call setup \"incoming\""),
           let device = Self.address(in: message) {
            return .ring(address: device)
        }
        return nil
    }

    /// The first colon-separated Bluetooth address in a line, lower-cased as Halo keeps them.
    static func address(in message: String) -> String? {
        guard let range = message.range(of: #"([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"#, options: .regularExpression) else { return nil }
        return message[range].lowercased()
    }

    static func number(after label: String, in message: String) -> Double? {
        guard let start = message.range(of: label)?.upperBound else { return nil }
        let digits = message[start...].drop { $0 == " " }.prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }
}
