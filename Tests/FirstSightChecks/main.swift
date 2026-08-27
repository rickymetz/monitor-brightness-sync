// Framework-free checks for first-sight enrollment — runs with only the Command
// Line Tools (XCTest/swift-testing need full Xcode). Built by ./run-tests.sh,
// which compiles this together with the real Sources/.../FirstSight.swift, so it
// exercises the actual implementation.
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

let displayLink = FirstSightMonitor(id: "sw-10635-10049-244", prefersDefaultDisabled: false)
let appleTV = FirstSightMonitor(id: "sw-1552-99-3", prefersDefaultDisabled: true)

print("FirstSight enrollment checks")

// 1. A brand new ordinary display enrolls syncing.
do {
  let r = FirstSight.enroll([displayLink], seen: [], disabled: [])
  check(r.newlySeen, "a new display is newly seen")
  check(r.seen == [displayLink.id], "it joins the seen set")
  check(r.disabled.isEmpty, "an ordinary display enrolls enabled")
  check(!r.disabledChanged, "nothing to persist in the disabled set")
}

// 2. A brand new Apple-vendor display (AirPlay target, Sidecar iPad) enrolls
//    switched off, so a session doesn't start by dimming the living-room TV.
do {
  let r = FirstSight.enroll([appleTV], seen: [], disabled: [])
  check(r.seen == [appleTV.id], "it joins the seen set")
  check(r.disabled == [appleTV.id], "an Apple-vendor display enrolls disabled")
  check(r.disabledChanged, "the disabled set needs persisting")
}

// 3. The point of the seen set: a display already seen keeps the user's choice.
//    Without this, every relaunch would re-disable an Apple-vendor display the
//    user had deliberately switched on.
do {
  let r = FirstSight.enroll([appleTV], seen: [appleTV.id], disabled: [])
  check(!r.newlySeen, "an already-seen display is not re-enrolled")
  check(r.disabled.isEmpty, "the user's choice to enable it survives")
  check(!r.disabledChanged, "nothing is persisted")
  check(r.seen == [appleTV.id], "the seen set is unchanged")
}

// 4. A seen display the user switched off stays off, and stays off exactly once.
do {
  let r = FirstSight.enroll([displayLink], seen: [displayLink.id], disabled: [displayLink.id])
  check(!r.newlySeen, "no re-enrollment")
  check(r.disabled == [displayLink.id], "the user's disable is left alone")
  check(!r.disabledChanged, "and is not rewritten")
}

// 5. Mixed: one known display, one new one. Only the new one is decided, and
//    the known display's state is carried through untouched.
do {
  let r = FirstSight.enroll([displayLink, appleTV], seen: [displayLink.id], disabled: [])
  check(r.newlySeen, "the new display is newly seen")
  check(r.seen == [displayLink.id, appleTV.id], "both are now seen")
  check(r.disabled == [appleTV.id], "only the new Apple-vendor display is disabled")
}

// 6. Idempotent: feeding the outcome back in (the app re-enters via onMonitors
//    after pushing the new disabled set) decides nothing further.
do {
  let first = FirstSight.enroll([displayLink, appleTV], seen: [], disabled: [])
  let second = FirstSight.enroll([displayLink, appleTV], seen: first.seen, disabled: first.disabled)
  check(!second.newlySeen, "the second pass enrolls nothing")
  check(!second.disabledChanged, "and persists nothing")
  check(second.seen == first.seen && second.disabled == first.disabled, "state is stable")
}

// 7. An empty scan (all displays unplugged) changes nothing.
do {
  let r = FirstSight.enroll([], seen: [displayLink.id], disabled: [appleTV.id])
  check(!r.newlySeen && !r.disabledChanged, "no displays, no decisions")
  check(r.seen == [displayLink.id] && r.disabled == [appleTV.id], "existing state is preserved")
}

print(failures == 0 ? "\nAll FirstSight enrollment checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
