import Foundation
import Network
import Security

/// Connects to the Mac coordinator over TLS-PSK and exchanges length-prefixed
/// JSON frames.  Mirrors macOS ColorSyncTransport exactly:
///   • identity  : "colorsync"
///   • PSK       : Data(psk.utf8)   (psk is the percent-decoded base64 string)
///   • cipher    : TLS_PSK_WITH_AES_128_GCM_SHA256
///   • framing   : UInt32 BE length prefix (FrameCodec / FrameDecoder)
///
/// Concurrency design
/// ------------------
/// `ColorSyncClient` is `@MainActor` (ObservableObject for SwiftUI).
/// All NWConnection callbacks and the mutable `FrameDecoder` live inside the
/// non-isolated `Receiver` helper, which is confined to its own
/// `DispatchQueue`.  `Receiver` hops back to the main actor via a
/// `@Sendable` closure for status changes and decoded messages.
@MainActor
final class ColorSyncClient: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published var status: Status = .idle

    /// Called on the main actor for each decoded `MacToPhone` message.
    var onMessage: ((MacToPhone) -> Void)?

    private var receiver: Receiver?

    func connect(_ payload: PairingPayload) {
        status = .connecting
        let r = Receiver(
            payload: payload,
            onStatus: { [weak self] s in Task { @MainActor in self?.status = s } },
            onMessage: { [weak self] msg in Task { @MainActor in self?.onMessage?(msg) } }
        )
        receiver = r
        r.start()
    }

    func disconnect() {
        receiver?.stop()
        receiver = nil
    }

    func send(_ message: PhoneToMac) {
        receiver?.send(message)
    }
}

// MARK: - Receiver (non-isolated, lives on its own queue)

/// Owns the `NWConnection` and `FrameDecoder`.  All mutation happens on
/// `queue`; results are forwarded via `@Sendable` closures.
private final class Receiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mbsync.client")
    private var connection: NWConnection?
    private var decoder = FrameDecoder()

    private let onStatus: @Sendable (ColorSyncClient.Status) -> Void
    private let onMessage: @Sendable (MacToPhone) -> Void

    init(
        payload: PairingPayload,
        onStatus: @escaping @Sendable (ColorSyncClient.Status) -> Void,
        onMessage: @escaping @Sendable (MacToPhone) -> Void
    ) {
        self.onStatus = onStatus
        self.onMessage = onMessage

        // Build TLS-PSK params matching ColorSyncTransport byte-for-byte.
        let tls = NWProtocolTLS.Options()
        let pskData = Data(payload.psk.utf8)
        let idData = Data("colorsync".utf8)
        let pskDD = pskData.withUnsafeBytes { DispatchData(bytes: $0) }
        let idDD  = idData.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            pskDD as __DispatchData,
            idDD  as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)

        let params = NWParameters(tls: tls)
        guard let port = NWEndpoint.Port(rawValue: payload.port) else {
            onStatus(.failed("bad port"))
            return
        }
        let conn = NWConnection(
            host: NWEndpoint.Host(payload.host),
            port: port,
            using: params)
        self.connection = conn
    }

    func start() {
        guard let conn = connection else { return }
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStatus(.connected)
                self.send(.paired)
            case .failed(let e):
                self.onStatus(.failed("\(e)"))
            case .cancelled:
                self.onStatus(.idle)
            default:
                break
            }
        }
        receive(conn)
        conn.start(queue: queue)
    }

    func stop() {
        connection?.cancel()
        connection = nil
    }

    func send(_ message: PhoneToMac) {
        guard let conn = connection,
              let body = try? JSONEncoder().encode(message) else { return }
        conn.send(content: FrameCodec.encode(body), completion: .contentProcessed { _ in })
    }

    // MARK: - Receive loop

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                let bodies = self.decoder.push(data)
                for body in bodies {
                    if let msg = try? JSONDecoder().decode(MacToPhone.self, from: body) {
                        self.onMessage(msg)
                    }
                }
            }
            if isDone || err != nil { conn.cancel(); return }
            self.receive(conn)
        }
    }
}
