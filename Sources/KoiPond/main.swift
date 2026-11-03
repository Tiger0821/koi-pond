import AppKit

if SnapshotCommand.runIfRequested() || NowPlayingPreview.runIfRequested() || KoiFacePreview.runIfRequested() { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
