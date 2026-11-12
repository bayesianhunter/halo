// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One of the once-a-second reports the Bluetooth daemon logs while it streams music (A2DP) to a speaker or headphones.
/// The format is the daemon's own and undocumented; a line that does not parse is skipped, never guessed at.
public struct LinkQualitySample: Equatable {
    /// The share of packets the Mac had to send again, in percent. High but harmless while every resend arrives.
    public var retransmitted: Double
    /// Packets given up on: these are what is heard as a dropout.
    public var dropped: Int
    /// How loud the other end is heard, in dBm.
    public var rssi: Int
    /// The median noise across the channels in use, in dBm.
    public var noise: Int?
    /// The connection handle, to tell two streams apart.
    public var handle: Int

    public static func parse(_ line: String) -> LinkQualitySample? {
        guard line.contains("A2DP LinkQualityReport"),
              let handle = int(after: "Handle =", in: line),
              let retransmitted = number(after: "ReTx =", in: line),
              let rssi = int(after: "RSSI =", in: line) else { return nil }
        let dropped = (int(after: " TxFlush pkts =", in: line) ?? 0) + (int(after: "Tx2Flush pkts =", in: line) ?? 0)
        return LinkQualitySample(retransmitted: retransmitted, dropped: dropped, rssi: rssi,
                                 noise: int(after: "Noise = {", in: line), handle: handle)
    }

    private static func number(after label: String, in line: String) -> Double? {
        guard let range = line.range(of: label) else { return nil }
        let rest = line[range.upperBound...].drop { $0 == " " }
        let digits = rest.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
    }

    /// A whole number of a sane size; anything a report could not mean (huge, infinite) is not understood.
    private static func int(after label: String, in line: String) -> Int? {
        number(after: label, in: line).flatMap { abs($0) < 1e9 ? Int($0) : nil }
    }
}

/// What a check of a few seconds found, summed up for the page.
public struct LinkQualitySummary: Equatable {
    public var samples: Int
    public var averageRetransmitted: Double
    public var dropped: Int
    public var averageRSSI: Int
    public var medianNoise: Int?

    public init?(_ samples: [LinkQualitySample]) {
        guard !samples.isEmpty else { return nil }
        self.samples = samples.count
        averageRetransmitted = samples.map(\.retransmitted).reduce(0, +) / Double(samples.count)
        dropped = samples.map(\.dropped).reduce(0, +)
        averageRSSI = Int((Double(samples.map(\.rssi).reduce(0, +)) / Double(samples.count)).rounded())
        let noises = samples.compactMap(\.noise).sorted()
        medianNoise = noises.isEmpty ? nil : noises[noises.count / 2]
    }
}
