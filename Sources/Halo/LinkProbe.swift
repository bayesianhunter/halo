// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import HaloCore
import Network
import SystemConfiguration

/// The measurements behind a link check: one ping and two plain TCP connections, run only when the link fails or
/// when asked. Each gives up within a few seconds; none of them repeats on its own.
enum LinkProbe {
    private static let queue = DispatchQueue(label: "Halo link probe", qos: .utility)

    /// The router of this Mac's primary network, as the system reports it.
    static func gateway() -> String? {
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return global?["Router"] as? String
    }

    /// The first IPv4 address of a host name, `.local` names included; blocks for up to a few seconds.
    static func resolve(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var address = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) == nil ? nil : String(cString: text)
    }

    /// One ICMP echo, up to three tries a second apart. Uses the unprivileged datagram ICMP socket, so no root.
    static func ping(_ address: String) -> (LinkReach, Int?) {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else { return (.unavailable, nil) }
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard socket >= 0 else { return (.unavailable, nil) }
        defer { close(socket) }
        let identifier = UInt16.random(in: 1...UInt16.max)
        for sequence in UInt16(1)...3 {
            var packet = [UInt8](repeating: 0, count: 16)
            packet[0] = 8 // echo request
            packet[4] = UInt8(identifier >> 8); packet[5] = UInt8(identifier & 0xff)
            packet[6] = UInt8(sequence >> 8); packet[7] = UInt8(sequence & 0xff)
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xff)
            let start = DispatchTime.now()
            let sent = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard sent == packet.count else { return (.unavailable, nil) }
            var buffer = [UInt8](repeating: 0, count: 256)
            // A per-receive timeout alone can be renewed forever by unrelated replies. Bound the whole attempt
            // as well, using monotonic time so a clock adjustment cannot extend an on-demand check.
            while case let spent = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds, spent < 1_000_000_000 {
                // Each receive waits only for what is left of the second, so an unrelated reply late in it cannot
                // stretch this try to nearly two.
                let left = 1_000_000_000 - spent
                var wait = timeval(tv_sec: 0, tv_usec: __darwin_suseconds_t(min(999_999, max(1_000, left / 1_000))))
                setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
                var source = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, &buffer, buffer.count, 0, $0, &length) }
                }
                guard count > 0 else { break }
                // Only a reply from the address pinged; another ping running at the same time can share the socket's traffic.
                guard source.sin_addr.s_addr == target.sin_addr.s_addr else { continue }
                // Datagram ICMP sockets on macOS hand back the IP header too.
                let header = buffer[0] >> 4 == 4 ? Int(buffer[0] & 0x0f) * 4 : 0
                guard count >= header + 8, buffer[header] == 0 else { continue } // echo reply
                let replySequence = UInt16(buffer[header + 6]) << 8 | UInt16(buffer[header + 7])
                guard replySequence == sequence else { continue }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                return (.ok, max(1, Int(elapsed.rounded())))
            }
        }
        return (.timedOut, nil)
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            sum += UInt32(bytes[index]) << 8 | UInt32(index + 1 < bytes.count ? bytes[index + 1] : 0)
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// A bare TCP connection over the local network only (never peer-to-peer), closed as soon as it settles.
    /// Connected or refused both mean the path works; only silence counts as blocked.
    static func tcp(_ address: String, port: UInt16, timeout: TimeInterval = 4, done: @escaping (LinkReach) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: port) else { return done(.unavailable) }
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = Int(timeout)
        let parameters = NWParameters(tls: nil, tcp: options)
        parameters.includePeerToPeer = false
        let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: parameters)
        var settled = false
        let finish = { (reach: LinkReach) in
            guard !settled else { return }
            settled = true
            connection.cancel()
            done(reach)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(.ok)
            case .waiting(let error), .failed(let error):
                if case .posix(let code) = error, code == .ECONNREFUSED { finish(.refused) } else { finish(.timedOut) }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(.timedOut) }
    }

    /// Runs the probes for a peer at `host` (a `.local` name) and Halo `port`, and reports on the main queue.
    static func run(host: String?, port: UInt16?, done: @escaping (_ address: String?, _ ping: (LinkReach, Int?),
                                                                                  _ peer: LinkReach, _ gateway: LinkReach) -> Void) {
        queue.async {
            let address = host.flatMap(resolve)
            let ping = address.map(ping) ?? (.unavailable, nil)
            let group = DispatchGroup()
            var peer = LinkReach.unavailable, gatewayReach = LinkReach.unavailable
            if let address, let port {
                group.enter()
                tcp(address, port: port) { peer = $0; group.leave() }
            }
            if let router = gateway() {
                // Port 80 answers or refuses on nearly every router; either way the path to it works.
                group.enter()
                tcp(router, port: 80) { gatewayReach = $0; group.leave() }
            }
            group.notify(queue: .main) { done(address, ping, peer, gatewayReach) }
        }
    }
}
