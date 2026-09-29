import AppKit

// A normal app (window + Dock icon) that also lives in the menu bar; see AppDelegate.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
