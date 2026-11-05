import AppKit

if SnapshotCommand.runIfRequested() || NowPlayingPreview.runIfRequested() || KoiFacePreview.runIfRequested() || AppIconCommand.runIfRequested()
    || LaunchChargePreview.runIfRequested() { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
