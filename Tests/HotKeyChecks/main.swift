// Framework-free checks for KeyCombo — runs with only the Command Line Tools.
// Built by ./run-tests.sh, which compiles this together with the real
// Sources/.../HotKey.swift so it exercises the actual implementation.
import Carbon
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

print("KeyCombo checks")

// AppKit modifier flags -> Carbon modifier mask.
check(KeyCombo.carbonModifiers(from: [.control, .option]) == UInt32(controlKey | optionKey),
      "⌃⌥ maps to control+option")
check(KeyCombo.carbonModifiers(from: [.command]) == UInt32(cmdKey), "⌘ maps to cmdKey")
check(KeyCombo.carbonModifiers(from: [.command, .shift]) == UInt32(cmdKey | shiftKey),
      "⌘⇧ maps to cmd+shift")
check(KeyCombo.carbonModifiers(from: []) == 0, "no modifiers -> 0")
// Flags outside the set we care about are ignored.
check(KeyCombo.carbonModifiers(from: [.capsLock]) == 0, "caps lock is ignored")

// Defaults are the ⌃⌥ arrow keys.
let up = KeyCombo.defaultUp
check(up.keyCode == 126, "default up is the Up arrow (126)")
check(up.carbonModifiers == UInt32(controlKey | optionKey), "default up uses ⌃⌥")
check(up.display == "⌃⌥↑", "default up displays ⌃⌥↑")
let down = KeyCombo.defaultDown
check(down.keyCode == 125, "default down is the Down arrow (125)")
check(down.display == "⌃⌥↓", "default down displays ⌃⌥↓")

// Codable round-trip (persisted in UserDefaults).
if let data = try? JSONEncoder().encode(up),
   let decoded = try? JSONDecoder().decode(KeyCombo.self, from: data) {
  check(decoded == up, "Codable round-trip preserves the combo")
} else {
  check(false, "Codable round-trip")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
