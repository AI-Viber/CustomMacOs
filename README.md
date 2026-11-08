# CustomMacOS

A small native macOS menu-bar/Dock app combining Rectangle-style window management with a few Karabiner-Elements-style key remaps. macOS 13 Ventura or later.

## Build and install

You need Apple's command-line tools (`xcode-select --install`, or a full Xcode install).

```bash
cd CustomMacOS
./build.sh --install     # builds, copies to /Applications, launches
```

`./build.sh` alone builds `build/CustomMacOS.app` without installing.

## First launch

1. macOS asks for **Accessibility** access. Turn on CustomMacOS in System Settings → Privacy & Security → **Device Control and Data Access** (called Accessibility before macOS 27). The app picks up the change within a couple of seconds; no relaunch needed.
2. The Settings window opens. Choose whether the app lives in the **Menu Bar**, the **Dock**, or **Both** (General tab).

> Rebuilding with the default ad-hoc signature changes the app's identity, so after a rebuild macOS may silently stop honouring the Accessibility permission. If shortcuts stop working, remove CustomMacOS from that list with "−" and add it again. Building with `SIGN_ID="Apple Development: …" ./build.sh` avoids this.

## Window management

Caps Lock acts as Hyper, so "Caps Lock + key" below means Hyper + key.

| Action | Shortcut |
|---|---|
| Left / Right / Top / Bottom half | ⌃⌥ ← → ↑ ↓ (press again to cycle ½ → ⅔ → ⅓) |
| Top-left / Top-right / Bottom-left / Bottom-right | Caps Lock + U / I / J / K |
| First / Center / Last third | ⌃⌥ D / F / G |
| First / Last two thirds | ⌃⌥ E / T |
| Maximize | Caps Lock + Return |
| Center | ⌃⌥ C |
| Make larger / smaller | ⌃⌥ = / − |
| Restore previous size | ⌃⌥ ⌫ |
| Move to left / right display | Caps Lock + O / P |

Every shortcut can be re-recorded or cleared in Settings → Windows. Also there:

- **Drag to snap**: drag a window to the left/right edge for halves, the top edge to maximize, corners for quarters, and the bottom edge for thirds. A preview shows where it will land.
- **Gap** between snapped windows (0–30 px).

## Keyboard (Karabiner-style)

- **Caps Lock**: by default it acts as **Hyper** (⌃⌥⇧⌘) while held and **Escape** when tapped on its own. Other modes: Hyper only, Escape, or off (normal Caps Lock).
- **Shift + Caps Lock** turns real Caps Lock on and off.

Hyper combinations can be recorded as window shortcuts, or used in any other app.

How it works: the app uses `hidutil` to send the physical Caps Lock key as F18, and an event tap turns F18 into Hyper/Escape. The mapping is cleared when the app quits. If the app ever crashes and Caps Lock seems dead, relaunch the app or run:

```bash
hidutil property --set '{"UserKeyMapping":[]}'
```

If you've remapped Caps Lock in System Settings → Keyboard → Modifier Keys, or in Karabiner-Elements, turn that off so the two don't fight.

## Menu bar: hide and show icons

**macOS 26 and earlier only.** macOS 27 draws the menu bar as a single window, which stops this from working, so CustomMacOS turns it off there. On macOS 27, hold ⌘ and drag icons to the left of the menu bar's own arrow, and click the arrow to show or hide them. **Caps Lock + M** tries to press that arrow for you (experimental: it searches the menu bar through the Accessibility API). Each press writes `menubar-diagnostics.txt` in this project folder describing what it found.

Settings → Menu Bar (on by default). A chevron (‹ ›) and a thin divider line appear near the right of the menu bar.

1. Click the chevron so everything is visible.
2. Hold ⌘ and drag any icon to the **left** of the divider to hide it, or to the right to keep it always visible.
3. Click the chevron again or press **Caps Lock + M** to show or hide. Revealed icons hide again after 10 seconds (adjustable, or never).

The apps behind hidden icons keep running. Right-click the chevron for a small menu. If the divider is ever dragged to the right of the chevron, hiding is refused so the chevron can't push itself off-screen; drag the divider back to its left.

## App shortcuts: add a shortcut to any app's menu item

Like System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts, but from the CustomMacOS menu and with clash checking.

1. With any app in front, choose **Add Shortcut to “App” Menu Item…** from the CustomMacOS menu. (Opening a menu-bar menu doesn't switch away from the app.)
2. Search for and select the menu item. Its current shortcut, if any, is shown on the right.
3. Record the new shortcut. Before you save, CustomMacOS warns if it's already used by:
   - another item anywhere in that app's menus,
   - another app shortcut CustomMacOS assigned in that app,
   - an App Shortcut set for All Applications in System Settings,
   - one of CustomMacOS's own shortcuts (window actions, menu bar), or
   - a macOS system shortcut (Spotlight, screenshots, Mission Control and so on).
4. Save, or **Save Anyway** to override.

The shortcut is applied two ways:

- **CustomMacOS** watches for it and presses the menu item when that app is in front. Works immediately, and also in apps that ignore App Shortcuts.
- **macOS App Shortcuts** (the `NSUserKeyEquivalents` setting System Settings uses). The app picks it up when it's next opened, then handles it itself, even without CustomMacOS; CustomMacOS stands aside so it never fires twice. After saving you're offered **Reopen “App” Now**, which quits the app normally (it can still ask to save documents) and opens it again.

Sandboxed apps (most App Store apps) keep their settings where only System Settings can write, so for those CustomMacOS handles the shortcut itself; to make it permanent add the same shortcut in System Settings. All shortcuts are listed in **Settings → App Shortcuts**, where they can be removed.

Only apps with a standard macOS menu bar are supported. Shortcuts are tied to the menu item's exact title (and its menu path), so items whose titles change, such as “Undo Typing”, only match under the title they had when assigned.

## Limits compared with Karabiner-Elements

Karabiner installs a low-level virtual keyboard driver. CustomMacOS uses only standard user-level APIs, so: remaps don't apply in secure input fields (password boxes, some terminals with Secure Keyboard Entry), and there are no per-device rules.

## Project layout

```
Sources/
  main.swift            app entry point
  AppDelegate.swift     menu bar / Dock presence, status menu, settings window, permissions
  AppSettings.swift     persisted preferences
  WindowAction.swift    window actions + default shortcuts
  WindowManager.swift   Accessibility-API window moving and geometry
  HotkeyManager.swift   global shortcuts (Carbon hot keys)
  DragSnapper.swift     drag-to-edge snapping + preview overlay
  KeyRemapper.swift     Caps Lock → Hyper/Escape, Shift+Caps → Caps Lock
  MenuReader.swift      reads another app's menus and shortcuts (Accessibility API); key layout helpers
  AppShortcutStore.swift      app shortcut list, macOS App Shortcuts, clash checking, system shortcuts
  AppShortcutTrigger.swift    presses menu items for app shortcuts; tracks the frontmost app
  AppShortcutPicker.swift     the "Add Shortcut to Menu Item…" window
  MenuBarHider.swift    hide/show section for menu bar icons (macOS 26 and earlier)
  NativeOverflowToggle.swift  presses macOS 27's built-in menu bar arrow
  SettingsView.swift    SwiftUI settings + shortcut recorder
Tools/MakeIcon.swift    draws the app icon during the build
build.sh                compile, bundle, sign, optional install
```
