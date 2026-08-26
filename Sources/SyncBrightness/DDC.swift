import CDDC
import CoreGraphics
import Foundation
import IOKit

// DDC/CI VCP feature code for luminance (brightness).
let kVCPBrightness: UInt8 = 0x10

private let kDDC7BitAddress: UInt8 = 0x37
private let kDDCDataAddress: UInt8 = 0x51

/// Lightweight identity for a connected external display, used by the UI.
struct DisplayInfo: Equatable {
  let id: String
  let name: String
}

/// Richer per-monitor state for the control window.
struct MonitorState: Equatable {
  let id: String
  let name: String
  var enabled: Bool
  var healthy: Bool
  var brightness: Double // current external fraction 0...1
}

/// One external display reachable over DDC/CI via its IOAVService.
final class ExternalDisplay {
  /// Nil when the display has no DDC/CI channel (DisplayLink, some hubs, some
  /// TVs). Such a display can still be dimmed via the gamma table.
  let service: IOAVService?
  /// A display with no DDC channel is permanently in the gamma-follow state that
  /// this class already models — there is no backlight to talk to.
  var isSoftwareOnly: Bool { service == nil }
  /// Stable identity (manufacturer/product/serial) used as the profile key.
  let id: String
  let name: String
  let serialNumber: Int64
  /// CoreGraphics display id, resolved separately (needed for gamma dimming).
  var cgDisplayID: CGDirectDisplayID?
  /// The calibration curve currently applied to this display.
  var curve = BrightnessCurve.default
  /// Cached maximum brightness value the monitor reports (e.g. 100). Defaults
  /// to 100 if the monitor does not answer a read.
  private(set) var maxBrightness: UInt16 = 100
  /// Whether the most recent DDC write was accepted (IOReturn OK).
  private(set) var lastWriteOK = true
  /// Whether the monitor answers DDC reads. If not, we treat its DDC controller
  /// as flaky and send single-shot writes (no retries) to avoid wedging it.
  private(set) var readResponsive = true
  /// Last fraction we set, used for smooth ramping.
  private(set) var lastSetFraction: Double?
  /// When DDC writes are refused, we follow the built-in via software gamma
  /// instead so the display still tracks brightness (non-DDC monitors, some
  /// USB-C hubs, etc.). These record that fallback for the UI.
  private(set) var followsViaGamma = false
  private(set) var gammaFollowLevel = 1.0

  var info: DisplayInfo { DisplayInfo(id: id, name: name) }
  var currentFraction: Double {
    if followsViaGamma { return gammaFollowLevel }
    // A software-only display we aren't dimming is at the panel's own setting,
    // which is this app's 100% — not 0, which would read as "off" in the UI.
    if isSoftwareOnly { return 1.0 }
    return lastSetFraction ?? 0
  }

  func markGammaFollow(level: Double) {
    followsViaGamma = true
    gammaFollowLevel = max(0.0, min(1.0, level))
  }

  func clearGammaFollow() {
    followsViaGamma = false
    gammaFollowLevel = 1.0
  }

  /// Record a level observed by reading the monitor (e.g. the user turned its
  /// own knob) so our state matches reality without driving the panel.
  func syncObservedLevel(_ fraction: Double) {
    lastSetFraction = max(0.0, min(1.0, fraction))
  }

  /// EDID product id, used to match this monitor to a CoreGraphics display when
  /// the serial number is unreported. 0 means the monitor does not report one.
  let productID: UInt32
  /// Set for software-only displays that should not start dimming on first sight
  /// (AirPlay targets, Sidecar iPads). Consumed by AppDelegate, not here.
  let prefersDefaultDisabled: Bool

  init(service: IOAVService?, id: String, name: String, serialNumber: Int64,
       productID: UInt32 = 0, cgDisplayID: CGDirectDisplayID? = nil,
       prefersDefaultDisabled: Bool = false) {
    self.service = service
    self.id = id
    self.name = name
    self.serialNumber = serialNumber
    self.productID = productID
    self.cgDisplayID = cgDisplayID
    self.prefersDefaultDisabled = prefersDefaultDisabled
  }

  /// Probe the monitor for its reported brightness range. Best-effort; also
  /// records whether the monitor answers reads at all, and seeds our notion of
  /// the current level from the monitor's actual brightness so relative key
  /// adjustments (clamshell/external-only) move from the real value, not 0.
  /// This runs only at scan/wake (not the hot sync loop), so it can retry hard.
  func refreshMaxBrightness() {
    guard let service else { return } // no bus to probe
    if let result = DDC.read(service: service, command: kVCPBrightness, retries: 4), result.max > 0 {
      maxBrightness = result.max
      readResponsive = true
      if lastSetFraction == nil {
        lastSetFraction = max(0.0, min(1.0, Double(result.current) / Double(result.max)))
      }
    } else {
      readResponsive = false
    }
    // Second read path: if DDC wouldn't give us a starting level, ask
    // DisplayServices (the same private API macOS uses) via the CG display id.
    // Many monitors answer this even when raw DDC reads are flaky. Ignore a 0 —
    // that's usually "couldn't read" rather than a genuine zero.
    if lastSetFraction == nil, let cgID = cgDisplayID,
       let fraction = BuiltinBrightness.fraction(of: cgID), fraction > 0 {
      lastSetFraction = fraction
    }
  }

  /// Set brightness from a 0...1 fraction of the monitor's own range. When
  /// `ramp` is set and the jump is large, step through intermediate values for
  /// a smooth transition (used on wake / source switches).
  @discardableResult
  func setBrightness(fraction: Double, ramp: Bool = false) -> Bool {
    let target = max(0.0, min(1.0, fraction))
    var ok = true
    if ramp, let last = lastSetFraction, abs(target - last) > 0.08 {
      let steps = min(8, max(2, Int((abs(target - last) / 0.05).rounded())))
      for s in 1 ... steps {
        let f = last + (target - last) * Double(s) / Double(steps)
        ok = write(fraction: f, retries: 0)
      }
    } else {
      ok = write(fraction: target, retries: readResponsive ? 1 : 0)
    }
    lastSetFraction = target
    lastWriteOK = ok
    return ok
  }

  private func write(fraction: Double, retries: Int) -> Bool {
    guard let service else { return false } // no DDC channel — the caller dims via gamma
    let value = UInt16((fraction * Double(maxBrightness)).rounded())
    return DDC.write(service: service, command: kVCPBrightness, value: value, retries: retries)
  }
}

enum DDC {
  /// Every external display we can drive: over DDC/CI where the monitor speaks
  /// it, and via the gamma table where it does not. `names` is the screen-name
  /// cache from AppDelegate — `NSScreen` is main-thread-only, and this runs on
  /// the sync queue.
  static func externalDisplays(names: [CGDirectDisplayID: String] = [:]) -> [ExternalDisplay] {
    var displays: [ExternalDisplay] = []
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    guard root != 0 else { return displays }
    defer { IOObjectRelease(root) }

    var iterator = io_iterator_t()
    guard IORegistryEntryCreateIterator(root, "IOService", IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
      return displays
    }
    defer { IOObjectRelease(iterator) }

    let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer { nameBuf.deallocate() }

    var lastIdentity = (id: "external", name: "External display", serial: Int64(0), productID: UInt32(0))
    while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
      defer { IOObjectRelease(entry) }
      guard IORegistryEntryGetName(entry, nameBuf) == KERN_SUCCESS else { continue }
      let entryName = String(cString: nameBuf)

      if entryName == "AppleCLCD2" || entryName == "IOMobileFramebufferShim" {
        if let identity = Self.identity(of: entry) {
          lastIdentity = identity
        }
      } else if entryName == "DCPAVServiceProxy" {
        if let location = Self.stringProperty(of: entry, key: "Location"), location == "External",
           let unmanaged = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) {
          let service = unmanaged.takeRetainedValue()
          displays.append(ExternalDisplay(service: service, id: lastIdentity.id, name: lastIdentity.name,
                                          serialNumber: lastIdentity.serial, productID: lastIdentity.productID))
        }
      }
    }
    return displays + Self.attachDisplayIDs(to: displays, names: names)
  }

  /// Assign a CoreGraphics display id to each DDC display, and build an
  /// `ExternalDisplay` for every display no DDC monitor claimed. The rule itself
  /// lives in `DisplayResolver` so it can be unit-tested; this is just the
  /// CoreGraphics plumbing around it.
  static func attachDisplayIDs(to ddcDisplays: [ExternalDisplay],
                               names: [CGDirectDisplayID: String]) -> [ExternalDisplay] {
    let assignment = DisplayResolver.resolve(
      ddc: ddcDisplays.map { DDCCandidate(serial: $0.serialNumber, model: $0.productID) },
      cg: cgCandidates(names: names))

    for (i, display) in ddcDisplays.enumerated() {
      display.cgDisplayID = assignment.ddc[i]
    }
    return assignment.software.map {
      ExternalDisplay(service: nil, id: $0.key, name: $0.name, serialNumber: 0,
                      cgDisplayID: $0.cgID, prefersDefaultDisabled: $0.prefersDefaultDisabled)
    }
  }

  private static func cgCandidates(names: [CGDirectDisplayID: String]) -> [CGDisplayCandidate] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.filter { CGDisplayIsBuiltin($0) == 0 }.map {
      CGDisplayCandidate(id: $0, vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0),
                         serial: CGDisplaySerialNumber($0), unit: CGDisplayUnitNumber($0), name: names[$0])
    }
  }

  // MARK: - Low-level DDC/CI

  /// Write a VCP feature value. Mirrors MonitorControl's proven Arm64 framing:
  /// the operand count doubles as the DDC opcode byte (1 = Get, 3 = Set), and
  /// the source address 0x51 is passed as the I2C offset rather than inlined.
  // Brightness writes are kept deliberately light: one I2C cycle and at most one
  // retry. Flooding a flaky monitor (especially one that fails reads) with DDC
  // traffic can wedge its controller, so the sync loop just tries again on the
  // next tick rather than hammering.
  @discardableResult
  static func write(service: IOAVService, command: UInt8, value: UInt16, retries: Int = 1) -> Bool {
    var send: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 0xFF)]
    var reply: [UInt8] = []
    return communicate(service: service, send: &send, reply: &reply, writeCycles: 1, retries: retries)
  }

  static func read(service: IOAVService, command: UInt8, retries: Int = 1) -> (current: UInt16, max: UInt16)? {
    var send: [UInt8] = [command]
    var reply = [UInt8](repeating: 0, count: 11)
    guard communicate(service: service, send: &send, reply: &reply, writeCycles: 1, retries: retries) else { return nil }
    let maxValue = UInt16(reply[6]) * 256 + UInt16(reply[7])
    let current = UInt16(reply[8]) * 256 + UInt16(reply[9])
    return (current, maxValue)
  }

  private static func communicate(service: IOAVService, send: inout [UInt8], reply: inout [UInt8], writeCycles: Int, retries: Int) -> Bool {
    var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
    let seed: UInt8 = send.count == 1 ? (kDDC7BitAddress << 1) : ((kDDC7BitAddress << 1) ^ kDDCDataAddress)
    packet[packet.count - 1] = checksum(seed: seed, data: packet, start: 0, end: packet.count - 2)

    var success = false
    for _ in 0...retries {
      for _ in 0 ..< max(1, writeCycles) {
        usleep(10000)
        success = IOAVServiceWriteI2C(service, UInt32(kDDC7BitAddress), UInt32(kDDCDataAddress), &packet, UInt32(packet.count)) == 0
      }
      if !reply.isEmpty {
        usleep(50000)
        if IOAVServiceReadI2C(service, UInt32(kDDC7BitAddress), 0, &reply, UInt32(reply.count)) == 0 {
          success = checksum(seed: 0x50, data: reply, start: 0, end: reply.count - 2) == reply[reply.count - 1]
        }
      }
      if success { return true }
      usleep(20000)
    }
    return success
  }

  private static func checksum(seed: UInt8, data: [UInt8], start: Int, end: Int) -> UInt8 {
    var chk = seed
    for i in start...end { chk ^= data[i] }
    return chk
  }

  // MARK: - Debug

  /// Lists every display-related IORegistry entry with its Location, for
  /// diagnosing detection (e.g. why nothing is found in clamshell).
  static func debugServiceDump() -> [String] {
    var lines: [String] = []
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    guard root != 0 else { return ["IORegistry root unavailable"] }
    defer { IOObjectRelease(root) }
    var iterator = io_iterator_t()
    guard IORegistryEntryCreateIterator(root, "IOService", IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
      return ["IORegistry iterator failed"]
    }
    defer { IOObjectRelease(iterator) }
    let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer { nameBuf.deallocate() }

    while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
      defer { IOObjectRelease(entry) }
      guard IORegistryEntryGetName(entry, nameBuf) == KERN_SUCCESS else { continue }
      let name = String(cString: nameBuf)
      if name == "DCPAVServiceProxy" {
        let loc = stringProperty(of: entry, key: "Location") ?? "(none)"
        let created = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) != nil
        lines.append("DCPAVServiceProxy  Location=\(loc)  IOAVService=\(created ? "yes" : "no")")
      } else if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
        lines.append("Framebuffer \(name)  product=\(identity(of: entry)?.name ?? "?")")
      }
    }
    return lines.isEmpty ? ["(no display services found)"] : lines
  }

  // MARK: - IORegistry property helpers

  private static func stringProperty(of entry: io_service_t, key: String) -> String? {
    guard let unmanaged = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) else {
      return nil
    }
    return unmanaged.takeRetainedValue() as? String
  }

  /// Build a display name and a stable profile id from the framebuffer's
  /// product attributes (manufacturer + product + serial).
  private static func identity(of entry: io_service_t) -> (id: String, name: String, serial: Int64, productID: UInt32)? {
    guard let unmanaged = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)),
          let attrs = unmanaged.takeRetainedValue() as? NSDictionary,
          let product = attrs["ProductAttributes"] as? NSDictionary
    else {
      return nil
    }

    let manufacturer = (product["ManufacturerID"] as? String) ?? ""
    let productName = (product["ProductName"] as? String) ?? ""
    let serialNumber = (product["SerialNumber"] as? Int64) ?? 0
    // Some framebuffer shim entries (observed on Apple Silicon) report a
    // "ProductID" far outside the 16-bit EDID product-code range. That is not a
    // real product id, so treat anything that overflows UInt32 as unreported
    // rather than trapping on the narrowing conversion.
    let productID = UInt32(exactly: (product["ProductID"] as? Int) ?? 0) ?? 0
    var serial = ""
    if serialNumber != 0 {
      serial = String(serialNumber)
    } else if let s = product["AlphanumericSerialNumber"] as? String {
      serial = s
    }

    let name = productName.isEmpty ? "External display" : productName
    let parts = [manufacturer, productName, serial].filter { !$0.isEmpty }
    let id = parts.isEmpty ? "external" : parts.joined(separator: "-")
    return (id, name, serialNumber, productID)
  }
}
