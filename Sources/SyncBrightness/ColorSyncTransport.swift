import Foundation
import Network
import CryptoKit
import Security

/// LAN transport for color sync: a TLS-PSK NWListener that frames length-prefixed
/// JSON. Conforms to ColorSyncPeer (sends MacToPhone), and surfaces decoded
/// PhoneToMac messages on the main queue.
final class ColorSyncTransport: ColorSyncPeer {
  struct ConnectionInfo { let host: String; let port: UInt16; let psk: String }
  enum TransportError: Error { case portUnavailable }

  private let queue = DispatchQueue(label: "colorsync.transport")
  private var listener: NWListener?
  private var connection: NWConnection?
  private let psk: String
  private var port: UInt16 = 0

  var onReceive: ((PhoneToMac) -> Void)?
  var onClientConnected: (() -> Void)?

  init() {
    self.psk = ColorSyncTransport.randomPSK()
  }

  /// Start listening; returns the info to encode in the QR.
  func start() throws -> ConnectionInfo {
    let opts = NWProtocolTLS.Options()
    let pskData = Data(psk.utf8)
    let identityData = Data("colorsync".utf8)
    let pskDD = pskData.withUnsafeBytes { DispatchData(bytes: $0) }
    let idDD  = identityData.withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(opts.securityProtocolOptions,
        pskDD as __DispatchData, idDD as __DispatchData)
    sec_protocol_options_append_tls_ciphersuite(opts.securityProtocolOptions,
        tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    let params = NWParameters(tls: opts)
    let listener = try NWListener(using: params)
    self.listener = listener
    // `listener.port` reports 0 ("unassigned") until the OS binds an ephemeral
    // port at `.ready`, so wait on the state rather than polling the port — and
    // surface a startup failure instead of swallowing it (an empty handler here
    // is what made an earlier bug undiagnosable).
    let ready = DispatchSemaphore(value: 0)
    var startupError: Error?
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready: ready.signal()
      case .failed(let error): startupError = error; ready.signal()
      case .waiting(let error): startupError = error  // may still recover; kept for diagnostics
      default: break
      }
    }
    listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
    listener.start(queue: queue)
    if ready.wait(timeout: .now() + 5) == .timedOut {
      listener.cancel()
      throw startupError ?? TransportError.portUnavailable
    }
    if let error = startupError, listener.port == nil {
      listener.cancel()
      throw error
    }
    guard let assigned = listener.port?.rawValue, assigned != 0 else {
      listener.cancel()
      throw TransportError.portUnavailable
    }
    port = assigned
    let host = CalibrationHost.lanIPv4() ?? "127.0.0.1"
    return ConnectionInfo(host: host, port: port, psk: psk)
  }

  func stop() {
    connection?.cancel(); connection = nil
    listener?.cancel(); listener = nil
  }

  private func accept(_ conn: NWConnection) {
    connection?.cancel()
    connection = conn
    var didNotifyConnected = false
    conn.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      if case .ready = state, !didNotifyConnected {
        didNotifyConnected = true
        DispatchQueue.main.async { self.onClientConnected?() }
      }
    }
    conn.start(queue: queue)
    receiveFrame(conn)
  }

  // MARK: ColorSyncPeer
  func send(_ message: MacToPhone) {
    guard let conn = connection, let body = try? JSONEncoder().encode(message) else { return }
    var frame = Data()
    var len = UInt32(body.count).bigEndian
    withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
    frame.append(body)
    conn.send(content: frame, completion: .contentProcessed { _ in })
  }

  // Length-prefixed (UInt32 BE) JSON frames.
  private func receiveFrame(_ conn: NWConnection) {
    conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, err in
      guard let self, let header, header.count == 4, err == nil else { conn.cancel(); return }
      let len = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
      guard len > 0, len < 4_000_000 else { conn.cancel(); return }
      conn.receive(minimumIncompleteLength: Int(len), maximumLength: Int(len)) { body, _, _, err2 in
        guard let body, err2 == nil else { conn.cancel(); return }
        if let msg = try? JSONDecoder().decode(PhoneToMac.self, from: body) {
          DispatchQueue.main.async { self.onReceive?(msg) }
        }
        self.receiveFrame(conn)
      }
    }
  }

  private static func randomPSK() -> String {
    let key = SymmetricKey(size: .bits128)
    return key.withUnsafeBytes { Data($0).base64EncodedString() }
  }
}

/// LAN IPv4 helper (first non-loopback en* interface).
enum CalibrationHost {
  static func lanIPv4() -> String? {
    var address: String?
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
      let flags = Int32(cur.pointee.ifa_flags)
      let fam = cur.pointee.ifa_addr.pointee.sa_family
      if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
         fam == UInt8(AF_INET),
         let name = cur.pointee.ifa_name, String(cString: name).hasPrefix("en") {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(cur.pointee.ifa_addr, socklen_t(cur.pointee.ifa_addr.pointee.sa_len),
                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        let ip = String(cString: host)
        if !ip.hasPrefix("127.") { address = ip; break }
      }
      p = cur.pointee.ifa_next
    }
    freeifaddrs(ifap)
    return address
  }
}
