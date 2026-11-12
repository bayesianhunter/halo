// SPDX-License-Identifier: GPL-3.0-only
import CoreBluetooth
import HaloCore
import HaloHID

/// Reads the standard Bluetooth LE Battery Service (0x180F, level 0x2A19) of connected input devices (mice,
/// keyboards), so any compliant one reports its charge without vendor-specific code.
final class BLEBatteries: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let hidService = CBUUID(string: "1812")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private(set) var levels: [UUID: Battery] = [:]
    /// Last read signal per connected peripheral name, in dBm.
    private(set) var signals: [String: Int] = [:]
    var onChange: (() -> Void)?
    var onSignal: ((String, Int) -> Void)?

    /// Asks each connected peripheral for its current signal; answers arrive through `onSignal`.
    func readSignals() {
        for peripheral in peripherals.values where peripheral.state == .connected { peripheral.readRSSI() }
    }

    /// The first call creates the manager, which asks for Bluetooth permission once.
    func refresh() {
        guard let central else {
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        guard central.state == .poweredOn else { return }
        // Only input devices. Asked by service, the system also hands over a phone, a watch or another Mac it is
        // connected to for Continuity (seen: a row for an Apple Watch came and went within a second while the pointer
        // was on the other Mac); asked for HID alone it hands over nothing (measured: no reading for a Bluetooth LE
        // mouse). Core Bluetooth knows a peripheral only by name, so the name must be one of the Bluetooth LE input
        // devices the registry lists. Assumed, not yet seen: a Bluetooth LE device the person renamed keeps its name
        // in the registry (classic Apple ones there have an empty one), or its charge would no longer show.
        let inputs = HaloHID.lowEnergyInputNames()
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.hidService, Self.batteryService])
            .filter { peripheral in peripheral.name.map(inputs.contains) ?? false }
        let ids = Set(connected.map(\.identifier))
        // One that dropped out of the list (or whose name the registry no longer lists) is let go, so its
        // battery notifications stop rather than bring its row back.
        for (id, dropped) in peripherals where !ids.contains(id) { central.cancelPeripheralConnection(dropped) }
        peripherals = peripherals.filter { ids.contains($0.key) }
        let names = Set(connected.compactMap(\.name))
        signals = signals.filter { names.contains($0.key) }
        let before = levels
        levels = levels.filter { ids.contains($0.key) }
        for peripheral in connected {
            // A peripheral we lost (sleep, Bluetooth restart) is connected again once the system has it back.
            if peripherals[peripheral.identifier] == nil || peripheral.state == .disconnected {
                peripherals[peripheral.identifier] = peripheral
                peripheral.delegate = self
                central.connect(peripheral)
            } else if let level = levelCharacteristic(of: peripheral) {
                // One that pushes its changes is already current; only the others are asked.
                if !level.isNotifying { peripheral.readValue(for: level) }
            } else if peripheral.state == .connected {
                peripheral.discoverServices([Self.batteryService])
            }
        }
        if levels != before { onChange?() }
    }

    private func levelCharacteristic(of peripheral: CBPeripheral) -> CBCharacteristic? {
        peripheral.services?.first { $0.uuid == Self.batteryService }?
            .characteristics?.first { $0.uuid == Self.batteryLevel }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            refresh()
        } else {
            // With Bluetooth off every reading is stale; start over when it comes back.
            peripherals = [:]
            signals = [:]
            if !levels.isEmpty { levels = [:]; onChange?() }
        }
    }

    /// Gone (switched off, out of range, disconnected by the person): its reading no longer describes anything. It is
    /// not connected again from here, which could undo a disconnect the person chose; once the system has it back,
    /// the next `refresh` finds it as it found it the first time.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        peripherals.removeValue(forKey: peripheral.identifier)
        if levels.removeValue(forKey: peripheral.identifier) != nil { onChange?() }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peripherals.removeValue(forKey: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.batteryService {
            peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for level in service.characteristics ?? [] where level.uuid == Self.batteryLevel {
            peripheral.readValue(for: level)
            // Most devices push changes, so no polling is needed after the first read.
            if level.properties.contains(.notify) { peripheral.setNotifyValue(true, for: level) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, let name = peripheral.name, RSSI.intValue < 0 else { return }
        signals[name] = RSSI.intValue
        onSignal?(name, RSSI.intValue)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.batteryLevel, let byte = characteristic.value?.first, byte <= 100,
              peripherals[peripheral.identifier] != nil else { return }
        let battery = Battery(name: peripheral.name ?? L("Bluetooth Device"), serial: "", percent: Int(byte))
        guard levels[peripheral.identifier] != battery else { return }
        levels[peripheral.identifier] = battery
        onChange?()
    }
}
