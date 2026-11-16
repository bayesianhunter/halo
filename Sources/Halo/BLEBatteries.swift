// SPDX-License-Identifier: GPL-3.0-only
import CoreBluetooth
import HaloCore
import HaloHID
import OSLog

/// Reads the standard Bluetooth LE Battery Service of connected input devices. Logitech's advertised HID++
/// service supplies the charging state that its standard percentage characteristic does not include. Only battery
/// queries and change subscriptions: no scanning for new devices or device configuration, and no charging poll timer.
final class BLEBatteries: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let batteryProbe = Logger(subsystem: "com.liuzhekan.Halo", category: "BatteryProbe")
    static let hidService = CBUUID(string: "1812")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    // The connected device advertises this Logitech HID++ service; it needs only the existing Bluetooth grant.
    static let logitechService = CBUUID(string: "00010000-0000-1000-8000-011F2000046D")
    static let logitechReport = CBUUID(string: "00010001-0000-1000-8000-011F2000046D")

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var logitech: [UUID: HIDPPBattery] = [:]
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
        logitech = logitech.filter { ids.contains($0.key) }
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
                peripheral.discoverServices([Self.batteryService, Self.logitechService])
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
            logitech = [:]
            signals = [:]
            if !levels.isEmpty { levels = [:]; onChange?() }
        }
    }

    /// Gone (switched off, out of range, disconnected by the person): its reading no longer describes anything. It is
    /// not connected again from here, which could undo a disconnect the person chose; once the system has it back,
    /// the next `refresh` finds it as it found it the first time.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        peripherals.removeValue(forKey: peripheral.identifier)
        logitech.removeValue(forKey: peripheral.identifier)
        if levels.removeValue(forKey: peripheral.identifier) != nil { onChange?() }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peripherals.removeValue(forKey: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService, Self.logitechService])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            if service.uuid == Self.batteryService {
                peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
            } else if service.uuid == Self.logitechService {
                peripheral.discoverCharacteristics([Self.logitechReport], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if service.uuid == Self.logitechService,
           let report = service.characteristics?.first(where: { $0.uuid == Self.logitechReport }),
           report.properties.contains(.notify), report.properties.contains(.write) {
            logitech[peripheral.identifier] = HIDPPBattery()
            peripheral.setNotifyValue(true, for: report)
        }
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

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.logitechReport else { return }
        guard characteristic.isNotifying, error == nil else {
            // Losing the status subscription must not leave an old "charging" flag on the standard reading.
            logitech.removeValue(forKey: peripheral.identifier)
            if let percent = levels[peripheral.identifier]?.percent, peripherals[peripheral.identifier] != nil {
                updateLevel(peripheral, percent: percent)
            }
            return
        }
        peripheral.writeValue(HIDPPBattery.discoveryGATT, for: characteristic, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Self.logitechReport, let error {
            batteryProbe.error("Battery query failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, peripherals[peripheral.identifier] != nil else { return }
        if characteristic.uuid == Self.logitechReport, let data = characteristic.value,
           var reader = logitech[peripheral.identifier] {
            let update = reader.receiveGATT(data)
            logitech[peripheral.identifier] = reader
            if let request = update.request {
                batteryProbe.info("Battery query: feature \(reader.featureIndex ?? 0), function \((request.dropFirst().first ?? 0) >> 4)")
                peripheral.writeValue(request, for: characteristic, type: .withResponse)
            }
            if let capability = update.capability {
                batteryProbe.info("Battery capability: levels \(capability.levels), flags \(capability.flags), coarse \(capability.coarse)")
            }
            if let reading = update.reading {
                batteryProbe.info("Battery status: \(reading.status), level: \(reading.percent ?? -1)")
                if let percent = reading.percent ?? levels[peripheral.identifier]?.percent {
                    updateLevel(peripheral, percent: percent)
                }
            }
            return
        }
        guard characteristic.uuid == Self.batteryLevel, let byte = characteristic.value?.first, byte <= 100,
              peripherals[peripheral.identifier] != nil else { return }
        let percent = logitech[peripheral.identifier]?.percent(forStandardReading: Int(byte)) ?? Int(byte)
        updateLevel(peripheral, percent: percent)
    }

    private func updateLevel(_ peripheral: CBPeripheral, percent: Int) {
        let battery = Battery(name: peripheral.name ?? L("Bluetooth Device"), serial: "", percent: percent,
                              charging: logitech[peripheral.identifier]?.reading?.charging ?? false,
                              chargedOnCable: logitech[peripheral.identifier]?.reading?.chargedOnCable ?? false)
        guard levels[peripheral.identifier] != battery else { return }
        levels[peripheral.identifier] = battery
        onChange?()
    }
}
