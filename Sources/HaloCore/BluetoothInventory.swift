// SPDX-License-Identifier: GPL-3.0-only

/// The metadata Bluetooth reports for a connected peripheral.
public struct ClassicDevice: Equatable {
    public let name: String
    public let address: String
    public let symbol: String
    public let rssi: Int?
    public var audio: Bool
    public var speaker: Bool
    public var levels: [String: Int]
    public var major: UInt32

    public init(name: String, address: String, symbol: String, rssi: Int?, audio: Bool = false,
                speaker: Bool = false, levels: [String: Int] = [:], major: UInt32 = 0) {
        self.name = name; self.address = address; self.symbol = symbol; self.rssi = rssi
        self.audio = audio; self.speaker = speaker; self.levels = levels; self.major = major
    }
}

/// An alive Bluetooth output reported by Core Audio, independent of IOBluetooth's device objects.
public struct BluetoothAudioEndpoint: Equatable {
    public let name: String
    public let address: String
    public init(name: String, address: String) { self.name = name; self.address = address }
}

/// Cache classification, never presence or readings. Core Audio can keep an audio device visible when
/// IOBluetooth cannot create its device object; a device absent from both live lists never comes back from cache.
public struct BluetoothInventory {
    private var knownAudio: [String: ClassicDevice] = [:]
    public init() {}

    public mutating func update(classic: [ClassicDevice], audio: [BluetoothAudioEndpoint]) -> [ClassicDevice] {
        var devices: [String: ClassicDevice] = [:]
        for device in classic where !device.address.isEmpty {
            devices[device.address] = device
            if device.audio { knownAudio[device.address] = device }
        }
        for endpoint in audio where !endpoint.address.isEmpty {
            if devices[endpoint.address]?.audio == true { continue }
            let known = knownAudio[endpoint.address]
            // A name is not evidence that a device is a speaker. Unknown audio devices get no speaker-mic rule.
            devices[endpoint.address] = ClassicDevice(name: endpoint.name, address: endpoint.address,
                symbol: known?.symbol ?? "headphones", rssi: devices[endpoint.address]?.rssi,
                audio: true, speaker: known?.speaker ?? false, major: BluetoothClass.audio)
        }
        return devices.values.sorted { $0.address < $1.address }
    }
}
