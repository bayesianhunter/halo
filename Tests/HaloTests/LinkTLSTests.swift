// SPDX-License-Identifier: GPL-3.0-only
import Network
import Security
import XCTest
@testable import HaloCore

/// The link's TLS over loopback: two current ends get a key per connection; an end that offers only plain PSK
/// still connects at the TLS level, and the check is what tells it apart.
final class LinkTLSTests: XCTestCase {
    let key = Data((0..<32).map(UInt8.init))

    private func parameters(_ configure: (sec_protocol_options_t) -> Void) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        configure(tls.securityProtocolOptions)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredInterfaceType = .loopback
        return parameters
    }

    private var current: NWParameters { parameters { LinkTLS.configure($0, key: key, identity: "halo-link") } }

    /// A link set up with plain PSK, no forward secrecy: what Halo refuses.
    private var plainPSK: NWParameters {
        parameters { options in
            let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let name = Data("halo-link".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, name as __DispatchData)
            sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
            sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        }
    }

    /// Connects a client to a listener and reports what the check says on each end once both are ready.
    private func handshake(server: NWParameters, client: NWParameters) throws -> (server: Bool?, client: Bool?) {
        let listener = try NWListener(using: server, on: .any)
        // Everything below runs on this one queue; the test thread reads the results only after the waits.
        let queue = DispatchQueue(label: "link-tls-test")
        var accepted: NWConnection?
        var serverResult: Bool??
        let serverReady = expectation(description: "server side ready")
        listener.newConnectionHandler = { connection in
            accepted = connection
            connection.stateUpdateHandler = { state in
                guard case .ready = state, serverResult == nil else { return }
                serverResult = LinkTLS.forwardSecret(connection)
                serverReady.fulfill()
            }
            connection.start(queue: queue)
        }
        let listening = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 5)

        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: client)
        let clientDone = expectation(description: "client settled")
        var clientResult: Bool??
        var settled = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: clientResult = LinkTLS.forwardSecret(connection)
            case .failed, .waiting: break
            default: return
            }
            guard !settled else { return }
            settled = true
            clientDone.fulfill()
        }
        connection.start(queue: queue)
        wait(for: [clientDone, serverReady], timeout: 5)
        queue.sync {
            connection.cancel()
            accepted?.cancel()
            listener.cancel()
        }
        // Nil for a side that never got ready, which the callers' expectations treat as a failure.
        return queue.sync { (server: serverResult ?? nil, client: clientResult ?? nil) }
    }

    func testCurrentEndsGetAKeyPerConnection() throws {
        let ends = try handshake(server: current, client: current)
        XCTAssertEqual(ends.server, true)
        XCTAssertEqual(ends.client, true)
    }

    /// Halo may be either end: dialing an older Mac, or accepting its dial. Both ends see the plain suite.
    func testAnOlderEndIsToldApartOnEitherSide() throws {
        let dialing = try handshake(server: plainPSK, client: current)
        XCTAssertEqual(dialing.client, false, "Halo dialing an older Mac")
        let accepting = try handshake(server: current, client: plainPSK)
        XCTAssertEqual(accepting.server, false, "Halo accepting an older Mac's dial")
    }

    func testAConnectionWithoutTLSIsNotJudged() throws {
        let ends = try handshake(server: NWParameters.tcp.loopback, client: NWParameters.tcp.loopback)
        XCTAssertNil(ends.server)
        XCTAssertNil(ends.client)
    }
}

private extension NWParameters {
    var loopback: NWParameters { requiredInterfaceType = .loopback; return self }
}
