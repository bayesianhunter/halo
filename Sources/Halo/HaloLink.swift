// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CryptoKit
import Foundation
import HaloCore
import Network
import Security
import SystemConfiguration

/// The paired Mac as remembered on disk; its key is kept in the Keychain, never here.
struct LinkPeer: Codable, Equatable {
    var id: String
    var name: String
    var lastSeen: Date?
    /// Its last snapshot, so the menu can show what it had while it is offline.
    var snapshot: LinkSnapshot?
}

/// The long-term key for each paired Mac: one generic password per peer, account = the peer's ID.
struct LinkKeychain {
    let service: String

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    enum Lookup { case found(Data), missing, declined, unavailable(OSStatus) }

    /// Only a definite "no such item" counts as missing. A prompt the person declined is `declined`; anything else
    /// (a locked keychain) is `unavailable` and may work later.
    func read(_ account: String) -> Lookup {
        var result: CFTypeRef?
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return (result as? Data).map(Lookup.found) ?? .unavailable(status)
        case errSecItemNotFound: return .missing
        case errSecUserCanceled, errSecAuthFailed: return .declined
        default: return .unavailable(status)
        }
    }

    func write(_ key: Data, account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = key
        item[kSecAttrLabel as String] = service
        // Honoured by the data-protection keychain only; harmless for the login keychain this build uses.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Halo link: read-only sharing of the device list with one other Mac of the person's on the same network.
///
/// Unpaired, it neither advertises nor browses. While pairing, both Macs advertise and browse for each other, the one
/// with the lower ID connects, and the two run a `PairingExchange` over plain TCP: the digits the people compare are
/// what secures it, not the connection. Paired, both advertise `_halo._tcp` and browse for each
/// other, and only TLS-PSK connections keyed by the long-term key get through: nothing is read before the handshake.
/// Each side then sends a snapshot whenever its own changes. What it receives reaches this Mac's rules only through the
/// "match device settings" switch, and its clipboard only through "clipboard follows you"; never the event tap.
///
/// When the network shows the other Mac but will not carry a connection to it (a router or access point dropping TCP
/// between the two), the link checks why and falls back to a direct Wi-Fi link between the Macs (AWDL, as AirDrop
/// uses). That link makes the Wi-Fi radio share its time, so it is used only while the network fails: every ten
/// minutes the network is tried again, and with no connection at all after ten minutes the fallback ends.
final class HaloLink {
    static let serviceType = "_halo._tcp"
    private static let linkIdentity = "halo-link"

    enum Pairing: Equatable {
        case idle
        /// Looking for another Mac that is pairing too.
        case searching
        /// Both Macs show `code`; `confirmed` once the person here said it matches, then waiting for the other Mac.
        case comparing(code: String, with: String, confirmed: Bool)
    }

    let id: String
    let computerName: String
    private(set) var peer: LinkPeer?
    private(set) var pairing: Pairing = .idle
    /// How the last pairing attempt ended, for the General page; cleared by the next one.
    private(set) var notice: String?
    var online: Bool { session?.verified == true }

    /// How the live connection runs: over the local network, or straight between the two Macs.
    enum Path { case network, direct }
    private(set) var path: Path?
    /// Peer-to-peer is allowed: only after the network failed to carry a connection to a peer it shows.
    private(set) var direct = false
    /// The latest check measured here, and the latest one the other Mac sent.
    private(set) var lastCheck: LinkCheck?
    private(set) var peerCheck: LinkCheck?
    private(set) var checking = false
    /// Both views together, but only when they were measured around the same time; a stale one says nothing now.
    var verdict: LinkVerdict? { lastCheck.map { LinkVerdict.of($0, peer: currentPeerCheck) } }
    var currentPeerCheck: LinkCheck? {
        guard let own = lastCheck, let peerCheck, abs(peerCheck.at.timeIntervalSince(own.at)) < Self.directWindow else { return nil }
        return peerCheck
    }

    /// Builds this Mac's snapshot; called only while the peer is connected.
    var snapshot: (() -> LinkSnapshot)?
    /// Clipboard messages from the paired Mac, over the verified connection only.
    var onClip: ((LinkMessage) -> Void)?
    /// What the other Mac says about Universal Control between the two; see `StallWatch`.
    var onHandoff: ((LinkHandoff) -> Void)?
    var onChange: (() -> Void)?
    /// After the pairing is gone, whichever Mac ended it: what belonged to it goes too.
    var onUnpaired: (() -> Void)?
    /// Once both Macs have confirmed the digits and this one stored the key.
    var onPaired: (() -> Void)?
    var log: ((String) -> Void)?

    private let stateFile: URL
    private let keychain: LinkKeychain
    private let loopbackOnly: Bool
    private var key: Data?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peerEndpoint: NWEndpoint?
    private var session: LinkConnection?
    private var pending: [LinkConnection] = []
    private var outbox = LinkOutbox()
    private var sendWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var retryDelay: TimeInterval = 1
    private var pairingEnd: DispatchWorkItem?
    /// One exchange per pairing connection while searching: a stranger's connection cannot disturb the right one.
    private var exchanges: [ObjectIdentifier: PairingExchange] = [:]
    /// The exchange whose digits are shown. `stored`: the key is in the keychain, since the person here confirmed;
    /// it is taken out again unless the other Mac confirms too. `peerConfirmed`: the other Mac's proof arrived.
    private var comparing: (connection: LinkConnection, exchange: PairingExchange, stored: Bool, peerConfirmed: Bool)?
    /// Macs advertising a pairing, by ID, with where they are and when this Mac first saw them.
    private var pairingServices: [String: (endpoint: NWEndpoint, since: Date)] = [:]
    private var pairingDialWork: DispatchWorkItem?
    /// The one connection this attempt has sent this Mac's half on. One half per attempt: a stranger who could have
    /// this Mac reveal on many connections could keep the one whose digits happen to match the other Mac's.
    private var revealedOn: LinkConnection?
    private var revealDeadline: DispatchWorkItem?
    /// The peer as found on the local network (not over AWDL), and where its probes go.
    private var networkEndpoint: NWEndpoint?
    private var peerHost: String?
    private var peerPort: UInt16?
    private var dialTimeouts = 0
    private var handshakeFailures = 0
    /// Past this many failed handshakes with no session the other Mac most likely no longer has this pairing (it
    /// paired again, with this Mac or another, while this one was away): retries slow to `slowRetry`.
    static let handshakeGiveUp = 3
    static let slowRetry: TimeInterval = 1800
    private var slowRetryLogged = false
    /// When the first of the current run of dial timeouts came: an earlier check says nothing about this run.
    private var timeoutsSince: Date?
    /// Said once per run, however often such connections come.
    private var weakHandshakeLogged = false
    /// Connections refused for lacking forward secrecy since the last session, for the link check.
    private var weakRefusals = 0
    private var inboundStalls: [Date] = []
    /// Kinds of message from the paired Mac already logged as unreadable this run.
    private var unreadableLogged: Set<String> = []
    private var snapshotFailureLogged = false
    /// Waiting for the keychain to become readable (locked at login); see `loadKey`.
    private var keychainObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var keychainRetry: DispatchWorkItem?
    private var keychainDelay: TimeInterval = 30
    /// The person declined the keychain's prompt for the pairing key this run; the pairing is kept but cannot connect.
    private(set) var keyDeclined = false
    private var lastAutoCheck = Date.distantPast
    private var directWork: DispatchWorkItem?
    /// Direct windows in a row that never connected (the Macs out of AWDL range); each doubles the rest before the next.
    private var failedWindows = 0
    private var directRestUntil = Date.distantPast
    private static let directWindow: TimeInterval = 600

    private struct State: Codable {
        var id: String
        var peer: LinkPeer?
    }

    /// What still reads in a damaged `link.json`, field by field: losing the ID would end the pairing on both Macs.
    private struct Salvage: Decodable {
        var id: String?
        var peer: LinkPeer?

        private struct Bare: Decodable {
            var id: String
            var name: String
        }

        private enum Keys: String, CodingKey { case id, peer }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try? c.decode(String.self, forKey: .id)
            // A peer whose snapshot no longer reads is still the peer, without its last snapshot.
            peer = (try? c.decode(LinkPeer.self, forKey: .peer))
                ?? (try? c.decode(Bare.self, forKey: .peer)).map { LinkPeer(id: $0.id, name: $0.name) }
        }
    }

    init(directory: URL, keychainService: String, computerName: String = HaloLink.computerName(), loopbackOnly: Bool = false) {
        stateFile = directory.appendingPathComponent("link.json")
        keychain = LinkKeychain(service: keychainService)
        self.computerName = computerName
        self.loopbackOnly = loopbackOnly
        var saved: State?
        var damaged = false
        switch StateFile.load(State.self, from: stateFile) {
        case .absent:
            break
        case .loaded(let state):
            saved = state
        case .unreadable(let data, var kept):
            let salvage = data.flatMap { try? JSONDecoder().decode(Salvage.self, from: $0) }
            let salvagedID = salvage?.id.flatMap { LinkKeys.isPeerID($0) ? $0 : nil }
            // Left in place, yet without an ID nothing in it can be used: moved aside after all, so the new ID is
            // saved and stays this Mac's across launches.
            if kept == nil, data != nil, salvagedID == nil { kept = StateFile.moveAside(stateFile) }
            StateFiles.report(stateFile.lastPathComponent, keptAs: kept, salvaged: salvagedID != nil)
            damaged = true
            if let salvagedID { saved = State(id: salvagedID, peer: salvage?.peer) }
        }
        id = saved.map(\.id).flatMap { LinkKeys.isPeerID($0) ? $0 : nil } ?? LinkKeys.newPeerID()
        peer = saved?.peer
        // A damaged file moved aside is written afresh at once; one left in place is not written over at all.
        if (saved?.id != id || damaged), StateFiles.mayWrite(stateFile.lastPathComponent) { persist() }
    }

    static func computerName() -> String {
        SCDynamicStoreCopyComputerName(nil, nil) as String? ?? Host.current().localizedName ?? "Mac"
    }

    /// Starts advertising and browsing if paired; unpaired, nothing runs.
    func start() {
        loadKey()
        configure()
    }

    /// The paired Mac's key. A key that is gone (removed in Keychain Access) ends the pairing cleanly. A keychain
    /// that cannot be read right now (still locked at login) keeps the pairing and is read again when the session
    /// becomes active, the screen unlocks or the Mac wakes; as a fallback for a keychain that unlocks on none of
    /// these, once more after 30 s, then at doubling intervals up to half an hour, and only while it stays unreadable.
    /// A prompt the person declined is their answer: it is not asked again until they relaunch, and the link says so.
    private func loadKey() {
        guard let peer, key == nil else { return }
        switch keychain.read(peer.id) {
        case .found(let stored):
            key = stored
            stopWaitingForKeychain()
        case .missing:
            stopWaitingForKeychain()
            self.peer = nil
            persist()
            log?("paired key missing from the keychain; unpaired")
            onUnpaired?()
            onChange?()
        case .declined:
            stopWaitingForKeychain()
            keyDeclined = true
            log?("keychain access to the pairing key was declined")
            onChange?()
        case .unavailable(let status):
            if keychainObservers.isEmpty {
                log?("keychain not readable (\(status)); waiting for unlock")
                let retry: (Notification) -> Void = { [weak self] _ in self?.retryKeychain() }
                let workspace = NSWorkspace.shared.notificationCenter
                let distributed = DistributedNotificationCenter.default() as NotificationCenter
                keychainObservers = [
                    (workspace, workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: retry)),
                    (workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: retry)),
                    (distributed, distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: retry))
                ]
            }
            keychainRetry?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.retryKeychain() }
            keychainRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + keychainDelay, execute: work)
            keychainDelay = min(keychainDelay * 2, 1800)
        }
    }

    private func retryKeychain() {
        guard key == nil, peer != nil else { return stopWaitingForKeychain() }
        loadKey()
        if key != nil { configure(); onChange?() }
    }

    private func stopWaitingForKeychain() {
        for (center, token) in keychainObservers { center.removeObserver(token) }
        keychainObservers = []
        keychainRetry?.cancel()
        keychainRetry = nil
        keychainDelay = 30
    }

    func stop() {
        // A key stored for a pairing still being confirmed goes with it.
        if pairing != .idle {
            endPairingAttempt()
            pairing = .idle
        }
        stopWaitingForKeychain()
        directWork?.cancel()
        endSession()
        stopNetwork()
        pending.forEach { $0.cancel() }
        pending = []
    }

    // MARK: Pairing

    /// Looks for the other Mac, which must be pairing too, and shows the digits to compare once it is found.
    func startPairing() {
        guard peer == nil, mayPair() else { return }
        endPairingAttempt()
        pairing = .searching
        notice = nil
        schedulePairingEnd(after: LinkKeys.searchTime, notice: L("No other Mac that is pairing was found"))
        log?("pairing: searching")
        configure()
        onChange?()
    }

    /// A pairing must be saved to last: with `link.json` left as it was (written by a newer Halo), the other Mac would
    /// keep a pairing this one forgets on its next launch.
    private func mayPair() -> Bool {
        guard !StateFiles.mayWrite(stateFile.lastPathComponent) else { return true }
        notice = L("link.json can’t be written, so pairing isn’t possible for now")
        onChange?()
        return false
    }

    /// The person here says the digits match: the key is stored and the other Mac told; the pairing holds once the
    /// other Mac's person has said so too.
    func confirmPairing() {
        guard var current = comparing, !current.stored, case .comparing(let code, let name, false) = pairing,
              let other = current.exchange.peer, let key = current.exchange.key, let proof = current.exchange.confirmation else { return }
        guard keychain.write(key, account: other.peer) else {
            log?("pairing could not store the key")
            return cancelPairing(notice: L("Pairing didn’t finish; try again"))
        }
        current.stored = true
        comparing = current
        current.connection.send(.pairConfirm(proof))
        pairing = .comparing(code: code, with: name, confirmed: true)
        if current.peerConfirmed { return commitPairing() }
        onChange?()
    }

    /// Ends an attempt. Hanging up tells the other Mac too, so it does not keep a pairing this one gave up.
    func cancelPairing(notice: String? = nil) {
        guard pairing != .idle else { return }
        endPairingAttempt()
        pairing = .idle
        self.notice = notice
        configure()
        onChange?()
    }

    /// Forgets the pairing here and, when the other Mac is connected now, there too: it is told over the paired
    /// connection, the only one it trusts. One that is offline keeps its side until someone unpairs it there.
    func unpair() { forget(byPeer: false) }

    private func forget(byPeer: Bool) {
        guard let peer else { return }
        keychain.delete(peer.id)
        stopWaitingForKeychain()
        keyDeclined = false
        notice = byPeer ? L("The other Mac unpaired") : nil
        self.peer = nil
        key = nil
        resetFailures()
        persist()
        endSession(sending: byPeer ? nil : .unpaired)
        // A second connection still forming could reach the other Mac with the old key and replace the session the
        // message rides on before it is read.
        directWork?.cancel()
        pending.forEach { $0.cancel() }
        pending = []
        configure()
        log?(byPeer ? "unpaired by the other Mac" : "unpaired")
        onUnpaired?()
        onChange?()
    }

    /// Lets go of everything an attempt holds; a key stored for a pairing that never completed goes too.
    private func endPairingAttempt() {
        if let comparing {
            // Let go first: cancelling reports the close at once, and it must not read as the other Mac hanging up.
            self.comparing = nil
            if comparing.stored, let other = comparing.exchange.peer { keychain.delete(other.peer) }
            comparing.connection.cancel()
        }
        exchanges = [:]
        pairingEnd?.cancel()
        pairingEnd = nil
        pairingServices = [:]
        pairingDialWork?.cancel()
        pairingDialWork = nil
        revealedOn = nil
        revealDeadline?.cancel()
        revealDeadline = nil
        pending.forEach { $0.cancel() }
        pending = []
    }

    private func schedulePairingEnd(after seconds: TimeInterval, notice: String) {
        pairingEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            self?.log?("pairing: timed out")
            self?.cancelPairing(notice: notice)
        }
        pairingEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: end)
    }

    /// The other Mac's half arrived and matched its commitment: these digits are shown, and every other attempt ends.
    private func compare(_ exchange: PairingExchange, code: String, on connection: LinkConnection) {
        exchanges = [:]
        revealDeadline?.cancel()
        revealDeadline = nil
        // `comparing` holds this connection from here; its close is that path's to read, not a failed reveal.
        revealedOn = nil
        pending.removeAll { $0 === connection }
        pending.forEach { $0.cancel() }
        pending = []
        comparing = (connection, exchange, false, false)
        let name = exchange.peer?.computer ?? ""
        pairing = .comparing(code: code, with: name, confirmed: false)
        // No one else is let in while the digits are compared.
        stopNetwork()
        schedulePairingEnd(after: LinkKeys.compareTime, notice: L("Pairing didn’t finish; try again"))
        log?("pairing: comparing with \(name)")
        onChange?()
    }

    private func commitPairing() {
        guard let current = comparing, let other = current.exchange.peer, let key = current.exchange.key else { return }
        comparing = nil
        peer = LinkPeer(id: other.peer, name: other.computer)
        self.key = key
        resetFailures()
        stopWaitingForKeychain()
        keyDeclined = false
        persist()
        log?("paired with \(other.computer) \(other.peer)")
        onPaired?()
        // The confirmation goes out before the connection closes, so the other Mac still completes.
        current.connection.afterSends { current.connection.cancel() }
        cancelPairing(notice: nil)
    }

    // MARK: Network

    /// With a key: TLS 1.2 with that pre-shared key only, no certificates, and a peer without the key fails the
    /// handshake before any byte of ours is read or written. Without one (pairing): plain TCP, since the exchange
    /// secures itself. Keepalive notices a vanished peer without Halo polling.
    private func parameters(key: Data?, identity: String, direct: Bool = false) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.keepaliveInterval = 15
        tcp.keepaliveCount = 4
        tcp.connectionTimeout = 10
        guard let key else {
            let parameters = NWParameters(tls: nil, tcp: tcp)
            if loopbackOnly { parameters.requiredInterfaceType = .loopback }
            return parameters
        }
        let tls = NWProtocolTLS.Options()
        LinkTLS.configure(tls.securityProtocolOptions, key: key, identity: identity)
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = direct && !loopbackOnly
        if loopbackOnly { parameters.requiredInterfaceType = .loopback }
        return parameters
    }

    private var browseParameters: NWParameters {
        let parameters = NWParameters()
        parameters.includePeerToPeer = direct && !loopbackOnly
        if loopbackOnly { parameters.requiredInterfaceType = .loopback }
        return parameters
    }

    /// Brings listener and browser in line with the pairing state, recreating the listener when its key changes.
    private func configure() {
        stopNetwork()
        switch pairing {
        case .searching:
            listen(key: nil, identity: "", txt: ["id": id, "pair": "1"])
            browse()
        case .comparing:
            break
        case .idle:
            guard peer != nil, let key else { return }
            // Where the probes of a link check go; both are public on the network already through Bonjour.
            var txt = ["id": id]
            if let host = SCDynamicStoreCopyLocalHostName(nil) as String? { txt["host"] = host + ".local" }
            listen(key: key, identity: Self.linkIdentity, txt: txt, direct: direct)
            browse()
        }
    }

    private func stopNetwork() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        peerEndpoint = nil
        networkEndpoint = nil
        retryWork?.cancel()
        retryWork = nil
    }

    private func listen(key: Data?, identity: String, txt: [String: String], direct: Bool = false) {
        let listener: NWListener
        do { listener = try NWListener(using: parameters(key: key, identity: identity, direct: direct)) } catch {
            log?("listener failed: \(error)")
            return
        }
        // The instance name only has to be unique; the TXT record says who it is.
        listener.service = NWListener.Service(name: "Halo-\(id.prefix(8))", type: Self.serviceType, txtRecord: NWTXTRecord(txt))
        // A connection queued for a listener that was just replaced (pairing's plain one, say) is not judged by the new one's rules.
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener, listener === self.listener else { return connection.cancel() }
            self.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                self.log?("listening on port \(port)\(direct ? " (direct allowed)" : "")")
                // The port is known only now; a paired link adds it to the record for the other Mac's probes.
                if txt["host"] != nil {
                    var record = txt
                    record["port"] = String(port)
                    listener.service = NWListener.Service(name: "Halo-\(self.id.prefix(8))", type: Self.serviceType,
                                                          txtRecord: NWTXTRecord(record))
                }
            case .failed(let error):
                self.log?("listener failed: \(error)")
                // A network change can take the port away; start again in a while rather than spinning.
                self.listener = nil
                listener.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, self.listener == nil else { return }
                    self.configure()
                }
            default: break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func browse() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: browseParameters)
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, browser === self.browser else { return }
            self.found(results)
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, browser === self.browser else { return }
            switch state {
            case .failed(let error):
                self.log?("browser failed: \(error)")
                // Without a browser the peer is never found again; start over in a while, as the listener does.
                self.browser = nil
                browser.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, self.browser == nil else { return }
                    self.configure()
                }
            case .waiting(let error):
                self.log?("browser waiting: \(error)")
            default: break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        var services: [(id: String, pairing: Bool, endpoint: NWEndpoint, overAir: Bool)] = []
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let other = txt["id"], other != id, LinkKeys.isPeerID(other) else { continue }
            let overAir = !result.interfaces.isEmpty && result.interfaces.allSatisfy { Self.isDirect($0.name) }
            services.append((other, txt["pair"] == "1", result.endpoint, overAir))
            if other == peer?.id, !overAir {
                peerHost = txt["host"] ?? peerHost
                peerPort = txt["port"].flatMap(UInt16.init) ?? peerPort
            }
        }
        switch pairing {
        case .searching:
            let now = Date()
            var seen: [String: (endpoint: NWEndpoint, since: Date)] = [:]
            for service in services where service.pairing {
                if pairingServices[service.id] == nil { log?("found pairing Mac \(service.id)") }
                seen[service.id] = (service.endpoint, pairingServices[service.id]?.since ?? now)
            }
            pairingServices = seen
            dialForPairing()
        case .idle:
            guard let peer else { return }
            let mine = services.filter { $0.id == peer.id && !$0.pairing }
            // Bonjour merges the network and AWDL sightings into one result; a dial with peer-to-peer allowed races both,
            // one without stays on the network.
            let wasMissing = peerEndpoint == nil
            networkEndpoint = mine.first { !$0.overAir }?.endpoint
            peerEndpoint = mine.first?.endpoint
            // Bonjour reports again on any change (the other Mac's record gaining its port, another service): only a
            // peer that was not in sight is dialled at once; otherwise the retry under way keeps its backoff.
            if peerEndpoint != nil, wasMissing {
                log?("found peer \(peer.id)")
                connectSoon(after: 0)
            }
        case .comparing:
            break
        }
    }

    /// One pairing connection at a time. The Mac with the lower ID dials at once; the other only once it has seen the
    /// first for a few seconds without being dialled, for a network that shows each Mac to only one of them. A
    /// connection that ends before this Mac revealed anything costs nothing, so the next one is tried a moment later.
    private func dialForPairing() {
        pairingDialWork?.cancel()
        pairingDialWork = nil
        guard pairing == .searching, revealedOn == nil, pending.isEmpty, !pairingServices.isEmpty else { return }
        let now = Date()
        let due = pairingServices.map { (id: $0.key, endpoint: $0.value.endpoint, at: $0.value.since.addingTimeInterval(id < $0.key ? 0 : 3)) }
            .min { $0.at < $1.at }!
        guard due.at <= now else {
            let work = DispatchWorkItem { [weak self] in self?.dialForPairing() }
            pairingDialWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + due.at.timeIntervalSince(now), execute: work)
            return
        }
        // Tried again only after the next failure's pause, not in a tight loop.
        pairingServices[due.id]?.since = now.addingTimeInterval(3)
        dial(due.endpoint, key: nil, identity: "")
    }

    /// The Mac with the lower ID dials; the other dials too, a moment later, only if nothing arrived, so one
    /// connection normally forms even when only one side sees the other's advertisement.
    private func connectSoon(after delay: TimeInterval) {
        guard let peer, session == nil else { return }
        retryWork?.cancel()
        let wait = delay + (id < peer.id ? 0 : 3)
        let work = DispatchWorkItem { [weak self] in
            // Only a dial of our own already under way makes another pointless; a stranger's half-open
            // connection to our listener must not stop us from reaching the peer.
            guard let self, self.session == nil, !self.pending.contains(where: \.dialed),
                  let endpoint = self.peerEndpoint, let key = self.key else { return }
            self.dial(endpoint, key: key, identity: Self.linkIdentity, direct: self.direct)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func dial(_ endpoint: NWEndpoint, key: Data?, identity: String, direct: Bool = false) {
        let connection = LinkConnection(NWConnection(to: endpoint, using: parameters(key: key, identity: identity, direct: direct)), dialed: true)
        adopt(connection)
    }

    private func accept(_ connection: NWConnection) {
        // A handful of handshakes at once is plenty for one peer; more is someone knocking. When full, the oldest
        // incoming one makes way, so idle connections cannot keep the real peer out.
        if case .comparing = pairing { connection.cancel(); return }
        if pairing == .searching, revealedOn != nil { connection.cancel(); return }
        let incoming = pending.filter { !$0.dialed }
        if incoming.count >= 4 { incoming.first?.cancel() }
        adopt(LinkConnection(connection, dialed: false))
    }

    private func adopt(_ connection: LinkConnection) {
        let forPairing = pairing != .idle
        connection.keyed = !forPairing
        pending.append(connection)
        if forPairing { exchanges[ObjectIdentifier(connection)] = PairingExchange(id: id, computer: computerName) }
        connection.onReady = { [weak self, weak connection] in
            guard let self, let connection else { return }
            if forPairing, let exchange = self.exchanges[ObjectIdentifier(connection)] {
                connection.send(.pairCommit(exchange.commitment))
                // A connection that sends no commitment of its own would hold the one pairing connection open.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
                    guard let self, let connection, self.exchanges[ObjectIdentifier(connection)]?.committed == false else { return }
                    self.dropPairing(connection)
                }
            } else if !forPairing {
                connection.send(.hello(peer: self.id))
            }
        }
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection else { return }
            self.received(message, on: connection, forPairing: forPairing)
        }
        connection.onUnreadable = { [weak self] type in
            guard let self, self.unreadableLogged.insert(type).inserted else { return }
            self.log?("skipped a \(type) this version cannot read")
        }
        connection.onClose = { [weak self, weak connection] error in
            guard let self, let connection else { return }
            self.closed(connection, error: error, forPairing: forPairing)
        }
        connection.start()
    }

    /// One pairing connection that broke the exchange (a stranger, or a Mac that gave up) goes; the search goes on.
    private func dropPairing(_ connection: LinkConnection) {
        if comparing?.connection === connection || revealedOn === connection { return cancelPairing(notice: L("Pairing didn’t finish; try again")) }
        exchanges[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }

    private func received(_ message: LinkMessage, on connection: LinkConnection, forPairing: Bool) {
        switch (message, forPairing) {
        case (.pairCommit(let commitment), true):
            let slot = ObjectIdentifier(connection)
            // This Mac's half goes out once per attempt; a commitment on any other connection after that is turned away.
            guard pairing == .searching, revealedOn == nil || revealedOn === connection, var exchange = exchanges[slot],
                  let reveal = try? exchange.received(commitment: commitment) else { return dropPairing(connection) }
            exchanges[slot] = exchange
            revealedOn = connection
            connection.send(.pairReveal(reveal))
            // The other half must follow at once; one held back is someone keeping this Mac's half for later.
            let deadline = DispatchWorkItem { [weak self] in
                self?.log?("pairing: the other half never came")
                self?.cancelPairing(notice: L("Pairing didn’t finish; try again"))
            }
            revealDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: deadline)
        case (.pairReveal(let reveal), true):
            let slot = ObjectIdentifier(connection)
            guard pairing == .searching, var exchange = exchanges[slot] else { return dropPairing(connection) }
            do {
                let code = try exchange.received(reveal: reveal)
                compare(exchange, code: code, on: connection)
            } catch {
                log?("pairing: \(reveal.computer) failed the exchange (\(error))")
                dropPairing(connection)
            }
        case (.pairConfirm(let proof), true):
            // From any other connection it is a stranger's, and must not end the attempt the person is looking at.
            guard var current = comparing, current.connection === connection else { return dropPairing(connection) }
            guard !current.peerConfirmed, current.exchange.accepts(confirmation: proof) else {
                log?("pairing: confirmation did not check out")
                return cancelPairing(notice: L("Pairing didn’t finish; try again"))
            }
            current.peerConfirmed = true
            comparing = current
            if current.stored { commitPairing() }
        case (.hello(let other), false):
            guard let peer, other == peer.id, !connection.verified else { connection.cancel(); return }
            connection.verified = true
            connection.verifiedAt = Date()
            pending.removeAll { $0 === connection }
            if let old = session, !prefer(connection, over: old) {
                connection.cancel()
                return
            }
            let old = session
            session = connection
            old?.cancel()
            retryWork?.cancel()
            outbox.reset()
            snapshotFailureLogged = false
            resetFailures()
            weakRefusals = 0
            failedWindows = 0
            directRestUntil = .distantPast
            // The other side sends its own check on connecting if it has one; an earlier run's may be gone with it.
            peerCheck = nil
            path = connection.overAir ? .direct : .network
            log?("connected to \(peer.name) \(path == .direct ? "directly (AWDL)" : "over the network")")
            self.peer?.lastSeen = Date()
            sendSnapshot()
            if let lastCheck { connection.send(.report(lastCheck)) }
            if path == .network, direct { leaveDirect() }
            // A direct dial that was under way when the window closed can still connect; keep reviewing it then.
            if path == .direct, !direct {
                direct = true
                scheduleDirectReview()
            }
            // A fault found earlier no longer describes a network that carries the link; measure it again once.
            if path == .network, let verdict, verdict != .ok { check() }
            onChange?()
        case (.snapshot(let snapshot), false):
            guard connection.verified, connection === session else { return }
            guard snapshot != peer?.snapshot else { return }
            peer?.snapshot = snapshot
            if !snapshot.computer.isEmpty { peer?.name = snapshot.computer }
            log?("snapshot \(String(decoding: (try? JSONEncoder().encode(snapshot)) ?? Data(), as: UTF8.self))")
            onChange?()
        case (.clip, false), (.clipChunk, false), (.clipRequest, false), (.clipDeclined, false):
            guard connection.verified, connection === session else { return }
            onClip?(message)
        case (.handoff(let handoff), false):
            guard connection.verified, connection === session else { return }
            onHandoff?(handoff)
        case (.unpaired, false):
            guard connection.verified, connection === session else { return }
            forget(byPeer: true)
        case (.report(let check), false):
            guard connection.verified, connection === session, check != peerCheck else { return }
            peerCheck = check
            log?("peer check: \(LinkVerdict.of(check).rawValue)")
            onChange?()
        default:
            // A message that does not belong on this kind of connection: the other side is confused, so hang up.
            connection.cancel()
        }
    }

    /// Of two connections to the peer: when both formed within moments of each other (each side dialed), both
    /// sides keep the one the lower ID dialed; otherwise the newer, since the older one is likely dead unnoticed.
    private func prefer(_ newer: LinkConnection, over older: LinkConnection) -> Bool {
        guard let peer, newer.verifiedAt.timeIntervalSince(older.verifiedAt) < 5 else { return true }
        let lower = id < peer.id
        return (newer.dialed == lower) || (older.dialed != lower)
    }

    private func closed(_ connection: LinkConnection, error: NWError?, forPairing: Bool) {
        pending.removeAll { $0 === connection }
        if forPairing {
            exchanges[ObjectIdentifier(connection)] = nil
            guard pairing != .idle else { return }
            if let current = comparing, current.connection === connection {
                // The other Mac hung up while the digits were shown: it cancelled, said they differ, or ran out of
                // time. If the person here had already confirmed, the other Mac may have completed on that just
                // before its own confirmation was lost.
                log?("pairing: the other Mac ended it")
                cancelPairing(notice: current.stored ? L("Pairing didn’t finish. If the other Mac shows it as paired, unpair it there, then try again")
                                                     : L("The other Mac cancelled pairing"))
            } else if revealedOn === connection {
                log?("pairing: ended after this Mac's half went out")
                cancelPairing(notice: L("Pairing didn’t finish; try again"))
            } else {
                dialForPairing()
            }
            return
        }
        if connection.withoutForwardSecrecy {
            if peer != nil { weakRefusals += 1 }
            if !weakHandshakeLogged {
                weakHandshakeLogged = true
                log?("refused a connection without forward secrecy")
            }
            // So the diagnostics export and its verdict (`noForwardSecrecy`) say why, as after timeouts; at most once per window.
            if peer != nil, pairing == .idle, Date().timeIntervalSince(lastAutoCheck) >= Self.directWindow {
                lastAutoCheck = Date()
                check()
            }
        }
        guard connection === session else {
            noteFailure(connection, error: error)
            if session == nil, peer != nil, connection.dialed { scheduleRetry() }
            return
        }
        // Back to a quick retry only after a session that lasted: one the other Mac keeps ending at once must not
        // turn into a reconnect every second.
        if Date().timeIntervalSince(connection.verifiedAt) > 60 { retryDelay = 1 }
        endSession()
        log?("disconnected")
        scheduleRetry()
        onChange?()
    }

    /// `last` goes out before the connection closes: cancelling at once could drop it, so the connection closes once
    /// the network has taken it, or after two seconds.
    private func endSession(sending last: LinkMessage? = nil) {
        sendWork?.cancel()
        guard let session else { return }
        self.session = nil
        path = nil
        if let last, session.verified {
            session.send(last)
            session.afterSends { session.cancel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { session.cancel() }
        } else {
            session.cancel()
        }
        if peer != nil {
            peer?.lastSeen = Date()
            persist()
        }
    }

    /// Exponential backoff up to two minutes; a fresh sighting of the peer resets it. A peer that keeps failing the
    /// handshake is tried only every half hour: the other Mac can still connect here, and does once it is paired again.
    private func scheduleRetry() {
        guard pairing == .idle, peer != nil, peerEndpoint != nil else { return }
        let delay: TimeInterval
        if handshakeFailures >= Self.handshakeGiveUp {
            delay = Self.slowRetry
            if !slowRetryLogged {
                slowRetryLogged = true
                log?("the other Mac keeps refusing this pairing; trying every \(Int(delay / 60)) min")
            }
        } else {
            delay = retryDelay
            retryDelay = min(retryDelay * 2, 120)
            log?("retry in \(Int(delay)) s")
        }
        connectSoon(after: delay)
    }

    // MARK: Checks and the direct fallback

    static func isDirect(_ interface: String) -> Bool { interface.hasPrefix("awdl") || interface.hasPrefix("llw") }

    /// Counts what failed and how. Two dials in a row that time out against a peer the network shows set off a
    /// check and the direct fallback; a handshake from the peer that never finishes is evidence the other way round.
    private func noteFailure(_ connection: LinkConnection, error: NWError?) {
        guard peer != nil, pairing == .idle else { return }
        // Only our own dials: an incoming connection that fails TLS is as likely the other Mac's probe or a stranger.
        if case .tls(_)? = error, connection.dialed, session == nil { handshakeFailures += 1 }
        guard connection.timedOut else { return }
        if !connection.dialed {
            inboundStalls.append(Date())
            inboundStalls.removeAll { Date().timeIntervalSince($0) > Self.directWindow }
            return
        }
        guard session == nil, peerEndpoint != nil else { return }
        if dialTimeouts == 0 { timeoutsSince = Date() }
        dialTimeouts += 1
        log?("dial timed out (\(dialTimeouts) in a row)")
        guard dialTimeouts >= 2 else { return }
        if Date().timeIntervalSince(lastAutoCheck) >= Self.directWindow {
            lastAutoCheck = Date()
            check(afterTimeouts: true)
        } else {
            // Only a check made during this run of timeouts speaks for it; one from before, say while a session was
            // up, would hide a network that has failed since.
            let current = lastCheck.flatMap { check in timeoutsSince.map { check.at >= $0 } == true ? check : nil }
            afterTimeouts(peerTCP: current?.peerTCP, fresh: false)
        }
    }

    /// Dials that keep timing out: when Halo's port on the other Mac takes a plain TCP connection, what stalls is the
    /// handshake (a key the other Mac no longer has), which a direct link would not mend; otherwise the network is
    /// the suspect and the direct fallback is tried. Each check counts as one failed handshake at most, however many
    /// timeouts it is consulted for.
    private func afterTimeouts(peerTCP: LinkReach?, fresh: Bool) {
        guard session == nil, dialTimeouts >= 2 else { return }
        if peerTCP == .ok {
            if fresh { handshakeFailures += 1 }
            return
        }
        // The port is silent: the network is what fails, whatever the handshakes did before.
        if peerTCP == .timedOut { handshakeFailures = 0 }
        // Without the peer's advertised host there is nothing to dial directly.
        if !direct, networkEndpoint != nil, peerHost != nil, !loopbackOnly, Date() >= directRestUntil { enterDirect() }
    }

    /// A session, a new pairing or unpairing: earlier failures say nothing any more.
    private func resetFailures() {
        dialTimeouts = 0
        timeoutsSince = nil
        handshakeFailures = 0
        slowRetryLogged = false
    }

    /// Measures the path to the peer once: ping, a TCP connection to its Halo port and one to the router.
    func check(afterTimeouts timeouts: Bool = false) {
        guard peer != nil, !checking else { return }
        checking = true
        onChange?()
        // A reconfigure forgets the sighting for a moment; a live connection over the network shows the peer is there.
        let found = networkEndpoint != nil || path == .network
        LinkProbe.run(host: peerHost, port: peerPort) { [weak self] address, ping, peerTCP, gateway in
            guard let self else { return }
            self.checking = false
            self.inboundStalls.removeAll { Date().timeIntervalSince($0) > Self.directWindow }
            if timeouts { self.afterTimeouts(peerTCP: peerTCP, fresh: true) }
            let check = LinkCheck(found: found, address: address, ping: ping.0, pingMilliseconds: ping.1, peerTCP: peerTCP,
                                  gatewayTCP: gateway, inboundStalled: self.inboundStalls.count, dialTimeouts: self.dialTimeouts,
                                  handshakeFailures: self.handshakeFailures, noForwardSecrecy: self.weakRefusals)
            self.lastCheck = check
            self.log?("check: \(LinkVerdict.of(check).rawValue) ping=\(ping.0.rawValue) tcp=\(peerTCP.rawValue) router=\(gateway.rawValue) "
                      + "inbound stalled=\(check.inboundStalled) dial timeouts=\(check.dialTimeouts)")
            if let session = self.session, session.verified { session.send(.report(check)) }
            self.onChange?()
        }
    }

    private func enterDirect() {
        direct = true
        retryDelay = 1
        log?("network fails to reach the peer; allowing a direct link")
        configure()
        scheduleDirectReview()
        onChange?()
    }

    private func leaveDirect() {
        guard direct else { return }
        direct = false
        directWork?.cancel()
        directWork = nil
        log?(path == .network ? "network works again; direct link off" : "no connection in the direct window; direct link off")
        configure()
        onChange?()
    }

    /// Every ten minutes of the fallback: with no connection, end it; over AWDL, try the network again. The lower ID
    /// tries, as it dials first; a connection that forms over the network replaces the direct one on both sides.
    private func scheduleDirectReview() {
        directWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.direct else { return }
            if self.session == nil {
                self.dialTimeouts = 0
                self.failedWindows += 1
                let rest = min(Self.directWindow * pow(2, Double(self.failedWindows - 1)), 2 * 3600)
                self.directRestUntil = Date().addingTimeInterval(rest)
                self.leaveDirect()
                return
            }
            if self.path == .direct, let peer = self.peer, self.id < peer.id, let endpoint = self.networkEndpoint, let key = self.key {
                self.log?("trying the network again")
                self.dial(endpoint, key: key, identity: Self.linkIdentity, direct: false)
            }
            self.scheduleDirectReview()
        }
        directWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.directWindow, execute: work)
    }

    // MARK: Snapshots

    /// Called at every change point; costs nothing unless the peer is connected, and sends only a changed snapshot.
    func snapshotChanged() {
        guard online else { return }
        sendWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendSnapshot() }
        sendWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Sends clipboard messages to the paired Mac; false when it is not connected right now or one cannot be encoded.
    @discardableResult
    func send(_ messages: [LinkMessage]) -> Bool {
        guard let frames = try? messages.map(LinkFrame.encode) else { return false }
        return send(frames: frames, done: nil)
    }

    /// Sends frames encoded elsewhere; `done` runs once the network has taken them all, or the connection dropped.
    @discardableResult
    func send(frames: [Data], done: (() -> Void)?) -> Bool {
        guard let session, session.verified else { return false }
        frames.forEach(session.send(frame:))
        if let done { session.afterSends(done) }
        return true
    }

    private func sendSnapshot() {
        guard let session, session.verified, let snapshot = snapshot?() else { return }
        let frame: Data?
        do { frame = try outbox.frame(for: snapshot) } catch {
            // Logged once per connection: the next debounce would only fail the same way.
            if !snapshotFailureLogged { log?("snapshot not sent: \(error)") }
            snapshotFailureLogged = true
            return
        }
        guard let frame else { return }
        session.send(frame: frame)
        log?("sent snapshot (\(frame.count) bytes)")
    }

    private func persist() {
        guard StateFiles.mayWrite(stateFile.lastPathComponent) else { return }
        do {
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(State(id: id, peer: peer)).write(to: stateFile, options: .atomic)
        } catch {
            log?("could not save link state: \(error)")
        }
    }
}

/// One TLS connection: a 4-byte length, then that many bytes of JSON, read one message at a time.
private final class LinkConnection {
    let connection: NWConnection
    let dialed: Bool
    /// True once the peer's hello matched the paired peer.
    var verified = false
    var verifiedAt = Date.distantPast
    /// Closed by the handshake timer: nothing came back in time.
    private(set) var timedOut = false
    /// Closed because the handshake fell back to plain PSK.
    private(set) var withoutForwardSecrecy = false
    /// Runs over TLS with the paired key (every connection but pairing's), so it must have forward secrecy.
    var keyed = false
    private var reachedReady = false
    /// Runs over AWDL rather than the local network.
    var overAir: Bool { connection.currentPath?.availableInterfaces.contains { HaloLink.isDirect($0.name) } ?? false }
    var onReady: (() -> Void)?
    var onMessage: ((LinkMessage) -> Void)?
    var onClose: ((NWError?) -> Void)?
    /// A message of a known kind whose contents did not read, on a verified connection; it is skipped.
    var onUnreadable: ((String) -> Void)?
    private var closed = false
    private var sending = 0
    private var afterSent: (() -> Void)?

    init(_ connection: NWConnection, dialed: Bool) {
        self.connection = connection
        self.dialed = dialed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.reachedReady = true
                // Anything that settled for plain PSK is not talked to.
                if self.keyed, LinkTLS.forwardSecret(self.connection) != true {
                    self.withoutForwardSecrecy = true
                    return self.cancel()
                }
                self.onReady?()
                self.receiveHeader()
            // Waiting means no route right now; give up and let the owner retry later instead of hanging on.
            case .waiting(let error), .failed(let error): self.finish(error)
            case .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: .main)
        // A handshake that stalls is dropped rather than held open. This is also how a key the other Mac no longer
        // has ends on the dialing side: the listener rejects it (bad MAC), but the dialer is not told and stays preparing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.connection.state != .ready, !self.closed else { return }
            self.timedOut = true
            self.cancel()
        }
    }

    func cancel() {
        connection.cancel()
        finish(nil)
    }

    private func finish(_ error: NWError?) {
        guard !closed else { return }
        closed = true
        // TCP's own connect timeout can report before the handshake timer fires; it is the same silence.
        if !reachedReady, case .posix(.ETIMEDOUT)? = error { timedOut = true }
        if connection.state != .cancelled { connection.cancel() }
        onClose?(error)
        // Whoever waits for the sends to go hears now: nothing more will go on this connection.
        let waiting = afterSent
        afterSent = nil
        waiting?()
        onReady = nil
        onMessage = nil
        onClose = nil
        onUnreadable = nil
    }

    func send(_ message: LinkMessage) {
        guard let frame = try? LinkFrame.encode(message) else { return }
        send(frame: frame)
    }

    func send(frame: Data) {
        guard !closed else { return }
        sending += 1
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.sending -= 1
            if error != nil { self.cancel(); return }
            if self.sending == 0, let after = self.afterSent {
                self.afterSent = nil
                after()
            }
        })
    }

    /// Runs `action` once everything queued so far has been handed to the network.
    func afterSends(_ action: @escaping () -> Void) {
        guard sending > 0, !closed else { return action() }
        let earlier = afterSent
        afterSent = { earlier?(); action() }
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, let length = LinkFrame.bodyLength(header: data) else { self.cancel(); return }
            if complete { self.cancel(); return }
            self.receiveBody(length)
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, data.count == length else { self.cancel(); return }
            do {
                if let message = try LinkFrame.decode(body: data) { self.onMessage?(message) }
            } catch LinkFrame.Failure.unreadable(let type) where self.verified {
                // The paired Mac said something this version cannot read: skip it, once, rather than hang up and be
                // sent the same thing again on reconnecting.
                self.onUnreadable?(type)
            } catch {
                self.cancel()
                return
            }
            if complete { self.cancel() } else if !self.closed { self.receiveHeader() }
        }
    }
}

/// Kinds travel instead of SF Symbol names, so a peer can only pick from glyphs this Mac already uses.
extension LinkDevice.Kind {
    init(symbol: String) {
        switch symbol {
        case "computermouse.fill": self = .mouse
        case "rectangle.and.hand.point.up.left": self = .trackpad
        case "keyboard.fill": self = .keyboard
        case "headphones": self = .headphones
        case "hifispeaker.fill": self = .speaker
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .mouse: return "computermouse.fill"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .keyboard: return "keyboard.fill"
        case .headphones: return "headphones"
        case .speaker: return "hifispeaker.fill"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }
}
