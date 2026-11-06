import CKeycadence
import Foundation
import Observation

enum MenuBarLabel: String, CaseIterable, Identifiable {
    case none, switchName, keysToday
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Icon only"
        case .switchName: "Switch name"
        case .keysToday: "Keys today"
        }
    }
}

enum ClickAction: String, CaseIterable, Identifiable {
    case openPanel, toggleSound
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openPanel: "Open panel"
        case .toggleSound: "Turn sound on or off"
        }
    }
}

enum QuietRule: String, CaseIterable, Identifiable {
    case speakers, headphones, bluetooth, externalKeyboard, microphone, camera, otherAudio, calendar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speakers: "Using built-in speakers"
        case .headphones: "Using headphones"
        case .bluetooth: "A Bluetooth device is connected"
        case .externalKeyboard: "An external keyboard is connected"
        case .microphone: "The microphone is in use"
        case .camera: "The camera is in use"
        case .otherAudio: "Another app is using audio output"
        case .calendar: "A calendar event is happening"
        }
    }
    var symbol: String {
        switch self {
        case .speakers: "speaker.wave.2"
        case .headphones: "headphones"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .externalKeyboard: "keyboard"
        case .microphone: "mic"
        case .camera: "video"
        case .otherAudio: "play.circle"
        case .calendar: "calendar"
        }
    }
}

struct SwitchInfo: Identifiable, Hashable {
    let id: Int
    let name: String
    let character: String
    let hue: Double
    let saturation: Double
    let brightness: Double
}

/// Order matches `SOURCES` in tools/build_pack.py. Named for what they are, not by brand.
let allSwitches: [SwitchInfo] = [
    .init(id: 0, name: "Portable", character: "1950s manual typewriter", hue: 0.40, saturation: 0.35, brightness: 0.48),
    .init(id: 1, name: "Office", character: "1970s electric typewriter", hue: 0.0, saturation: 0.66, brightness: 0.62),
    .init(id: 2, name: "Terminal", character: "Early 1980s buckling spring", hue: 0.11, saturation: 0.18, brightness: 0.82),
    .init(id: 3, name: "Spring", character: "Buckling spring, built today", hue: 0.60, saturation: 0.08, brightness: 0.62),
    .init(id: 4, name: "Clicky", character: "Classic clicky switches", hue: 0.57, saturation: 0.72, brightness: 0.78),
    .init(id: 5, name: "Linear", character: "Heavy linear switches", hue: 0.62, saturation: 0.10, brightness: 0.30),
    .init(id: 6, name: "Dome", character: "Soft, cushioned dome and spring", hue: 0.09, saturation: 0.16, brightness: 0.90),
    .init(id: 7, name: "Hobby", character: "Hobbyist build, lubed and tuned", hue: 0.78, saturation: 0.40, brightness: 0.70),
    .init(id: 8, name: "Gasket", character: "Modern, creamy and thocky", hue: 0.47, saturation: 0.45, brightness: 0.68),
]

/// User settings. Each one persists itself and pushes to the engine when it changes.
@MainActor
@Observable
final class Preferences {
    private let store = UserDefaults.standard
    private let engine: OpaquePointer

    var enabled: Bool { didSet { store.set(enabled, forKey: "enabled"); applyEnabled() } }
    var volume: Double { didSet { store.set(volume, forKey: "volume"); kc_engine_set_volume(engine, curve(volume)) } }
    var switchID: Int { didSet { store.set(switchID, forKey: "switchID"); kc_engine_set_profile(engine, Int32(switchID)) } }
    var outputDeviceUID: String { didSet { store.set(outputDeviceUID, forKey: "outputDeviceUID"); applyOutputDevice() } }

    var stereoPan: Bool { didSet { store.set(stereoPan, forKey: "stereoPan"); kc_engine_set_pan(engine, stereoPan) } }
    var spatial: Bool { didSet { store.set(spatial, forKey: "spatial"); kc_engine_set_spatial(engine, spatial) } }
    var pitchVariation: Bool { didSet { store.set(pitchVariation, forKey: "pitchVariation"); kc_engine_set_pitch_variation(engine, pitchVariation) } }
    var ignoreRapid: Bool { didSet { store.set(ignoreRapid, forKey: "ignoreRapid"); kc_engine_set_ignore_rapid(engine, ignoreRapid) } }
    var muteModifiers: Bool { didSet { store.set(muteModifiers, forKey: "muteModifiers"); kc_engine_set_mute_modifiers(engine, muteModifiers) } }

    var toneX: Double { didSet { store.set(toneX, forKey: "toneX"); applyTone() } }
    var toneY: Double { didSet { store.set(toneY, forKey: "toneY"); applyTone() } }

    var effectsVolume: Double { didSet { store.set(effectsVolume, forKey: "effectsVolume"); kc_engine_set_effects_volume(engine, curve(effectsVolume)) } }
    var mouseSounds: Bool { didSet { store.set(mouseSounds, forKey: "mouseSounds"); kc_engine_set_mouse_sounds(engine, mouseSounds) } }
    var returnDing: Bool { didSet { store.set(returnDing, forKey: "returnDing"); kc_engine_set_return_ding(engine, returnDing) } }

    var quietEnabled: Bool { didSet { store.set(quietEnabled, forKey: "quietEnabled"); onQuietRulesChanged?() } }
    var quietVolume: Double { didSet { store.set(quietVolume, forKey: "quietVolume"); onQuietRulesChanged?() } }
    var quietRules: Set<QuietRule> {
        didSet { store.set(quietRules.map(\.rawValue), forKey: "quietRules"); onQuietRulesChanged?() }
    }
    var quietNotifications: Bool { didSet { store.set(quietNotifications, forKey: "quietNotifications") } }

    var menuBarLabel: MenuBarLabel { didSet { store.set(menuBarLabel.rawValue, forKey: "menuBarLabel"); onMenuBarChanged?() } }
    var clickAction: ClickAction { didSet { store.set(clickAction.rawValue, forKey: "clickAction") } }
    var solidIconWhenOff: Bool { didSet { store.set(solidIconWhenOff, forKey: "solidIconWhenOff"); onMenuBarChanged?() } }
    var hoverPreview: Bool { didSet { store.set(hoverPreview, forKey: "hoverPreview") } }
    var statsEnabled: Bool { didSet { store.set(statsEnabled, forKey: "statsEnabled"); onMenuBarChanged?() } }

    var hotkeyCode: UInt32 { didSet { store.set(Int(hotkeyCode), forKey: "hotkeyCode"); onHotkeyChanged?() } }
    var hotkeyModifiers: UInt32 { didSet { store.set(Int(hotkeyModifiers), forKey: "hotkeyModifiers"); onHotkeyChanged?() } }

    @ObservationIgnored var onQuietRulesChanged: (() -> Void)?
    @ObservationIgnored var onMenuBarChanged: (() -> Void)?
    @ObservationIgnored var onHotkeyChanged: (() -> Void)?
    /// Set by QuietMonitor: whether a rule currently applies.
    var isQuiet = false { didSet { applyQuiet(); onMenuBarChanged?() } }

    init(engine: OpaquePointer) {
        self.engine = engine
        store.register(defaults: [
            "enabled": true, "volume": 0.5, "switchID": 8, "stereoPan": true, "spatial": true, "pitchVariation": true,
            "effectsVolume": 1.0, "mouseSounds": false, "hoverPreview": true,
            "hotkeyCode": 40, // K
            "hotkeyModifiers": 0x1800, // control + option (Carbon flags)
        ])
        enabled = store.bool(forKey: "enabled")
        volume = store.double(forKey: "volume")
        switchID = min(store.integer(forKey: "switchID"), allSwitches.count - 1)
        outputDeviceUID = store.string(forKey: "outputDeviceUID") ?? ""
        stereoPan = store.bool(forKey: "stereoPan")
        spatial = store.bool(forKey: "spatial")
        pitchVariation = store.bool(forKey: "pitchVariation")
        ignoreRapid = store.bool(forKey: "ignoreRapid")
        muteModifiers = store.bool(forKey: "muteModifiers")
        toneX = store.double(forKey: "toneX")
        toneY = store.double(forKey: "toneY")
        effectsVolume = store.double(forKey: "effectsVolume")
        mouseSounds = store.bool(forKey: "mouseSounds")
        returnDing = store.bool(forKey: "returnDing")
        quietEnabled = store.bool(forKey: "quietEnabled")
        quietVolume = store.double(forKey: "quietVolume")
        quietRules = Set((store.stringArray(forKey: "quietRules") ?? []).compactMap(QuietRule.init(rawValue:)))
        quietNotifications = store.bool(forKey: "quietNotifications")
        menuBarLabel = MenuBarLabel(rawValue: store.string(forKey: "menuBarLabel") ?? "") ?? .none
        clickAction = ClickAction(rawValue: store.string(forKey: "clickAction") ?? "") ?? .openPanel
        solidIconWhenOff = store.bool(forKey: "solidIconWhenOff")
        hoverPreview = store.bool(forKey: "hoverPreview")
        statsEnabled = store.bool(forKey: "statsEnabled")
        hotkeyCode = UInt32(store.integer(forKey: "hotkeyCode"))
        hotkeyModifiers = UInt32(store.integer(forKey: "hotkeyModifiers"))
        applyAll()
    }

    private func applyAll() {
        applyEnabled()
        // No UI: for latency testing. `open Keycadence.app --args -audioBufferFrames 64`
        let frames = store.integer(forKey: "audioBufferFrames")
        if frames > 0 { kc_engine_set_buffer_frames(engine, UInt32(frames)) }
        kc_engine_set_volume(engine, curve(volume))
        kc_engine_set_profile(engine, Int32(switchID))
        kc_engine_set_pan(engine, stereoPan)
        kc_engine_set_spatial(engine, spatial)
        kc_engine_set_pitch_variation(engine, pitchVariation)
        kc_engine_set_ignore_rapid(engine, ignoreRapid)
        kc_engine_set_mute_modifiers(engine, muteModifiers)
        applyTone()
        kc_engine_set_effects_volume(engine, curve(effectsVolume))
        kc_engine_set_mouse_sounds(engine, mouseSounds)
        kc_engine_set_return_ding(engine, returnDing)
        applyQuiet()
        applyOutputDevice()
    }

    private func applyEnabled() {
        kc_engine_set_enabled(engine, enabled)
        onMenuBarChanged?()
    }

    private func applyTone() { kc_engine_set_tone(engine, Float(toneX), Float(toneY)) }

    func applyQuiet() {
        kc_engine_set_quiet_gain(engine, isQuiet && quietEnabled ? curve(quietVolume) : 1)
    }

    func applyOutputDevice() {
        let device = outputDeviceUID.isEmpty ? 0 : AudioDevices.deviceID(forUID: outputDeviceUID) ?? 0
        kc_engine_set_output_device(engine, device)
    }

    /// Loudness is perceived roughly logarithmically; a squared slider feels even.
    private func curve(_ value: Double) -> Float { Float(value * value) }
}
