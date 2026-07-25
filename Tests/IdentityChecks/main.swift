// Framework-free checks for DisplayIdentity — runs with only the Command Line
// Tools. Built by ./run-tests.sh, which compiles this together with the real
// Sources/.../DisplayIdentity.swift so it exercises the actual implementation.
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

print("DisplayIdentity.uniqued")

check(DisplayIdentity.uniqued([]) == [], "empty list stays empty")
check(DisplayIdentity.uniqued(["DEL-U2720Q-123"]) == ["DEL-U2720Q-123"],
      "a lone id is untouched (existing profiles keep loading)")
check(DisplayIdentity.uniqued(["a", "b", "c"]) == ["a", "b", "c"], "distinct ids are untouched")

// Two identical monitors with no EDID serial produce the same id.
check(DisplayIdentity.uniqued(["dup", "dup"]) == ["dup", "dup#2"],
      "a duplicate is suffixed, the first occurrence is not")
check(DisplayIdentity.uniqued(["dup", "dup", "dup"]) == ["dup", "dup#2", "dup#3"],
      "three of a kind number upward")
check(DisplayIdentity.uniqued(["a", "b", "a", "b"]) == ["a", "b", "a#2", "b#2"],
      "interleaved duplicates each get their own counter")

// A generated suffix must not collide with an id that already looks like one.
check(DisplayIdentity.uniqued(["x", "x#2", "x"]) == ["x", "x#2", "x#3"],
      "skips a suffix that is already taken")

print("DisplayIdentity.disambiguated")

check(DisplayIdentity.disambiguated(names: ["Studio Display"]) == ["Studio Display"],
      "a unique name is left alone")
check(DisplayIdentity.disambiguated(names: ["Dell U2720Q", "Dell U2720Q"])
  == ["Dell U2720Q (1)", "Dell U2720Q (2)"], "repeated names are numbered from 1")
check(DisplayIdentity.disambiguated(names: ["A", "B", "A"]) == ["A (1)", "B", "A (2)"],
      "only the repeated name is numbered, order preserved")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
