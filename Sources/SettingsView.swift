import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            WindowsTab(settings: settings)
                .tabItem { Label("Windows", systemImage: "rectangle.split.2x1") }
            KeyboardTab(settings: settings)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            MenuBarTab(settings: settings)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            AppShortcutsTab()
                .tabItem { Label("App Shortcuts", systemImage: "command") }
            MonitorTab()
                .tabItem { Label("Monitor", systemImage: "waveform.path.ecg") }
        }
        .frame(width: 600, height: 620)
    }
}

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Show CustomMacOS in", selection: $settings.presence) {
                    ForEach(AppPresence.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }))
            } footer: {
                Text("In Dock-only mode, click the Dock icon to reopen these settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Permissions") {
                HStack(alignment: .top) {
                    Image(systemName: settings.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(settings.accessibilityGranted ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                        Text(settings.accessibilityGranted
                             ? "Granted. Window management and key remapping are active."
                             : "Needed to move windows and remap keys. Turn on CustomMacOS in Privacy & Security → Device Control and Data Access (called Accessibility before macOS 27). After a rebuild, remove it there with − and add it again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !settings.accessibilityGranted {
                        Button("Open Settings") { Permissions.openAccessibilitySettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WindowsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Behaviour") {
                Toggle("Snap windows by dragging them to screen edges", isOn: $settings.dragToSnap)
                Toggle("Repeating a half cycles ½ → ⅔ → ⅓", isOn: $settings.cycleHalves)
                HStack {
                    Text("Gap between windows")
                    Slider(value: $settings.gap, in: 0...30, step: 1)
                    Text("\(Int(settings.gap)) px")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            ForEach(WindowAction.Category.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(WindowAction.actions(in: category)) { action in
                        HStack {
                            Text(action.title)
                            Spacer()
                            ShortcutRecorder(shortcut: binding(for: action))
                        }
                    }
                }
            }

            Section {
                Button("Restore Default Shortcuts") { settings.resetShortcuts() }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for action: WindowAction) -> Binding<Shortcut?> {
        Binding(get: { settings.shortcuts[action] },
                set: { settings.setShortcut($0, for: action) })
    }
}

private struct KeyboardTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var keyboards = KeyboardMappings.shared

    var body: some View {
        Form {
            Section {
                Picker("Caps Lock", selection: $settings.capsLockMode) {
                    ForEach(CapsLockMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Shift + Caps Lock turns Caps Lock on/off", isOn: $settings.shiftCapsTogglesCapsLock)
                    .disabled(settings.capsLockMode == .off)
            } footer: {
                Text("Hyper is ⌃⌥⇧⌘ pressed together. While Caps Lock is held, every key you press is sent with Hyper, so you can bind Hyper shortcuts in the Windows tab or in other apps. Caps Lock is restored to normal when CustomMacOS quits.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !settings.accessibilityGranted && settings.capsLockMode != .off {
                Section {
                    Label("Key remapping is paused until Accessibility access is granted.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if keyboards.connected.isEmpty {
                    Text("No keyboards found.").foregroundStyle(.secondary)
                }
                ForEach(keyboards.connected) { kb in
                    Toggle(isOn: Binding(
                        get: { keyboards.isSwapped(kb.id) },
                        set: { keyboards.setSwap($0, id: kb.id, name: kb.name) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kb.name)
                            Text(kb.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(keyboards.rememberedNotConnected) { kb in
                    Toggle(isOn: Binding(
                        get: { true },
                        set: { if !$0 { keyboards.setSwap(false, id: kb.id, name: kb.name) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kb.name)
                            Text("Not connected · swap applies when it's plugged in").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Swap ⌥ Option and ⌘ Command")
            } footer: {
                Text("For Windows/PC keyboards, where Alt sits where ⌘ Command is on a Mac keyboard. Turn it on for each keyboard that needs it; other keyboards are unaffected. These choices are saved on this Mac only, apply automatically whenever that keyboard is connected while CustomMacOS is running, and don't need Accessibility access. If you've already swapped these keys in System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys, set them back there, or the two swaps cancel out.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MenuBarTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        if MenuBarHider.isSupported {
            hiderForm
        } else {
            Form {
                Section("Built into macOS 27") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("macOS 27 changed how the menu bar is drawn, so CustomMacOS's own hiding can't work here. macOS now has it built in:")
                        Label("Hold ⌘ and drag an icon to the left of the menu bar's arrow to hide it, or to the right to keep it visible.", systemImage: "1.circle")
                        Label("Click the arrow to show or hide those icons. The apps keep running.", systemImage: "2.circle")
                        Label("To remove an icon completely, use System Settings → Menu Bar.", systemImage: "3.circle")
                    }
                    .font(.callout)
                    .padding(.vertical, 2)
                }
                Section {
                    Toggle("Keyboard shortcut presses the arrow for you", isOn: $settings.menuBarHiderEnabled)
                    if settings.menuBarHiderEnabled {
                        HStack {
                            Text("Show / hide shortcut")
                            Spacer()
                            ShortcutRecorder(shortcut: Binding(
                                get: { settings.menuBarShortcut },
                                set: { settings.setMenuBarShortcut($0) }))
                        }
                    }
                } footer: {
                    Text("Needs Accessibility access. Experimental: Apple doesn't document the arrow, so this may stop working after a macOS update.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private var hiderForm: some View {
        Form {
            Section {
                Toggle("Hide menu bar icons I choose", isOn: $settings.menuBarHiderEnabled)
            } footer: {
                Text("Apps whose icons are hidden keep running. Only the icon is moved out of sight.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.menuBarHiderEnabled {
                Section("How to use it") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("A chevron (‹ ›) and a thin divider line appear near the right of your menu bar.", systemImage: "1.circle")
                        Label("Click the chevron to show everything. Hold ⌘ and drag any icon to the left of the divider line to hide it, or to the right to keep it visible.", systemImage: "2.circle")
                        Label("Click the chevron again, press the shortcut below, or just wait, and the icons left of the divider tuck away.", systemImage: "3.circle")
                        Label("Right-click the chevron for a menu with Settings.", systemImage: "4.circle")
                    }
                    .font(.callout)
                    .padding(.vertical, 2)
                }

                Section("Options") {
                    HStack {
                        Text("Show / hide shortcut")
                        Spacer()
                        ShortcutRecorder(shortcut: Binding(
                            get: { settings.menuBarShortcut },
                            set: { settings.setMenuBarShortcut($0) }))
                    }
                    Picker("Hide again automatically", selection: $settings.menuBarAutoHideDelay) {
                        Text("After 5 seconds").tag(5.0)
                        Text("After 10 seconds").tag(10.0)
                        Text("After 30 seconds").tag(30.0)
                        Text("Never").tag(0.0)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppShortcutsTab: View {
    @ObservedObject var store = AppShortcutStore.shared
    @ObservedObject var settings = AppSettings.shared

    private struct AppGroup: Identifiable {
        let id: String  // app name
        let items: [AppMenuShortcut]
    }

    private var groups: [AppGroup] {
        let grouped = Dictionary(grouping: store.items, by: { $0.appName })
        return grouped.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { name in
                AppGroup(id: name, items: (grouped[name] ?? []).sorted { $0.pathDisplay < $1.pathDisplay })
            }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Give any menu item in any app a keyboard shortcut. With the app in front, choose “Add Shortcut to Menu Item…” from the CustomMacOS menu. CustomMacOS checks the shortcut isn't already used in that app, by CustomMacOS or by macOS first.")
                        .font(.callout)
                    if let app = ActiveAppTracker.shared.targetApp, let name = app.localizedName {
                        Button("Add Shortcut to a \(name) Menu Item…") {
                            AppShortcutPickerController.shared.show(for: app)
                        }
                    }
                }
                .padding(.vertical, 2)
                Toggle("Also save to macOS App Shortcuts", isOn: $store.saveToMacOS)
            } footer: {
                Text("Saved to macOS: the app handles the shortcut itself once it's reopened, even without CustomMacOS, and it appears in System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts. Until then, and for apps macOS won't let CustomMacOS save to, CustomMacOS presses the menu item for you.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !settings.accessibilityGranted {
                Section {
                    Label("App shortcuts need Accessibility access.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if store.items.isEmpty {
                Section {
                    Text("No app shortcuts yet.").foregroundStyle(.secondary)
                }
            }

            ForEach(groups) { group in
                Section(group.id) {
                    ForEach(group.items) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.pathDisplay)
                                Text(item.savedToMacOS ? "Saved to macOS · CustomMacOS covers it until the app is reopened"
                                                       : "Handled by CustomMacOS")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.shortcut.displayString)
                                .font(.callout.monospaced())
                            Button {
                                store.remove(item)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this shortcut")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press a key combination. Esc cancels; the ⓧ clears the shortcut.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(recording ? "Type shortcut…" : (shortcut?.displayString ?? "Record Shortcut"))
                    .frame(minWidth: 120)
                    .foregroundStyle(shortcut == nil && !recording ? Color.secondary : Color.primary)
            }
            if shortcut != nil && !recording {
                Button { shortcut = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        HotkeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 && e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()
                return nil
            }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods.isEmpty && !Shortcut.isFunctionKey(e.keyCode) {
                NSSound.beep()
                return nil
            }
            shortcut = Shortcut(keyCode: UInt32(e.keyCode), modifiers: Shortcut.carbonModifiers(from: mods))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            HotkeyManager.shared.resume()
        }
    }
}
