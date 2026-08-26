import Cocoa

let app = NSApplication.shared

if let diag = ProcessInfo.processInfo.environment["SYNCBRIGHTNESS_DIAG"], !diag.isEmpty {
  Diagnostics.run(writeProbe: diag == "write") // =write also exercises a DDC write
  exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar agent, no Dock icon
app.run()
