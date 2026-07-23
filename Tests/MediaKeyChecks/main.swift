// Framework-free checks for BrightnessKeyDecoder — runs with only the Command
// Line Tools. Built by ./run-tests.sh, which compiles this together with the
// real Sources/.../MediaKeyTap.swift so it exercises the actual implementation.
import Cocoa
import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String) {
  if condition {
    print("  ✓ \(message)")
  } else {
    print("  ✗ \(message)")
    failures += 1
  }
}

// NSSystemDefined form: key code in the high word, key state in bits 8-15.
func data1(keyCode: Int, down: Bool) -> Int {
  (keyCode << 16) | ((down ? 0x0A : 0x0B) << 8)
}

print("systemDefined form")
check(BrightnessKeyDecoder.systemDefined(subtype: 8, data1: data1(keyCode: 2, down: true))
  == BrightnessKeyPress(increase: true, isKeyDown: true), "brightness up, key down")
check(BrightnessKeyDecoder.systemDefined(subtype: 8, data1: data1(keyCode: 3, down: false))
  == BrightnessKeyPress(increase: false, isKeyDown: false), "brightness down, key up")
check(BrightnessKeyDecoder.systemDefined(subtype: 8, data1: data1(keyCode: 7, down: true)) == nil,
      "other media keys ignored")
check(BrightnessKeyDecoder.systemDefined(subtype: 7, data1: data1(keyCode: 2, down: true)) == nil,
      "non-media subtype ignored")

// Plain key form — what Apple keyboards send on recent macOS (keycodes 144/145).
print("plain key form")
check(BrightnessKeyDecoder.plainKey(keyCode: 144, isKeyDown: true)
  == BrightnessKeyPress(increase: true, isKeyDown: true), "144 is brightness up")
check(BrightnessKeyDecoder.plainKey(keyCode: 145, isKeyDown: true)
  == BrightnessKeyPress(increase: false, isKeyDown: true), "145 is brightness down")
check(BrightnessKeyDecoder.plainKey(keyCode: 145, isKeyDown: false)
  == BrightnessKeyPress(increase: false, isKeyDown: false), "key up decodes as key up")
check(BrightnessKeyDecoder.plainKey(keyCode: 0, isKeyDown: true) == nil, "'a' is not a brightness key")
check(BrightnessKeyDecoder.plainKey(keyCode: 117, isKeyDown: true) == nil, "fwd-delete is not a brightness key")

if failures > 0 {
  print("\(failures) check(s) failed")
  exit(1)
}
print("all checks passed")
