// SPDX-License-Identifier: GPL-3.0-only

/// The major classes of a Bluetooth device's class of device, as IOBluetooth reports them.
public enum BluetoothClass {
    public static let computer: UInt32 = 0x01
    public static let phone: UInt32 = 0x02
    public static let audio: UInt32 = 0x04
    /// Keyboards, mice, trackpads, game controllers.
    public static let peripheral: UInt32 = 0x05

    /// Whether a connected Bluetooth device that is no pointing device Halo knows gets a row of its own. Only with
    /// evidence that it is a peripheral: a speaker or headphones, an input device by its class or because the
    /// registry lists it as a Bluetooth LE input device (`lowEnergyInput`), or a charge it reports. Phones, watches
    /// and computers keep a link for Handoff; connected over Bluetooth Low Energy they may have no class at all (an
    /// iPhone shows only "Services: BLE"), so leaving out the phone and computer classes was not enough to keep them
    /// off the list.
    public static func listedAlone(major: UInt32, lowEnergyInput: Bool, hasBattery: Bool) -> Bool {
        major == audio || major == peripheral || lowEnergyInput || hasBattery
    }
}
