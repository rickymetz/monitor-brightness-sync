import Foundation

/// Appends color-sync diagnostics to a file so the measurement, computed gains,
/// and side-by-side verify can be inspected without screenshots. Path defaults to
/// /tmp/mbsync-colorsync.log (override with MBSYNC_COLORSYNC_LOG). Best-effort.
enum ColorSyncDebugLog {
  static let path: String =
    ProcessInfo.processInfo.environment["MBSYNC_COLORSYNC_LOG"] ?? "/tmp/mbsync-colorsync.log"

  static func log(_ message: String) {
    let line = "[\(timestamp())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: path) {
      defer { try? fh.close() }
      fh.seekToEndOfFile()
      fh.write(data)
    } else {
      try? data.write(to: URL(fileURLWithPath: path))
    }
  }

  /// Mark the start of a fresh session so old runs are easy to ignore.
  static func session(_ label: String) {
    log("==== \(label) ====")
  }

  private static func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
  }
}
