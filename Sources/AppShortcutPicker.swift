import AppKit
import SwiftUI

/// The "Add Shortcut to Menu Item…" window: lists the target app's menu items, records a
/// shortcut, warns about clashes, then saves it both ways.
final class AppShortcutPickerController: NSObject, NSWindowDelegate {
    static let shared = AppShortcutPickerController()
    private var window: NSWindow?

    func show(for app: NSRunningApplication) {
        guard AXIsProcessTrusted() else {
            Permissions.prompt()
            return
        }
        let name = app.localizedName ?? app.bundleIdentifier ?? "this app"
        guard let bundleID = app.bundleIdentifier else {
            alert("Can't add a shortcut to \(name)", "This app has no bundle identifier, so macOS can't store shortcuts for it.")
            return
        }
        KeyLayout.refresh()
        let entries = MenuReader.entries(for: app.processIdentifier)
        guard !entries.isEmpty else {
            alert("Couldn't read \(name)'s menus",
                  "Either \(name) doesn't use a standard macOS menu bar, or CustomMacOS doesn't have Accessibility access yet.")
            return
        }

        window?.close()
        let model = PickerModel(app: app, appName: name, bundleID: bundleID, entries: entries)
        let view = AppShortcutPickerView(model: model,
                                         onCancel: { [weak self] in self?.window?.close() },
                                         onSave: { [weak self] in self?.save(model) })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Add Shortcut to \(name) Menu Item"
        w.styleMask = [.titled, .closable, .resizable]
        w.setContentSize(NSSize(width: 640, height: 600))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Make sure a shortcut recording in progress doesn't leave hotkeys suspended.
        HotkeyManager.shared.resume()
    }

    private func save(_ model: PickerModel) {
        guard let entry = model.selected, let shortcut = model.shortcut else { return }
        let store = AppShortcutStore.shared

        var savedToMacOS = false
        if store.saveToMacOS {
            savedToMacOS = NativeAppShortcuts.write(bundleID: model.bundleID, appURL: model.app.bundleURL,
                                                    path: entry.path, shortcut: shortcut)
        }
        // If an earlier shortcut for this item was saved to macOS but this one isn't, clear the old one.
        if !savedToMacOS,
           let old = store.items(for: model.bundleID).first(where: { $0.path == entry.path }), old.savedToMacOS {
            NativeAppShortcuts.remove(bundleID: model.bundleID, path: entry.path)
        }
        store.upsert(AppMenuShortcut(bundleID: model.bundleID, appName: model.appName, path: entry.path,
                                     shortcut: shortcut, savedToMacOS: savedToMacOS))
        AppShortcutTrigger.shared.update()
        window?.close()

        let keys = shortcut.displayString
        let name = model.appName
        let a = NSAlert()
        a.messageText = "\(keys) now chooses “\(entry.pathDisplay)” in \(name)"
        if savedToMacOS {
            a.informativeText = "It works straight away through CustomMacOS. It's also saved to macOS App Shortcuts, so once \(name) is reopened, \(name) handles it itself, even when CustomMacOS isn't running."
            a.addButton(withTitle: "Reopen \(name) Now")
            a.addButton(withTitle: "Later")
        } else if store.saveToMacOS {
            a.informativeText = "\(name) keeps its settings in a protected location that only System Settings can change, so CustomMacOS handles this shortcut itself while it's running. To make it work without CustomMacOS, add the same shortcut in System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts."
            a.addButton(withTitle: "OK")
        } else {
            a.informativeText = "CustomMacOS handles this shortcut while it's running."
            a.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn, savedToMacOS {
            Relauncher.relaunch(model.app)
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// Quits an app normally (so it can ask to save documents) and opens it again.
enum Relauncher {
    static func relaunch(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        guard app.terminate() else { return }
        let giveUp = Date().addingTimeInterval(60)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            if app.isTerminated {
                timer.invalidate()
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            } else if Date() > giveUp {
                // Still open (for example, the user cancelled a save dialog). Leave it alone.
                timer.invalidate()
            }
        }
    }
}

final class PickerModel: ObservableObject {
    let app: NSRunningApplication
    let appName: String
    let bundleID: String
    let entries: [MenuEntry]

    @Published var search = ""
    @Published var selection: MenuEntry.ID? {
        didSet {
            // Start from the shortcut CustomMacOS already assigned to this item, if any.
            if let entry = selected {
                shortcut = AppShortcutStore.shared.items(for: bundleID).first { $0.path == entry.path }?.shortcut
            }
        }
    }
    @Published var shortcut: Shortcut?

    init(app: NSRunningApplication, appName: String, bundleID: String, entries: [MenuEntry]) {
        self.app = app
        self.appName = appName
        self.bundleID = bundleID
        self.entries = entries
    }

    var filtered: [MenuEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.pathDisplay.localizedCaseInsensitiveContains(q) }
    }

    var selected: MenuEntry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    var conflicts: [String] {
        guard let shortcut, let entry = selected else { return [] }
        return ConflictChecker.conflicts(for: shortcut, bundleID: bundleID, appName: appName,
                                         entries: entries, selectedPath: entry.path)
    }

    func assigned(_ entry: MenuEntry) -> Shortcut? {
        AppShortcutStore.shared.items(for: bundleID).first { $0.path == entry.path }?.shortcut
    }
}

struct AppShortcutPickerView: View {
    @ObservedObject var model: PickerModel
    @ObservedObject var store = AppShortcutStore.shared
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let icon = model.app.icon {
                    Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a menu item in \(model.appName)").font(.headline)
                    Text("\(model.entries.count) menu items. Greyed items are currently unavailable but can still be given a shortcut.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            TextField("Search menu items", text: $model.search)
                .textFieldStyle(.roundedBorder)

            List(model.filtered, selection: $model.selection) { entry in
                HStack {
                    Text(entry.pathDisplay)
                        .foregroundStyle(entry.enabled ? Color.primary : Color.secondary)
                    Spacer()
                    if let mine = model.assigned(entry) {
                        Text(mine.displayString)
                            .font(.callout.monospaced())
                            .foregroundStyle(Color.accentColor)
                            .help("Assigned by CustomMacOS")
                    } else if let existing = entry.existing {
                        Text(existing.displayString)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(entry.id)
            }
            .frame(minHeight: 260)

            if let entry = model.selected {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Shortcut for “\(entry.pathDisplay)”")
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            ShortcutRecorder(shortcut: $model.shortcut)
                        }
                        if let existing = entry.existing {
                            Text("Its current shortcut is \(existing.displayString). The new one replaces it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.shortcut != nil {
                            let conflicts = model.conflicts
                            if conflicts.isEmpty {
                                Label("Not used anywhere else in \(model.appName), CustomMacOS or macOS.",
                                      systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("This shortcut is already in use:", systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    ForEach(conflicts, id: \.self) { c in
                                        Text("• \(c)").font(.callout)
                                    }
                                    Text("If you save it anyway, the clashing command will no longer respond to this shortcut in \(model.appName). CustomMacOS and macOS shortcuts take priority over app menus.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(4)
                }
            } else {
                Text("Select a menu item above, then record a shortcut for it.")
                    .foregroundStyle(.secondary)
            }

            Toggle("Also save to macOS App Shortcuts, so it keeps working without CustomMacOS",
                   isOn: $store.saveToMacOS)
                .font(.callout)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(model.conflicts.isEmpty ? "Save" : "Save Anyway", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selected == nil || model.shortcut == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 520)
    }
}
