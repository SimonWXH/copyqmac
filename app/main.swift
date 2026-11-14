// Entry point. An explicit NSApplication rather than a SwiftUI `App` because a
// menu-bar-only app needs an AppKit delegate for the status item, the Carbon
// hotkey, and the non-activating panel.
//
// Top-level code is not main-actor isolated by default, but it does run on the
// main thread, so assumeIsolated is accurate here.

import AppKit

// One-time maintenance path for stores written before internal bookkeeping
// flavours were treated as internal. The flag is required so an ordinary
// launch, capture, or import never deletes anything; the sweep runs headless,
// prints what it removed per tab, and exits.
if CommandLine.arguments.contains("--cleanup-internal-marker-entries") {
    exit(runInternalMarkerCleanup())
}

func runInternalMarkerCleanup() -> Int32 {
    do {
        let store = try ClipboardStore.openDefault()
        let report = try InternalMarkerCleanup.removeMarkerOnlyEntries(in: store)
        print("Internal marker cleanup: \(try ClipboardStore.defaultURL().path)")
        print(report.summary)
        return 0
    } catch {
        FileHandle.standardError.write(Data("Internal marker cleanup failed: \(error)\n".utf8))
        return 1
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
