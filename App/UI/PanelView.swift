import CKeycadence
import SwiftUI

/// The menu bar panel: the sound switch, volume, and a board of keycaps to pick from.
struct PanelView: View {
    @Bindable var prefs: Preferences
    let permission: InputPermission
    let engine: OpaquePointer
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !permission.granted { PermissionBanner(permission: permission) }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.caption)
                Slider(value: $prefs.volume, in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("Volume")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.caption)
            }

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: allSwitches.count, by: 3)), id: \.self) { start in
                    GridRow {
                        ForEach(allSwitches[start..<min(start + 3, allSwitches.count)]) { info in
                            KeycapButton(info: info, selected: prefs.switchID == info.id, hoverPreview: prefs.hoverPreview,
                                         engine: engine) {
                                prefs.switchID = info.id
                                kc_engine_preview_profile(engine, Int32(info.id))
                            }
                        }
                    }
                }
            }

            Text(allSwitches[prefs.switchID].character)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()
            HStack {
                Button("Settings…", action: openSettings).buttonStyle(.plain)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Keycadence").font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Sound", isOn: $prefs.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private var status: String {
        if !prefs.enabled { return "Off" }
        if prefs.isQuiet && prefs.quietEnabled { return "Quiet: a rule applies" }
        return allSwitches[prefs.switchID].name
    }
}

private struct PermissionBanner: View {
    let permission: InputPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Allow Input Monitoring").font(.subheadline.weight(.semibold))
            Text("macOS needs your OK before Keycadence can hear key presses. It only uses them to choose a sound, and never stores or sends them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { permission.request() }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A switch, drawn as the keycap it would sit under.
private struct KeycapButton: View {
    let info: SwitchInfo
    let selected: Bool
    let hoverPreview: Bool
    let engine: OpaquePointer
    let action: () -> Void
    @State private var pressed = false

    private var color: Color { Color(hue: info.hue, saturation: info.saturation, brightness: info.brightness) }
    private var legend: Color { info.brightness > 0.72 ? .black.opacity(0.65) : .white.opacity(0.9) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(color.opacity(0.75))
                    RoundedRectangle(cornerRadius: 7)
                        .fill(color)
                        .padding(EdgeInsets(top: 3, leading: 4, bottom: 7, trailing: 4))
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    Text(String(info.name.prefix(1)))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(legend)
                        .offset(y: -2)
                }
                .frame(height: 40)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2).padding(-2)
                    }
                }
                Text(info.name).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(info.name): \(info.character)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { inside in
            if inside && hoverPreview { kc_engine_preview_profile(engine, Int32(info.id)) }
        }
    }
}
