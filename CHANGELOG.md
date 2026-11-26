# Changelog

All notable changes to CustomMacOS. Versions follow [semantic versioning](https://semver.org): MAJOR.MINOR.PATCH, where MINOR adds features and PATCH only fixes problems. Each version is tagged in Git (`v1.2.0`), and the build number shown in About is the number of commits, so every build can be traced to its exact commit.

## 1.2.0 (2026-11-27)

### Added
- **About**: an About tab in Settings and an About CustomMacOS window (also in the menu bar menu), showing the version, build number, commit and links to GitHub, the changelog and the licence. **Copy Version Details** copies everything needed for a bug report.
- **Battery in the menu bar**: Settings → General → Menu bar icon can show an upright battery in place of the CustomMacOS icon, or beside it. Adjustable width, percentage beside or inside it, and colours for the charge level (green, orange, red), Low Power Mode (yellow) and charging (blue). The menu gains a battery section with time remaining and Battery Settings.
- **Swap ⌥ Option and ⌘ Command per keyboard**, for Windows/PC keyboards. Saved separately on each Mac and applied automatically when the keyboard is connected.
- **System monitor**: CPU, GPU, Neural Engine, memory, disk and network in the menu bar (shared with MenuPulse).
- **Signed, notarised release builds** with `release.sh`, and an MIT licence.
- **Xcode project**: open `CustomMacOS.xcodeproj` and press ⌘B to build and install.

### Changed
- **Add Shortcut to Menu Item…** has moved near the bottom of the menu, just above Settings.
- Build numbers now come from Git automatically.

### Fixed
- **Slow typing and doubled letters**: key handling now runs on its own high-priority thread, so nothing else the app does can delay a key press. Keyboards are only remapped when one actually reconnects, in the background, instead of every time any device appears.

## 1.1.0 (2026-11-08)

### Added
- **App shortcuts**: give any menu item in any app a keyboard shortcut, with a warning first if it clashes with the app's other shortcuts, CustomMacOS's own, or macOS's. Saved to macOS App Shortcuts and handled by CustomMacOS until the app is reopened.

### Fixed
- Windows in Electron apps (Claude, VS Code, Slack) can be moved and resized.

## 1.0.0 (2026-11-04)

First version.
- Rectangle-style window management: halves, quarters, thirds, maximise, centre, move between displays, drag to screen edges to snap, with re-recordable shortcuts.
- Caps Lock as Hyper (held) or Escape (tapped); Shift + Caps Lock for real Caps Lock.
- Show in the menu bar, the Dock, or both; launch at login.
- Hide menu bar icons behind a divider (macOS 26 and earlier).
