// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

/// What Halo needs from the HID layer: which device sent a scroll, the scrolling devices and peripheral charge,
/// and reversing a scroll's vertical direction.
///
/// Knowing the sender takes four functions the system does not publish; they are looked up by name once, and
/// without them Halo leaves every event alone. Everything else uses the public HID event-system client and the
/// I/O Registry.
public enum HaloHID {
    private typealias CopyEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias Sender = @convention(c) (CFTypeRef) -> UInt64
    private typealias GetFloat = @convention(c) (CFTypeRef, UInt32) -> Double
    private typealias SetFloat = @convention(c) (CFTypeRef, UInt32, Double) -> Void

    private struct Symbols {
        let copyEvent: CopyEvent
        let sender: Sender
        let getFloat: GetFloat
        let setFloat: SetFloat
    }

    private static let symbols: Symbols? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let copyEvent = load("CGEventCopyIOHIDEvent", as: CopyEvent.self),
              let sender = load("IOHIDEventGetSenderID", as: Sender.self),
              let getFloat = load("IOHIDEventGetFloatValue", as: GetFloat.self),
              let setFloat = load("IOHIDEventSetFloatValue", as: SetFloat.self) else { return nil }
        return Symbols(copyEvent: copyEvent, sender: sender, getFloat: getFloat, setFloat: setFloat)
    }()

    /// Whether the sender of an event can be known on this system; without it nothing is ever reversed.
    public static var available: Bool { symbols != nil }

    /// The registry ID of the HID service that produced the event, 0 for synthetic or unknown events.
    public static func sender(of event: CGEvent) -> UInt64 {
        guard let symbols, let hid = symbols.copyEvent(event)?.takeRetainedValue() else { return 0 }
        return symbols.sender(hid)
    }

    /// Flips the vertical scroll in every form the event carries; horizontal, phases and momentum are untouched.
    public static func reverseVertical(_ event: CGEvent) -> Bool { scaleVertical(event, by: -1) }

    /// Multiplies the vertical scroll in every form the event carries by `factor`: -1 reverses, 2 doubles the
    /// speed, -2 does both. Horizontal, phases and momentum are untouched.
    ///
    /// Measured on synthetic events (see the tests): writing the line delta makes the system recompute the
    /// fixed-point delta (×1) and the pixel delta (×8), discarding the device's own pixel value. So the line
    /// delta is written first and the exact fixed-point and pixel values are written back after it. The device's
    /// original report rides along inside the event as well; it is scaled too, so nothing downstream sees the
    /// two disagree. Whole-number deltas are rounded, but a step never rounds away to nothing. Returns false,
    /// changing nothing, when a value cannot be scaled.
    public static func scaleVertical(_ event: CGEvent, by factor: Double) -> Bool {
        guard let symbols, factor.isFinite, factor != 0 else { return false }
        let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let raw = event.getDoubleValueField(.scrollWheelEventRawDeltaAxis1)
        let accelerated = event.getDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1)
        let newFixed = fixed * factor, newRaw = raw * factor, newAccelerated = accelerated * factor
        guard let newLine = scaled(line, factor), let newPoint = scaled(point, factor),
              fixed.isFinite, raw.isFinite, accelerated.isFinite,
              newFixed.isFinite, newRaw.isFinite, newAccelerated.isFinite else { return false }
        let hid = symbols.copyEvent(event)?.takeRetainedValue()
        let original = hid.map { symbols.getFloat($0, scrollY) }
        if let original, !original.isFinite || !(original * factor).isFinite { return false }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: newLine)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: newFixed)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: newPoint)
        // iPhone Mirroring also consumes these values: a physical A/B/A test confirmed that reversing only
        // the ordinary deltas leaves its wheel direction unchanged. Leave zero values untouched so events
        // without these representations do not gain them just to store zero.
        if raw != 0 { event.setDoubleValueField(.scrollWheelEventRawDeltaAxis1, value: newRaw) }
        if accelerated != 0 { event.setDoubleValueField(.scrollWheelEventAcceleratedDeltaAxis1, value: newAccelerated) }
        if let hid { scaleEmbedded(hid, by: factor) }
        return true
    }

    /// A whole-number delta times `factor`, at least one step if it was a step at all; nil if out of range.
    static func scaled(_ value: Int64, _ factor: Double) -> Int64? {
        guard value != 0 else { return 0 }
        let product = Double(value) * factor
        guard abs(product) < 1e15 else { return nil }
        let rounded = product.rounded()
        return rounded == 0 ? (product > 0 ? 1 : -1) : Int64(rounded)
    }

    /// The scroll event's vertical value: event type kIOHIDEventTypeScroll (6) in the high 16 bits, axis 1 below
    /// (IOHIDEventTypes.h in Apple's open-source IOHIDFamily). Reading or writing it finds the scroll event whether it
    /// is the event itself or nested inside another, such as the translation a trackpad gesture arrives in.
    static let scrollY: UInt32 = (6 << 16) | 1

    /// Multiplies the scroll value inside a HID event, leaving any enclosing event's own values alone.
    @discardableResult
    static func scaleEmbedded(_ hid: CFTypeRef, by factor: Double) -> Bool {
        guard let symbols else { return false }
        let value = symbols.getFloat(hid, scrollY)
        guard value.isFinite else { return false }
        symbols.setFloat(hid, scrollY, value * factor)
        return true
    }

    @discardableResult
    static func reverseEmbedded(_ hid: CFTypeRef) -> Bool { scaleEmbedded(hid, by: -1) }

    /// Every HID service that scrolls, local or mirrored from another Mac by Universal Control.
    /// Keys: sender, local, touchpad and the device's own Product, Transport, VendorID, ProductID, SerialNumber,
    /// HIDScrollAccelerationType and Built-In.
    public static func devices() -> [[String: Any]] { autoreleasepool { enumerateDevices() } }

    private static func enumerateDevices() -> [[String: Any]] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.compactMap(info)
    }

    private static func info(_ service: IOHIDServiceClient) -> [String: Any]? {
        guard let sender = IOHIDServiceClientGetRegistryID(service) as? NSNumber else { return nil }
        // Services Universal Control creates live only in the event system; local ones also have a registry entry.
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(sender.uint64Value))
        defer { if entry != 0 { IOObjectRelease(entry) } }
        var info: [String: Any] = ["sender": sender, "local": entry != 0]
        for key in ["Product", "Transport", "VendorID", "ProductID", "SerialNumber", "HIDScrollAccelerationType", "Built-In"] {
            var value = IOHIDServiceClientCopyProperty(service, key as CFString)
            if value == nil, entry != 0 { value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            if let value = value as? String { info[key] = value } else if let value = value as? NSNumber { info[key] = value }
        }
        // A device says what it is: a touch pad (digitizer page 0x0D, usage 0x05) or a mouse (generic desktop 1, 2).
        let touchpad = IOHIDServiceClientConformsTo(service, 0x0D, 0x05) != 0
        let acceleration = info["HIDScrollAccelerationType"] as? String
        info["touchpad"] = touchpad || acceleration == "HIDTrackpadScrollAcceleration"
        let scrolls = touchpad || IOHIDServiceClientConformsTo(service, 1, 2) != 0
            || acceleration == "HIDTrackpadScrollAcceleration" || acceleration == "HIDMouseScrollAcceleration"
        return scrolls ? info : nil
    }

    private typealias ServiceForID = @convention(c) (IOHIDEventSystemClient, UInt64) -> Unmanaged<IOHIDServiceClient>?
    private static let serviceForID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDEventSystemClientCopyServiceForRegistryID")
        .map { unsafeBitCast($0, to: ServiceForID.self) }
    /// Kept for quick lookups: connecting a client costs milliseconds, a lookup through it microseconds.
    private static let lookupClient = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

    /// Connects the lookup client ahead of time, so the first scroll that needs it does not pay for that.
    public static func prepareLookup() { _ = lookupClient }

    /// One scrolling device by the sender ID its scrolls carry, with the same keys as `devices()`, in microseconds:
    /// cheap enough for the event tap. A Bluetooth mouse back from sleep, or a device Universal Control brings over,
    /// arrives under a new ID, and its first scroll should not wait for a full listing. Nil if it cannot be found.
    public static func device(sender: UInt64) -> [String: Any]? {
        guard sender != 0, let serviceForID else { return nil }
        // A service newer than the kept client may be missing from it; a fresh client (about 2 ms) sees it.
        guard let service = serviceForID(lookupClient, sender)?.takeRetainedValue()
                ?? serviceForID(IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault), sender)?.takeRetainedValue() else { return nil }
        return info(service)
    }

    /// Names of the input devices connected over Bluetooth LE (mice, keyboards), from the registry, so a battery read
    /// over Bluetooth LE can be told to belong to one: a phone, a watch or another Mac connected for Continuity offers
    /// the same battery service but is no input device here.
    public static func lowEnergyInputNames() -> Set<String> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var names = Set<String>()
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryCreateCFProperty(entry, "Transport" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String == "Bluetooth Low Energy",
                  let name = IORegistryEntryCreateCFProperty(entry, "Product" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String, !name.isEmpty else { continue }
            names.insert(name)
        }
        return names
    }

    /// Peripherals reporting BatteryPercent (Apple Bluetooth devices): percent, charging, Product, SerialNumber,
    /// VendorID and ProductID.
    public static func batteries() -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let percent = IORegistryEntryCreateCFProperty(entry, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber else { continue }
            var info: [String: Any] = ["percent": percent]
            // Read off a Magic Keyboard: 0 on battery, 3 while charging on its cable. Bit 0 is taken as charging.
            if let flags = IORegistryEntryCreateCFProperty(entry, "BatteryStatusFlags" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                info["charging"] = flags.intValue & 1 != 0
            }
            for key in ["Product", "SerialNumber", "VendorID", "ProductID"] { if let value = searchUp(entry, key) { info[key] = value } }
            result.append(info)
        }
        return result
    }

    /// The battery service has an empty Product; the name and serial sit on its parents.
    private static func searchUp(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        var current = entry
        IOObjectRetain(current)
        for _ in 0..<8 where current != 0 {
            let value = IORegistryEntryCreateCFProperty(current, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            if let text = value as? String, !text.isEmpty { IOObjectRelease(current); return text }
            if let number = value as? NSNumber { IOObjectRelease(current); return number }
            var parent: io_registry_entry_t = 0
            let found = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS
            IOObjectRelease(current)
            current = found ? parent : 0
        }
        if current != 0 { IOObjectRelease(current) }
        return nil
    }
}

/// HID services as they come and go, told by the event system the moment it happens, so nothing is listed on a timer
/// to notice. The callbacks are not published by the system; they are looked up by name, and without them `start`
/// returns false and Halo notices changes as before, on its next listing.
///
/// Lifetime: the callbacks receive this object unretained, and the private API offers no way to unregister them, so a
/// started watch must live as long as the process (Halo keeps one for the app's whole run). Releasing it after
/// `start` would leave the event system calling into freed memory.
public final class ServiceWatch {
    public struct Service: Equatable {
        public let sender: UInt64
        public let product: String
        public let transport: String
        /// A device another Mac lends this one through Universal Control ("V-" names), not its own helper.
        public var lent: Bool { product.hasPrefix("V-") && transport != "UniversalControl" }
    }

    public var onAdded: ((Service) -> Void)?
    public var onRemoved: ((Service) -> Void)?

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, IOHIDServiceClient) -> Void
    private typealias RegisterMatching = @convention(c) (IOHIDEventSystemClient, Callback, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias RegisterRemoval = @convention(c) (IOHIDServiceClient, Callback, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias Schedule = @convention(c) (IOHIDEventSystemClient, DispatchQueue) -> Void

    private struct Symbols {
        let registerMatching: RegisterMatching
        let registerRemoval: RegisterRemoval
        let schedule: Schedule
    }

    private static let symbols: Symbols? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let matching = dlsym(handle, "IOHIDEventSystemClientRegisterDeviceMatchingCallback"),
              let removal = dlsym(handle, "IOHIDServiceClientRegisterRemovalCallback"),
              let schedule = dlsym(handle, "IOHIDEventSystemClientScheduleWithDispatchQueue") else { return nil }
        return Symbols(registerMatching: unsafeBitCast(matching, to: RegisterMatching.self),
                       registerRemoval: unsafeBitCast(removal, to: RegisterRemoval.self),
                       schedule: unsafeBitCast(schedule, to: Schedule.self))
    }()

    private var client: IOHIDEventSystemClient?
    /// Each watched service as it was described when it came: a removed one may no longer answer for its properties.
    private var known: [UInt64: Service] = [:]

    /// Whether any device the other Mac lends this one is here now.
    public var anyLent: Bool { known.values.contains(where: \.lent) }

    public init() {}

    /// Starts watching, with callbacks on the main queue. False when the system does not offer the callbacks.
    @discardableResult
    public func start() -> Bool {
        guard client == nil else { return true }
        guard let symbols = Self.symbols else { return false }
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        self.client = client
        let target = Unmanaged.passUnretained(self).toOpaque()
        symbols.registerMatching(client, { target, _, service in
            guard let target else { return }
            let watch = Unmanaged<ServiceWatch>.fromOpaque(target).takeUnretainedValue()
            watch.onAdded?(watch.watchRemoval(of: service))
        }, target, nil)
        for service in IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? [] { watchRemoval(of: service) }
        symbols.schedule(client, .main)
        return true
    }

    @discardableResult
    private func watchRemoval(of service: IOHIDServiceClient) -> Service {
        let described = Self.describe(service)
        known[described.sender] = described
        Self.symbols?.registerRemoval(service, { target, _, service in
            guard let target else { return }
            let watch = Unmanaged<ServiceWatch>.fromOpaque(target).takeUnretainedValue()
            let sender = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
            let gone = watch.known.removeValue(forKey: sender) ?? ServiceWatch.describe(service)
            watch.onRemoved?(gone)
        }, Unmanaged.passUnretained(self).toOpaque(), nil)
        return described
    }

    private static func describe(_ service: IOHIDServiceClient) -> Service {
        Service(sender: (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0,
                product: IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String ?? "",
                transport: IOHIDServiceClientCopyProperty(service, "Transport" as CFString) as? String ?? "")
    }
}

/// Peripheral batteries as the system tells of them: each battery service (`batteries()` reads the same ones) sends
/// its clients a message when its state changes, a cable going in or out included, and new services are announced as
/// they appear. Measured: a Magic Trackpad's cable going in and out each sent one message within the second, with
/// `BatteryStatusFlags` already changed; a Magic Keyboard sent one with each new level, every one with the level or
/// charging already changed (a few came 2–5 points after the last, either as the keyboard reported them or with
/// messages missed between).
public final class BatteryWatch {
    /// Something about a battery changed, or one came or went: read `batteries()` again. On the main queue.
    public var onChange: (() -> Void)?
    private var port: IONotificationPortRef?
    private var matched: io_iterator_t = 0
    private var terminated: io_iterator_t = 0
    /// Each watched service's interest notification, by registry ID, released when the service goes.
    private var interests: [UInt64: io_object_t] = [:]

    public init() {}

    deinit { stop() }

    /// Starts watching; true when the notifications are in place.
    @discardableResult
    public func start() -> Bool {
        guard port == nil else { return true }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let target = Unmanaged.passUnretained(self).toOpaque()
        let matching = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("AppleDeviceManagementHIDEventService"), { target, iterator in
            guard let target else { return }
            Unmanaged<BatteryWatch>.fromOpaque(target).takeUnretainedValue().came(iterator, announce: true)
        }, target, &matched)
        let termination = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("AppleDeviceManagementHIDEventService"), { target, iterator in
            guard let target else { return }
            Unmanaged<BatteryWatch>.fromOpaque(target).takeUnretainedValue().went(iterator, announce: true)
        }, target, &terminated)
        guard matching == KERN_SUCCESS, termination == KERN_SUCCESS else { stop(); return false }
        // Draining arms each notification; the services already there are watched without being called news.
        came(matched, announce: false)
        went(terminated, announce: false)
        return true
    }

    public func stop() {
        interests.values.forEach { IOObjectRelease($0) }
        interests = [:]
        for iterator in [matched, terminated] where iterator != 0 { IOObjectRelease(iterator) }
        matched = 0
        terminated = 0
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    private static func id(_ service: io_service_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        return id
    }

    private func came(_ iterator: io_iterator_t, announce: Bool) {
        var any = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            any = true
            watch(service)
            IOObjectRelease(service)
        }
        if announce, any { onChange?() }
    }

    private func went(_ iterator: io_iterator_t, announce: Bool) {
        var any = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            any = true
            if let notification = interests.removeValue(forKey: Self.id(service)) { IOObjectRelease(notification) }
            IOObjectRelease(service)
        }
        if announce, any { onChange?() }
    }

    private func watch(_ service: io_service_t) {
        guard let port else { return }
        let id = Self.id(service)
        guard interests[id] == nil else { return }
        var notification: io_object_t = 0
        let target = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { target, _, _, _ in
            guard let target else { return }
            Unmanaged<BatteryWatch>.fromOpaque(target).takeUnretainedValue().onChange?()
        }, target, &notification)
        if result == KERN_SUCCESS { interests[id] = notification }
    }
}
