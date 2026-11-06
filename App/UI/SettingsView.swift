import CKeycadence
import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let prefs: Preferences
    let stats: KeyStats
    let engine: OpaquePointer
    let quiet: QuietMonitor

    var body: some View {
        TabView {
            SoundTab(prefs: prefs, engine: engine).tabItem { Label("Sound", systemImage: "waveform") }
            QuietTab(prefs: prefs, quiet: quiet).tabItem { Label("Quiet", systemImage: "moon") }
            GeneralTab(prefs: prefs).tabItem { Label("General", systemImage: "gearshape") }
            ActivityTab(prefs: prefs, stats: stats, engine: engine).tabItem { Label("Activity", systemImage: "chart.bar") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 620)
    }
}

// MARK: - Sound

struct SoundTab: View {
    @Bindable var prefs: Preferences
    let engine: OpaquePointer
    @State private var devices: [OutputDevice] = []

    var body: some View {
        Form {
            Section {
                LabeledContent("Volume") {
                    Slider(value: $prefs.volume, in: 0...1)
                }
                Picker("Switch", selection: $prefs.switchID) {
                    ForEach(allSwitches) { Text($0.name).tag($0.id) }
                }
                Picker("Output", selection: $prefs.outputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
            }
            Section("Realism") {
                Toggle("Place keys across the stereo field", isOn: $prefs.stereoPan)
                Toggle("Spatial sound (best on headphones)", isOn: $prefs.spatial)
                Toggle("Vary pitch and strength", isOn: $prefs.pitchVariation)
                Toggle("Skip very fast repeats", isOn: $prefs.ignoreRapid)
                Toggle("Silence modifier keys", isOn: $prefs.muteModifiers)
            }
            Section("Tone") {
                ToneField(x: $prefs.toneX, y: $prefs.toneY) {
                    kc_engine_preview_profile(engine, Int32(prefs.switchID))
                }
                .frame(height: 130)
            }
            Section("Extras") {
                LabeledContent("Extras volume") {
                    Slider(value: $prefs.effectsVolume, in: 0...1)
                }
                HStack {
                    Toggle("Mouse clicks", isOn: $prefs.mouseSounds)
                    Spacer()
                    Button("Hear it") { kc_engine_preview_effect(engine, KC_EFFECT_MOUSE) }.controlSize(.small)
                }
                HStack {
                    Toggle("Bell on Return", isOn: $prefs.returnDing)
                    Spacer()
                    Button("Hear it") { kc_engine_preview_effect(engine, KC_EFFECT_DING) }.controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDevices.outputDevices() }
    }
}

/// Drag anywhere in the field: left to right is dark to bright, bottom to top is thin to full.
private struct ToneField: View {
    @Binding var x: Double
    @Binding var y: Double
    let onRelease: () -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1), height = max(geo.size.height, 1)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [.indigo.opacity(0.28), .orange.opacity(0.28)],
                                         startPoint: .leading, endPoint: .trailing))
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [.primary.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom))
                Path { p in
                    p.move(to: CGPoint(x: width / 2, y: 0)); p.addLine(to: CGPoint(x: width / 2, y: height))
                    p.move(to: CGPoint(x: 0, y: height / 2)); p.addLine(to: CGPoint(x: width, y: height / 2))
                }
                .stroke(.secondary.opacity(0.25), lineWidth: 1)
                VStack {
                    Text("Full")
                    Spacer()
                    HStack { Text("Dark"); Spacer(); Text("Bright") }
                    Spacer()
                    Text("Thin")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
                Circle()
                    .fill(.white)
                    .shadow(radius: 2)
                    .frame(width: 18, height: 18)
                    .position(x: (x + 1) / 2 * width, y: (1 - y) / 2 * height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    x = max(-1, min(1, drag.location.x / width * 2 - 1))
                    y = max(-1, min(1, 1 - drag.location.y / height * 2))
                }
                .onEnded { _ in
                    // A small dead zone makes the neutral centre easy to find again.
                    if abs(x) < 0.06 { x = 0 }
                    if abs(y) < 0.06 { y = 0 }
                    onRelease()
                })
            .onTapGesture(count: 2) { x = 0; y = 0 }
            .accessibilityElement()
            .accessibilityLabel("Tone")
            .accessibilityValue("Brightness \(Int(x * 100)), fullness \(Int(y * 100))")
        }
    }
}

// MARK: - Quiet

struct QuietTab: View {
    @Bindable var prefs: Preferences
    let quiet: QuietMonitor

    var body: some View {
        Form {
            Section {
                Toggle("Go quiet automatically", isOn: $prefs.quietEnabled)
                LabeledContent("Volume when quiet") {
                    HStack {
                        Slider(value: $prefs.quietVolume, in: 0...1)
                        Text(prefs.quietVolume == 0 ? "Silent" : "\(Int(prefs.quietVolume * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!prefs.quietEnabled)
            }
            Section("Go quiet when") {
                ForEach(QuietRule.allCases) { rule in
                    Toggle(isOn: binding(rule)) {
                        HStack(spacing: 8) {
                            Image(systemName: rule.symbol).frame(width: 22)
                            Text(rule.title)
                        }
                    }
                }
            }
            .disabled(!prefs.quietEnabled)
            Section {
                Toggle("Notify me when this changes", isOn: $prefs.quietNotifications)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ rule: QuietRule) -> Binding<Bool> {
        Binding(get: { prefs.quietRules.contains(rule) }, set: { on in
            if on { prefs.quietRules.insert(rule) } else { prefs.quietRules.remove(rule) }
        })
    }
}

// MARK: - General

struct GeneralTab: View {
    @Bindable var prefs: Preferences
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Menu bar") {
                Picker("Show", selection: $prefs.menuBarLabel) {
                    ForEach(MenuBarLabel.allCases) { Text($0.title).tag($0) }
                }
                Picker("Clicking the icon", selection: $prefs.clickAction) {
                    ForEach(ClickAction.allCases) { Text($0.title).tag($0) }
                }
                if prefs.clickAction == .toggleSound {
                    Text("Right-click or Option-click still opens the panel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Keep the icon solid when off", isOn: $prefs.solidIconWhenOff)
                Toggle("Preview switches on hover", isOn: $prefs.hoverPreview)
            }
            Section("Shortcut") {
                LabeledContent("Turn sound on or off") {
                    HotkeyRecorder(code: $prefs.hotkeyCode, modifiers: $prefs.hotkeyModifiers)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct HotkeyRecorder: View {
    @Binding var code: UInt32
    @Binding var modifiers: UInt32
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(label) { recording ? stop() : start() }
            .monospaced()
            .onDisappear { stop() }
    }

    private var label: String {
        if recording { return "Press a shortcut…" }
        if code == 0 && modifiers == 0 { return "None" }
        return Hotkey.describe(code: code, modifiers: modifiers)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // esc: cancel
                stop()
                return nil
            }
            if event.keyCode == 51 { // delete: clear
                code = 0
                modifiers = 0
                stop()
                return nil
            }
            let carbon = Hotkey.carbonModifiers(from: event.modifierFlags)
            // A global shortcut without a modifier would swallow normal typing.
            guard carbon != 0 else { return nil }
            code = UInt32(event.keyCode)
            modifiers = carbon
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Activity

struct ActivityTab: View {
    @Bindable var prefs: Preferences
    let stats: KeyStats
    let engine: OpaquePointer
    @State private var latency = kc_stats()
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Count keystrokes", isOn: $prefs.statsEnabled)
            } footer: {
                Text("Only totals per day, stored on this Mac. Never which keys you pressed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if prefs.statsEnabled {
                Section("Last 14 days") {
                    KeyBars(days: stats.recent(14))
                        .frame(height: 90)
                    LabeledContent("Today", value: stats.liveToday.formatted())
                    LabeledContent("All time", value: stats.total.formatted())
                    Button("Reset counts", role: .destructive) { stats.reset() }
                }
            }
            Section("Speed") {
                if latency.count == 0 {
                    Text("Type something to measure this Mac's latency.").foregroundStyle(.secondary)
                } else {
                    LabeledContent("Key to sound, in this app", value: String(format: "%.1f ms average", latency.mean_ms))
                    LabeledContent("Slowest so far", value: String(format: "%.1f ms", latency.max_ms))
                    LabeledContent("Added by the output device", value: String(format: "%.1f ms", latency.device_ms))
                    LabeledContent("Audio buffer", value: "\(latency.buffer_frames) frames at \(Int(latency.sample_rate)) Hz")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { kc_engine_get_stats(engine, &latency) }
        .onReceive(refresh) { _ in kc_engine_get_stats(engine, &latency) }
    }
}

private struct KeyBars: View {
    let days: [(date: Date, keys: Int)]

    var body: some View {
        let peak = max(days.map(\.keys).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(days, id: \.date) { day in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(height: max(2, 90 * CGFloat(day.keys) / CGFloat(peak)))
                    .frame(maxWidth: .infinity)
                    .help("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.keys.formatted()) keys")
            }
        }
    }
}

// MARK: - About

struct AboutTab: View {
    private func aboutRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 20)
            Text(text)
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Keycadence").font(.title2.weight(.semibold))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Mechanical keyboard sounds, with almost no delay.")
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                aboutRow("wifi.slash", "No network access. It can't send anything.")
                aboutRow("lock", "Key presses are never stored.")
                aboutRow("waveform", "Real keyboards, from public domain recordings.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            Spacer()
        }
        .padding(.top, 36)
        .frame(maxWidth: .infinity)
    }
}
