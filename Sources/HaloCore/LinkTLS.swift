// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Network
import Security

/// The link's encryption: TLS 1.2 keyed by the paired key, with an ephemeral elliptic-curve exchange on top (ECDHE_PSK),
/// so each connection gets a key of its own. Traffic recorded today stays unreadable even if the paired key leaks
/// later. The system still accepts plain PSK whatever suites are listed (a peer that offers only that gets it), so
/// a connection is checked once ready and refused unless the exchange really happened.
public enum LinkTLS {
    /// RFC 7905. Measured on macOS 27: both ends listing it negotiate it; one end not listing it falls back to plain PSK.
    public static let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!

    public static func configure(_ options: sec_protocol_options_t, key: Data, identity: String) {
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let name = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, name as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, suite)
        // Pre-shared keys as set here are a TLS 1.2 mechanism; 1.3 would look for certificates instead.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
    }

    /// Nil for a connection without TLS (pairing); otherwise whether it negotiated the forward-secret suite.
    public static func forwardSecret(_ connection: NWConnection) -> Bool? {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(tls.securityProtocolMetadata) == suite
    }
}
