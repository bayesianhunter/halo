// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

/// One side of a pairing by numeric comparison, as Bluetooth pairs a keyboard: no code is typed. Each Mac makes a
/// one-time X25519 key and first sends only a commitment to it (a hash); once it has the other side's commitment, it
/// sends the key itself, and checks that the other's key matches what was committed. Both then show the same six
/// digits, taken from everything exchanged, and the person confirms on each Mac that they match.
///
/// Someone on the network who sits between the two must commit to a key toward each Mac before seeing that Mac's
/// key, so within one exchange on each Mac the six digits come out the same only by chance: one in a million. That
/// holds per attempt only if each Mac runs a single exchange per attempt; one that answered many connections would let
/// the stranger keep whichever pair of them matched, so the caller must reveal at most once per attempt. The
/// connection the exchange runs on needs no secret of its own. The long-term key never crosses the wire.
public struct PairingExchange {
    public enum Failure: Error, Equatable {
        /// A message out of turn: a reveal before the commitment, a second commitment.
        case outOfOrder
        /// The key revealed is not the one committed to.
        case commitmentBroken
        /// The other side is this Mac, or its key cannot be used.
        case unusable
    }

    public let own: LinkPairing
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private var peerCommitment: Data?
    public private(set) var peer: LinkPairing?
    /// The long-term key, once both keys are known; stored only after both people confirm.
    public private(set) var key: Data?
    private var transcript = Data()

    public init(id: String, computer: String, privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.privateKey = privateKey
        own = LinkPairing(peer: id, computer: LinkText.clean(computer), key: privateKey.publicKey.rawRepresentation)
    }

    /// Sent first, on connecting.
    public var commitment: Data { Self.commitment(to: own) }

    /// Whether the other side's commitment has arrived.
    public var committed: Bool { peerCommitment != nil }

    /// The other side's commitment; the answer is this side's key, sent only now.
    public mutating func received(commitment: Data) throws -> LinkPairing {
        guard peerCommitment == nil, commitment.count == SHA256.byteCount else { throw Failure.outOfOrder }
        peerCommitment = commitment
        return own
    }

    /// The other side's key, checked against its commitment; the answer is the six digits to show.
    public mutating func received(reveal: LinkPairing) throws -> String {
        guard let peerCommitment, peer == nil else { throw Failure.outOfOrder }
        guard Self.commitment(to: reveal) == peerCommitment else { throw Failure.commitmentBroken }
        guard reveal.peer != own.peer, reveal.key != own.key,
              let key = try? LinkKeys.longTermKey(own: privateKey, peerKey: reveal.key, ids: [own.peer, reveal.peer]) else {
            throw Failure.unusable
        }
        // Both sides put the two halves in the same order, the one with the lower ID first.
        let halves = [own, reveal].sorted { $0.peer < $1.peer }
        transcript = halves.map(Self.encode).reduce(Data(), +)
        let digest = Data(SHA256.hash(data: Data("Halo Link code v2".utf8) + transcript))
        let number = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        peer = reveal
        self.key = key
        return String(format: "%06d", number)
    }

    /// Sent once the person here has confirmed the digits match, so neither Mac keeps a pairing the other gave up. It
    /// proves only that the sender holds the same key from the same exchange; what keeps a stranger in the middle out
    /// is the people comparing the digits.
    public var confirmation: Data? { key.map { proof(by: own.peer, key: $0) } }

    /// Whether the other side's confirmation was made with the same key over the same exchange.
    public func accepts(confirmation: Data) -> Bool {
        guard let key, let peer else { return false }
        return confirmation == proof(by: peer.peer, key: key)
    }

    private func proof(by id: String, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("Halo Link confirm v2".utf8) + Data(id.utf8) + transcript,
                                             using: SymmetricKey(data: key)))
    }

    static func commitment(to pairing: LinkPairing) -> Data {
        Data(SHA256.hash(data: Data("Halo Link commit v2".utf8) + encode(pairing)))
    }

    /// Each field with its length in front, so no two different pairings encode alike.
    static func encode(_ pairing: LinkPairing) -> Data {
        [Data(pairing.peer.utf8), Data(pairing.computer.utf8), pairing.key].reduce(into: Data()) { data, field in
            withUnsafeBytes(of: UInt32(field.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(field)
        }
    }
}
