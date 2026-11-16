// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HaloCore

final class BluetoothInventoryTests: XCTestCase {
    let endpoint = BluetoothAudioEndpoint(name: "Audio output", address: "audio-1")
    let speaker = ClassicDevice(name: "Audio output", address: "audio-1", symbol: "hifispeaker.fill",
                                rssi: -45, audio: true, speaker: true, levels: ["single": 75], major: BluetoothClass.audio)

    func testAnEnumerationFailureKeepsOnlyLiveAudioAndItsKnownClassification() {
        var inventory = BluetoothInventory()
        XCTAssertEqual(inventory.update(classic: [speaker], audio: [endpoint]), [speaker])
        let fallback = inventory.update(classic: [], audio: [endpoint])
        XCTAssertEqual(fallback.count, 1)
        XCTAssertTrue(fallback[0].speaker)
        XCTAssertTrue(fallback[0].audio)
        XCTAssertEqual(fallback[0].symbol, "hifispeaker.fill")
        XCTAssertNil(fallback[0].rssi, "a cached signal is not a current reading")
        XCTAssertTrue(fallback[0].levels.isEmpty, "cached battery parts must not pass for fresh readings")
        XCTAssertTrue(inventory.update(classic: [], audio: []).isEmpty, "cache must not resurrect a disconnected speaker")
    }

    func testUnknownAudioIsVisibleButNeverGuessedToBeASpeaker() {
        var inventory = BluetoothInventory()
        let fallback = inventory.update(classic: [], audio: [.init(name: "Speaker in its name", address: "unknown")])
        XCTAssertEqual(fallback.count, 1)
        XCTAssertTrue(fallback[0].audio)
        XCTAssertFalse(fallback[0].speaker)
        XCTAssertEqual(fallback[0].symbol, "headphones")
    }

    func testTheTwoSourcesDoNotDuplicateARowAndRecoveryReplacesTheFallback() {
        var inventory = BluetoothInventory()
        let unknown = ClassicDevice(name: "Audio output", address: "audio-1", symbol: "dot.radiowaves.left.and.right", rssi: nil)
        XCTAssertEqual(inventory.update(classic: [unknown], audio: [endpoint]).count, 1)
        XCTAssertEqual(inventory.update(classic: [speaker], audio: [endpoint, endpoint]), [speaker])
    }
}
