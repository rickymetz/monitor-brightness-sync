import Foundation

/// Pairing info carried by the QR code: `mbsync://pair?h=<host>&p=<port>&k=<psk>`.
/// `k` is percent-encoded so the base64 PSK's +, /, = survive. Pure + shared.
struct PairingPayload: Equatable {
  let host: String
  let port: UInt16
  let psk: String

  static func build(host: String, port: UInt16, psk: String) -> String {
    let k = psk.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? psk
    let h = host.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? host
    return "mbsync://pair?h=\(h)&p=\(port)&k=\(k)"
  }

  static func parse(_ string: String) -> PairingPayload? {
    guard let comps = URLComponents(string: string),
          comps.scheme == "mbsync", comps.host == "pair",
          let items = comps.queryItems else { return nil }
    func value(_ name: String) -> String? {
      items.first(where: { $0.name == name })?.value
    }
    guard let h = value("h"), let pStr = value("p"), let port = UInt16(pStr),
          let k = value("k") else { return nil }
    return PairingPayload(host: h, port: port, psk: k)
  }
}
