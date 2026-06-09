import Cocoa
import CoreImage

enum ColorSyncQR {
  /// Encode connection info as a compact URL the iOS app parses:
  /// mbsync://pair?h=<host>&p=<port>&k=<psk-percent-encoded>
  static func payload(host: String, port: UInt16, psk: String) -> String {
    let k = psk.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? psk
    return "mbsync://pair?h=\(host)&p=\(port)&k=\(k)"
  }

  static func image(for string: String, scale: CGFloat = 10) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(string.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    else { return nil }
    let rep = NSCIImageRep(ciImage: out)
    let img = NSImage(size: rep.size); img.addRepresentation(rep)
    return img
  }
}
