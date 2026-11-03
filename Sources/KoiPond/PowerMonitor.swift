import AppKit
import IOKit.ps

/// Tracks battery, Low Power Mode, heat, sleep and screen lock so the pond can slow or rest.
final class PowerMonitor {
    var onChange: (() -> Void)?
    private(set) var onBattery = false
    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var thermalHot = false
    private var sleepReasons: Set<String> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?

    /// Asleep, display asleep, screen locked, or another user's session is in front.
    var isAsleep: Bool { !sleepReasons.isEmpty }

    init() {
        onBattery = Self.readOnBattery()
        thermalHot = Self.readThermalHot()

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.onBattery = PowerMonitor.readOnBattery()
            monitor.onChange?()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }

        let center = NotificationCenter.default
        observe(center, .NSProcessInfoPowerStateDidChange) { [weak self] in
            self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        observe(center, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in
            self?.thermalHot = Self.readThermalHot()
        }

        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep"),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session"),
        ]
        for (start, end, reason) in pairs {
            observe(workspace, start) { [weak self] in self?.sleepReasons.insert(reason) }
            observe(workspace, end) { [weak self] in self?.sleepReasons.remove(reason) }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.sleepReasons.insert("lock")
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.sleepReasons.remove("lock")
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ update: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            update()
            self?.onChange?()
        }
        observers.append((center, token))
    }

    private static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    private static func readThermalHot() -> Bool {
        ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
}
