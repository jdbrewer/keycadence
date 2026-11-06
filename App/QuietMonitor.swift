import CoreAudio
import CoreMediaIO
import EventKit
import Foundation
import IOBluetooth
import IOKit.hid
@preconcurrency import UserNotifications

/// Decides whether any of the user's quiet rules applies right now.
///
/// It polls gently and only while at least one rule is on: with none, the timer
/// does not exist and this class costs nothing.
@MainActor
final class QuietMonitor {
    private let prefs: Preferences
    private var timer: Timer?
    private lazy var eventStore = EKEventStore()
    private var calendarAllowed = false
    private var calendarChecked = Date.distantPast
    private var calendarBusy = false

    init(prefs: Preferences) {
        self.prefs = prefs
        prefs.onQuietRulesChanged = { [weak self] in self?.rulesChanged() }
        rulesChanged()
    }

    private func rulesChanged() {
        prefs.applyQuiet()
        let active = prefs.quietEnabled && !prefs.quietRules.isEmpty
        if active && timer == nil {
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !active {
            timer?.invalidate()
            timer = nil
        }
        if prefs.quietEnabled && prefs.quietRules.contains(.calendar) { requestCalendar() }
        evaluate()
    }

    private func evaluate() {
        let quiet = prefs.quietEnabled && prefs.quietRules.contains { applies($0) }
        guard quiet != prefs.isQuiet else { return }
        prefs.isQuiet = quiet
        if prefs.quietNotifications { notify(quiet: quiet) }
    }

    func applies(_ rule: QuietRule) -> Bool {
        switch rule {
        case .speakers: QuietProbes.outputKind() == .speakers
        case .headphones: QuietProbes.outputKind() == .headphones
        case .bluetooth: QuietProbes.bluetoothConnected()
        case .externalKeyboard: QuietProbes.externalKeyboardConnected()
        case .microphone: QuietProbes.microphoneInUse()
        case .camera: QuietProbes.cameraInUse()
        case .otherAudio: QuietProbes.otherAppPlayingAudio()
        case .calendar: calendarEventNow()
        }
    }

    private func requestCalendar() {
        eventStore.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in self?.calendarAllowed = granted }
        }
    }

    private func calendarEventNow() -> Bool {
        guard calendarAllowed else { return false }
        let now = Date()
        // Events don't start every two seconds; once a minute is plenty.
        guard now.timeIntervalSince(calendarChecked) > 60 else { return calendarBusy }
        calendarChecked = now
        let predicate = eventStore.predicateForEvents(withStart: now.addingTimeInterval(-1), end: now.addingTimeInterval(1), calendars: nil)
        calendarBusy = eventStore.events(matching: predicate).contains { !$0.isAllDay && $0.availability != .free }
        return calendarBusy
    }

    private func notify(quiet: Bool) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = quiet ? "Keycadence is quiet" : "Keycadence is back"
            center.add(UNNotificationRequest(identifier: "quiet", content: content, trigger: nil))
        }
    }
}

enum OutputKind { case speakers, headphones, other }

/// One stateless check per rule. Public so diagnostics and tests can call them.
enum QuietProbes {
    private static let dataSourceSpeakers: UInt32 = 0x6973_706B // 'ispk'
    private static let dataSourceHeadphones: UInt32 = 0x6864_706E // 'hdpn'

    static func outputKind() -> OutputKind {
        let device = AudioDevices.defaultOutput
        guard device != 0 else { return .other }
        let transport: UInt32 = AudioDevices.value(device, kAudioDevicePropertyTransportType, default: 0)
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .headphones
        case kAudioDeviceTransportTypeBuiltIn:
            let source: UInt32 = AudioDevices.value(device, kAudioDevicePropertyDataSource,
                                                    scope: kAudioObjectPropertyScopeOutput, default: 0)
            return source == dataSourceHeadphones ? .headphones : .speakers
        default:
            return .other
        }
    }

    static func microphoneInUse() -> Bool {
        let device = AudioDevices.defaultInput
        guard device != 0 else { return false }
        let running: UInt32 = AudioDevices.value(device, kAudioDevicePropertyDeviceIsRunningSomewhere, default: 0)
        return running != 0
    }

    static func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == 0 else { return false }
        addr.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return devices.contains { device in
            var running: UInt32 = 0
            var got: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running)
            return status == 0 && running != 0
        }
    }

    /// Public API since macOS 14.2, and needs no permission. It reports apps with audio
    /// output open, which is not always audible: some apps hold it open while silent.
    static func otherAppPlayingAudio() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let processes: [AudioObjectID] = AudioDevices.array(system, kAudioHardwarePropertyProcessObjectList, zero: 0)
        let me = getpid()
        return processes.contains { process in
            let running: UInt32 = AudioDevices.value(process, kAudioProcessPropertyIsRunningOutput, default: 0)
            guard running != 0 else { return false }
            let pid: pid_t = AudioDevices.value(process, kAudioProcessPropertyPID, default: me)
            guard pid != me else { return false }
            // System daemons hold audio open without anything audible playing.
            let bundle = AudioDevices.string(process, kAudioProcessPropertyBundleID) ?? ""
            return !bundle.isEmpty && !bundle.hasPrefix("com.apple.audio") && !bundle.hasPrefix("com.apple.CoreSpeech")
        }
    }

    static func bluetoothConnected() -> Bool {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).contains { $0.isConnected() }
    }

    static func externalKeyboardConnected() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        return devices.contains { device in
            let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? Bool ?? false
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
            let hasVendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0) != 0
            return !builtIn && hasVendor && (transport == "USB" || transport.hasPrefix("Bluetooth"))
        }
    }
}
