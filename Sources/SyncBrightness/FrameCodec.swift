import Foundation

/// Length-prefixed (UInt32 big-endian) framing, matching ColorSyncTransport.
enum FrameCodec {
  static let maxBody = 4_000_000

  static func encode(_ body: Data) -> Data {
    var frame = Data()
    var len = UInt32(body.count).bigEndian
    withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
    frame.append(body)
    return frame
  }
}

/// Incremental decoder: push bytes as they arrive, get back any complete bodies.
struct FrameDecoder {
  private var buffer = Data()
  private(set) var failed = false

  mutating func push<S: Sequence>(_ bytes: S) -> [Data] where S.Element == UInt8 {
    if failed { return [] }
    buffer.append(contentsOf: bytes)
    var out: [Data] = []
    while buffer.count >= 4 {
      let len = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      if Int(len) > FrameCodec.maxBody { failed = true; return out }
      guard buffer.count >= 4 + Int(len) else { break }
      let start = buffer.index(buffer.startIndex, offsetBy: 4)
      let end = buffer.index(start, offsetBy: Int(len))
      out.append(Data(buffer[start..<end]))
      buffer.removeSubrange(buffer.startIndex..<end)
    }
    return out
  }
}
