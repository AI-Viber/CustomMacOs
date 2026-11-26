import AppKit

/// Version and project details shown in About.
///
/// The version (e.g. 1.2.0) is `CFBundleShortVersionString` in Info.plist and is raised by hand
/// for each release (see CHANGELOG.md). The build number, commit and build date are filled in
/// by build.sh from Git when the app is built.
enum AppInfo {
    static let name = "CustomMacOS"
    static let repository = URL(string: "https://github.com/AI-Viber/CustomMacOs")!
    static let releases = URL(string: "https://github.com/AI-Viber/CustomMacOs/releases")!
    static let changelog = URL(string: "https://github.com/AI-Viber/CustomMacOs/blob/main/CHANGELOG.md")!
    static let licence = URL(string: "https://github.com/AI-Viber/CustomMacOs/blob/main/LICENSE")!

    static let summary = "Rectangle-style window management, Karabiner-style key remapping, app shortcuts, a system monitor and a battery indicator in your menu bar."

    private static func info(_ key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return (value?.isEmpty ?? true) ? nil : value
    }

    static var version: String { info("CFBundleShortVersionString") ?? "?" }
    static var build: String { info("CFBundleVersion") ?? "?" }
    /// Short Git commit hash the app was built from, if known.
    static var commit: String? { info("CMOSGitCommit") }
    /// ISO date the app was built.
    static var buildDate: String? { info("CMOSBuildDate") }
    static var copyright: String { info("NSHumanReadableCopyright") ?? "" }

    /// "Version 1.2.0 (build 24)"
    static var versionLine: String { "Version \(version) (build \(build))" }

    /// Everything in one line, for bug reports: "CustomMacOS 1.2.0 (24, a1b2c3d), macOS 27.0.1"
    static var fullDescription: String {
        var parts = [build]
        if let commit { parts.append(commit) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(name) \(version) (\(parts.joined(separator: ", "))), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    /// The standard macOS About window, with a short description and links.
    static func showAboutPanel() {
        let credits = NSMutableAttributedString(
            string: summary + "\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.labelColor])
        let link: (String, URL) -> NSAttributedString = { title, url in
            NSAttributedString(string: title, attributes: [
                .link: url, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        }
        credits.append(link("GitHub", repository))
        credits.append(NSAttributedString(string: "  ·  "))
        credits.append(link("What's new", changelog))
        credits.append(NSAttributedString(string: "  ·  "))
        credits.append(link("MIT licence", licence))
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: credits.length))

        var versionText = "build \(build)"
        if let commit { versionText += ", \(commit)" }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: name,
            .applicationVersion: version,
            .version: versionText,
            .credits: credits,
        ])
    }
}
