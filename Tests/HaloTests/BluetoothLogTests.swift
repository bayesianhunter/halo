// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

/// Real bluetoothd lines from 2026-11-02, as `log stream` hands them over in `eventMessage`, with the device address replaced.
final class BluetoothLogTests: XCTestCase {
    func testNarrowFilterPreservesEventsAndBatteryContext() {
        let messages: [(String, String, String)] = [
            ("bluetoothd", "Server.Audio", "Diversity statistics: ignored"),
            ("bluetoothd", "Server.Audio", "A2DP LinkQualityReport: ReTx = 13.9%"),
            ("bluetoothd", "Server.Handsfree", "Received HF indicator event from device AA:BB:CC:DD:EE:02"),
            ("bluetoothd", "Server.Audio", "Beamforming statistics: ignored"),
            ("bluetoothd", "Server.Handsfree", "Received battery level HF indicator with value: 46"),
            ("bluetoothd", "Server.Handsfree", #"Sending ring notification to device AA:BB:CC:DD:EE:02"#),
            ("bluetoothd", "Server.Handsfree", #"Sending call setup "incoming" to device AA:BB:CC:DD:EE:02"#),
            ("bluetoothd", "Server.Handsfree", "callPresent: no, callState: 4, callSetup: incoming, heldStatus: none"),
            ("another-process", "Server.Audio", "A2DP LinkQualityReport: ReTx = 99%"),
            ("bluetoothd", "another-category", "Received HF indicator event from device AA:BB:CC:DD:EE:03")
        ]
        let rows = messages.map { ["process": $0.0, "category": $0.1, "eventMessage": $0.2] }
        let broad = NSPredicate(format: #"process == "bluetoothd" AND (category == "Server.Audio" OR category == "Server.Handsfree")"#)
        let narrow = NSPredicate(format: BluetoothLogParser.logPredicate)
        func events(_ filter: NSPredicate) -> [BluetoothLogParser.Event] {
            var parser = BluetoothLogParser()
            return rows.filter { filter.evaluate(with: $0) }.compactMap { parser.parse($0["eventMessage"]!) }
        }
        XCTAssertEqual(events(narrow), events(broad))
        XCTAssertEqual(events(narrow), [.quality(retransmitted: 13.9), .battery(address: "aa:bb:cc:dd:ee:02", percent: 46),
                                        .ring(address: "aa:bb:cc:dd:ee:02"), .ring(address: "aa:bb:cc:dd:ee:02")])
        XCTAssertLessThan(rows.filter { narrow.evaluate(with: $0) }.count, rows.filter { broad.evaluate(with: $0) }.count)
    }

    func testRealLines() {
        var parser = BluetoothLogParser()
        XCTAssertEqual(parser.parse("A2DP LinkQualityReport: Handle = 22 ReTx = 13.9% ( 17 / 122), NAK =    0, NoSync =   17, TxPwr =  8 dBm, RSSI =  -56"),
                       .quality(retransmitted: 13.9))
        XCTAssertNil(parser.parse("Received HF indicator event from device AA:BB:CC:DD:EE:02"))
        XCTAssertEqual(parser.parse("Received battery level HF indicator with value: 46"), .battery(address: "aa:bb:cc:dd:ee:02", percent: 46))
        XCTAssertNil(parser.parse("Received battery level HF indicator with value: 47"), "a value needs its device line first")
        XCTAssertEqual(parser.parse(#"Sending ring notification for call <private> "<private>" to device AA:BB:CC:DD:EE:02"#),
                       .ring(address: "aa:bb:cc:dd:ee:02"))
        XCTAssertEqual(parser.parse(#"Sending call setup "incoming" to device AA:BB:CC:DD:EE:02"#), .ring(address: "aa:bb:cc:dd:ee:02"))
        XCTAssertNil(parser.parse("callPresent: no, callState: 4, callSetup: incoming, heldStatus: none"))
        XCTAssertNil(parser.parse("A2DP LinkQualityReport: Handle = 22 ReTx = n/a"), "changed wording is ignored, not misread")
    }
}
