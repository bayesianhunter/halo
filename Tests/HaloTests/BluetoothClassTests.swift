// SPDX-License-Identifier: GPL-3.0-only
import IOBluetooth
import XCTest
@testable import HaloCore

/// Which connected Bluetooth devices get a row of their own besides the pointing devices.
final class BluetoothClassTests: XCTestCase {
    func testTheClassesAreIOBluetooths() {
        XCTAssertEqual(BluetoothClass.computer, UInt32(kBluetoothDeviceClassMajorComputer))
        XCTAssertEqual(BluetoothClass.phone, UInt32(kBluetoothDeviceClassMajorPhone))
        XCTAssertEqual(BluetoothClass.audio, UInt32(kBluetoothDeviceClassMajorAudio))
        XCTAssertEqual(BluetoothClass.peripheral, UInt32(kBluetoothDeviceClassMajorPeripheral))
    }

    func testSpeakersAndInputDevicesAreListed() {
        XCTAssertTrue(BluetoothClass.listedAlone(major: BluetoothClass.audio, lowEnergyInput: false, hasBattery: false))
        XCTAssertTrue(BluetoothClass.listedAlone(major: BluetoothClass.peripheral, lowEnergyInput: false, hasBattery: false))
    }

    /// An iPhone linked over Bluetooth Low Energy for Handoff: no class, no charge Halo reads.
    func testAPhoneWithoutAClassIsNotListed() {
        XCTAssertFalse(BluetoothClass.listedAlone(major: 0, lowEnergyInput: false, hasBattery: false))
        XCTAssertFalse(BluetoothClass.listedAlone(major: BluetoothClass.phone, lowEnergyInput: false, hasBattery: false))
        XCTAssertFalse(BluetoothClass.listedAlone(major: BluetoothClass.computer, lowEnergyInput: false, hasBattery: false))
    }

    /// A Bluetooth LE keyboard without a class: listed as the registry's input device, before its charge is read
    /// and also when it reports none.
    func testALowEnergyInputDeviceWithoutAClass() {
        XCTAssertTrue(BluetoothClass.listedAlone(major: 0, lowEnergyInput: true, hasBattery: false))
        XCTAssertTrue(BluetoothClass.listedAlone(major: 0, lowEnergyInput: false, hasBattery: true))
    }
}
