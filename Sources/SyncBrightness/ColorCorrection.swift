import Foundation

/// A linear RGB triple in 0...1 (measured camera values or display patch colors).
struct RGB: Equatable, Codable {
  var r: Double
  var g: Double
  var b: Double
}

/// Per-channel correction applied to a display's gamma table. Gains are output
/// multipliers in 0...1 (we can only attenuate a channel, not exceed native).
struct ColorCorrection: Codable, Equatable {
  var redGain: Double
  var greenGain: Double
  var blueGain: Double
  var gamma: Double

  static let identity = ColorCorrection(redGain: 1, greenGain: 1, blueGain: 1, gamma: 1)
}

/// Median patch colors sampled from one photo. Codable for transport over the wire.
struct PatchSamples: Equatable, Codable {
  var white: RGB
  var gray50: RGB
  var gray25: RGB
  var red: RGB
  var green: RGB
  var blue: RGB
}
