// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreAudio
import Foundation
import IOKit

/// Where sound goes and comes from, for the Bluetooth audio rows: which device plays, which one listens, and
/// switching either. Driven by Core Audio's own change notices; nothing is polled.
final class AudioRoutes {
    /// The Bluetooth addresses (as `Address.normalize` writes them) of the default output and input, and whether
    /// a Bluetooth output is playing right now.
    struct State: Equatable {
        var output: String?
        var input: String?
        var playing = false
        /// Bluetooth devices whose microphone is running right now, by address, with the app using it when Core Audio
        /// says which; such a device has dropped to call quality.
        var micInUse: [String: String?] = [:]
        /// Bluetooth outputs running at a call link's sample rate rather than a music link's.
        var callQuality: Set<String> = []
    }

    private(set) var state = State()
    var onChange: (() -> Void)?
    /// Every Bluetooth device's "running" and sample-rate notices, so a microphone an app picked itself is seen too.
    private var watchedBluetooth: Set<AudioObjectID> = []
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.update() }

    init() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main, listener)
        }
        update()
    }

    /// With the lid closed the Mac's own microphone hears nothing useful, so the input is left alone.
    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }

    /// Plays through the Bluetooth device at `address`. False if it has no output.
    @discardableResult
    func useOutput(_ address: String) -> Bool {
        guard let device = devices().first(where: { Self.bluetoothAddress($0) == address && Self.hasStreams($0, input: false) }) else { return false }
        return setDefault(kAudioHardwarePropertyDefaultOutputDevice, device)
    }

    /// The microphone the person last had as the input, by UID, among those a speaker's rule may switch back to
    /// (`wired`). Kept in memory only: after a launch it starts as whatever the input is then.
    private var ownInput: String?

    /// Microphones wired to this Mac or built into it, or an aggregate the person made: never a Bluetooth device, an
    /// iPhone's (Continuity), or a virtual one an app installed.
    private static func wired(_ device: AudioObjectID) -> Bool {
        let transports: Set<UInt32> = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt,
                                       kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeAggregate]
        return transports.contains(uint32(device, kAudioDevicePropertyTransportType)) && hasStreams(device, input: true)
    }

    /// Where the input goes back to when the system made a speaker the microphone: the microphone the person had
    /// before if it is still connected, else the Mac's own, else any other wired one. The Mac's own is left out with
    /// the lid closed, since it hears nothing useful then. Nil when there is none, as on a Mac mini with only the speaker.
    func restoreTarget(lidClosed: Bool) -> (device: AudioObjectID, builtIn: Bool)? {
        let isBuiltIn = { (device: AudioObjectID) in Self.uint32(device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn }
        let usable = devices().filter { Self.wired($0) && !(lidClosed && isBuiltIn($0)) }
        let device = usable.first { ownInput != nil && Self.string($0, kAudioDevicePropertyDeviceUID) == ownInput }
            ?? usable.first(where: isBuiltIn)
            // An aggregate the person made only when it is all there is: it may hold the speaker itself.
            ?? usable.first { Self.uint32($0, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeAggregate }
            ?? usable.first
        return device.map { ($0, isBuiltIn($0)) }
    }

    enum Restore { case switched(name: String, builtIn: Bool), nowhere, failed }

    /// Switches the input back (see `restoreTarget`).
    func restoreInput(lidClosed: Bool) -> Restore {
        guard let target = restoreTarget(lidClosed: lidClosed) else { return .nowhere }
        guard setDefault(kAudioHardwarePropertyDefaultInputDevice, target.device) else { return .failed }
        return .switched(name: Self.string(target.device, kAudioObjectPropertyName) ?? "", builtIn: target.builtIn)
    }

    /// The name the Mac's own microphone goes by, for the menu item that switches to it.
    var builtInMicrophoneName: String? { builtInMicrophone.flatMap { Self.string($0, kAudioObjectPropertyName) } }

    private var builtInMicrophone: AudioObjectID? {
        devices().first { Self.uint32($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn && Self.hasStreams($0, input: true) }
    }

    private func update() {
        let output = Self.uint32(system, kAudioHardwarePropertyDefaultOutputDevice)
        let input = Self.uint32(system, kAudioHardwarePropertyDefaultInputDevice)
        if input != 0, Self.wired(input), let uid = Self.string(input, kAudioDevicePropertyDeviceUID) {
            ownInput = uid
        }
        let bluetooth = devices().filter { Self.bluetoothAddress($0) != nil }
        watchBluetooth(Set(bluetooth))
        // Playing matters only for a Bluetooth output (the log is read and the row marked only then), and every Bluetooth
        // device's running state is watched above; other outputs starting and stopping sound wake nothing here.
        var next = State(output: Self.bluetoothAddress(output), input: Self.bluetoothAddress(input),
                         playing: bluetooth.contains(output) && Self.uint32(output, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0)
        var listeners: [AudioObjectID: String]?
        for device in bluetooth {
            guard let address = Self.bluetoothAddress(device) else { continue }
            if Self.hasStreams(device, input: true), Self.running(device, input: true) {
                // Looked up only when a Bluetooth microphone runs, which is rare.
                if listeners == nil { listeners = Self.inputApps() }
                next.micInUse[address] = listeners?[device]
            }
            // A call link runs at 16 kHz (mSBC) or 8 kHz (CVSD); music at 44.1 kHz or more.
            if Self.hasStreams(device, input: false), case let rate = Self.float(device, kAudioDevicePropertyNominalSampleRate), rate > 0, rate < 32000 {
                next.callQuality.insert(address)
            }
        }
        guard next != state else { return }
        state = next
        onChange?()
    }

    private func watchBluetooth(_ devices: Set<AudioObjectID>) {
        guard devices != watchedBluetooth else { return }
        for (set, add) in [(watchedBluetooth.subtracting(devices), false), (devices.subtracting(watchedBluetooth), true)] {
            for device in set {
                for selector in [kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioDevicePropertyNominalSampleRate] {
                    var address = Self.address(selector)
                    if add { AudioObjectAddPropertyListenerBlock(device, &address, .main, listener) }
                    else { AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener) }
                }
            }
        }
        watchedBluetooth = devices
    }

    /// Whether `device`'s input or output side is running, for devices that have both.
    private static func running(_ device: AudioObjectID, input: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0
        }
        return value != 0
    }

    /// The app recording from each device right now, by name, as Core Audio's process objects report it.
    private static func inputApps() -> [AudioObjectID: String] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [:] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [:] }
        var apps: [AudioObjectID: String] = [:]
        for process in processes where uint32(process, kAudioProcessPropertyIsRunningInput) != 0 {
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid)
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? string(process, kAudioProcessPropertyBundleID)
            guard let name else { continue }
            var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeInput,
                                                            mElement: kAudioObjectPropertyElementMain)
            var devicesSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(process, &devicesAddress, 0, nil, &devicesSize) == noErr, devicesSize > 0 else { continue }
            var used = [AudioObjectID](repeating: 0, count: Int(devicesSize) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(process, &devicesAddress, 0, nil, &devicesSize, &used) == noErr else { continue }
            for device in used { apps[device] = name }
        }
        return apps
    }

    private static func float(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double {
        var address = address(selector)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private func devices() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func setDefault(_ selector: AudioObjectPropertySelector, _ device: AudioObjectID) -> Bool {
        var address = Self.address(selector)
        var value = device
        return AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr
    }

    /// A Bluetooth audio device's UID starts with its address, dashed: "AA-BB-CC-DD-EE-02:output".
    static func bluetoothAddress(_ device: AudioObjectID) -> String? {
        guard device != 0, uint32(device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBluetooth,
              let uid = string(device, kAudioDevicePropertyDeviceUID),
              let prefix = uid.split(separator: ":").first, prefix.count == 17 else { return nil }
        return Address.normalize(String(prefix))
    }

    private static func hasStreams(_ device: AudioObjectID, input: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
