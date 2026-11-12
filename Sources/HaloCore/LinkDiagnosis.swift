// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// What one probe found. A refused TCP connection still proves the path: something answered.
public enum LinkReach: String, Codable, Equatable {
    case ok, refused, timedOut
    /// Not tested: no address to test, or the probe could not run.
    case unavailable

    public var answered: Bool { self == .ok || self == .refused }

    /// A value from a newer peer reads as untested rather than making the whole report unreadable.
    public init(from decoder: Decoder) throws {
        self = LinkReach(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unavailable
    }
}

/// One run of the link checks, measured on one Mac. Sent to the other Mac too, so each side can show both views.
public struct LinkCheck: Codable, Equatable {
    public var at: Date
    /// The paired Mac is advertised on the local network (Bonjour).
    public var found: Bool
    /// The address the probes went to, for the log.
    public var address: String?
    public var ping: LinkReach
    public var pingMilliseconds: Int?
    /// A plain TCP connection to the paired Mac's Halo port.
    public var peerTCP: LinkReach
    /// A plain TCP connection to the router, to tell this Mac's own network apart from the path between the two.
    public var gatewayTCP: LinkReach
    /// Connections from the paired Mac that reached this one but never finished their handshake, in the last 10 minutes.
    public var inboundStalled: Int
    /// Halo's own connections to the paired Mac that timed out in a row before this check.
    public var dialTimeouts: Int
    /// Handshakes that reached the paired Mac but failed on the key.
    public var handshakeFailures: Int
    /// Connections refused because they settled for plain PSK, without forward secrecy. Halo always offers more.
    public var noForwardSecrecy: Int

    public init(at: Date = Date(), found: Bool, address: String? = nil, ping: LinkReach, pingMilliseconds: Int? = nil,
                peerTCP: LinkReach, gatewayTCP: LinkReach, inboundStalled: Int = 0, dialTimeouts: Int = 0, handshakeFailures: Int = 0,
                noForwardSecrecy: Int = 0) {
        self.at = at
        self.found = found
        self.address = address
        self.ping = ping
        self.pingMilliseconds = pingMilliseconds
        self.peerTCP = peerTCP
        self.gatewayTCP = gatewayTCP
        self.inboundStalled = inboundStalled
        self.dialTimeouts = dialTimeouts
        self.handshakeFailures = handshakeFailures
        self.noForwardSecrecy = noForwardSecrecy
    }

    /// Defensive, like the snapshot: a measurement a newer or older peer leaves out reads as not measured. Whether the
    /// peer was found has no "not measured" value, so a report without it does not read at all.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? .distantPast
        found = try c.decode(Bool.self, forKey: .found)
        address = (try? c.decodeIfPresent(String.self, forKey: .address)).map(LinkText.clean)
        ping = (try? c.decodeIfPresent(LinkReach.self, forKey: .ping)) ?? .unavailable
        pingMilliseconds = (try? c.decodeIfPresent(Int.self, forKey: .pingMilliseconds))
        peerTCP = (try? c.decodeIfPresent(LinkReach.self, forKey: .peerTCP)) ?? .unavailable
        gatewayTCP = (try? c.decodeIfPresent(LinkReach.self, forKey: .gatewayTCP)) ?? .unavailable
        inboundStalled = (try? c.decodeIfPresent(Int.self, forKey: .inboundStalled)) ?? 0
        dialTimeouts = (try? c.decodeIfPresent(Int.self, forKey: .dialTimeouts)) ?? 0
        handshakeFailures = (try? c.decodeIfPresent(Int.self, forKey: .handshakeFailures)) ?? 0
        noForwardSecrecy = (try? c.decodeIfPresent(Int.self, forKey: .noForwardSecrecy)) ?? 0
    }
}

/// What the measurements add up to, in the order the causes are ruled out.
public enum LinkVerdict: String, Codable, Equatable {
    /// The network carries the connection; nothing to fix there.
    case ok
    /// This Mac cannot reach its own router.
    case localNetwork
    /// The paired Mac is not advertised here: asleep, off, on another network, or Halo not running.
    case notFound
    /// Packets reach the paired Mac but TCP between the two does not: a router or access point drops it.
    case tcpBlocked
    /// The paired Mac is advertised but answers nothing at all, not even ping.
    case peerSilent
    /// The connection reaches the paired Mac but the key no longer matches: pair again.
    case handshake
    /// Connections made with the pairing key settled for plain PSK, without forward secrecy, and were refused:
    /// whatever made them is not a current Halo.
    case noForwardSecrecy
    /// Not enough was measured to say.
    case unknown

    public static func of(_ check: LinkCheck) -> LinkVerdict {
        // A router that ignores port 80 is not a fault while the peer still answers.
        if check.gatewayTCP == .timedOut, check.ping != .ok, !check.peerTCP.answered { return .localNetwork }
        if !check.found { return .notFound }
        if check.peerTCP.answered {
            if check.noForwardSecrecy > 0 { return .noForwardSecrecy }
            if check.handshakeFailures > 0 { return .handshake }
            // TCP gets through yet Halo's own connections stall: not something these probes can explain.
            return check.dialTimeouts > 0 ? .unknown : .ok
        }
        if check.peerTCP == .timedOut { return check.ping == .ok ? .tcpBlocked : .peerSilent }
        return .unknown
    }

    /// Both Macs' views together. A drop seen from either side is the finding; otherwise this Mac's own view stands.
    public static func of(_ local: LinkCheck, peer: LinkCheck?) -> LinkVerdict {
        let own = of(local)
        guard let peer else { return own }
        let theirs = of(peer)
        if own == .tcpBlocked || theirs == .tcpBlocked { return .tcpBlocked }
        if own == .localNetwork || theirs == .localNetwork { return .localNetwork }
        return own
    }
}
