import Foundation

public enum FanPilot {
    /// The helper's version. Bumped only when the helper or the app–helper
    /// protocol changes (the app restarts a helper whose version differs).
    /// The app's own version is in the VERSION file / CFBundleShortVersionString,
    /// so app-only releases leave the approved helper alone.
    public static let version = "0.2.3"

    public static let appBundleID = "com.antonarnaudov.fanpilot"
    /// launchd label and XPC Mach service name of the root helper.
    public static let helperLabel = "com.antonarnaudov.fanpilot.helper"
    public static let logSubsystem = "com.antonarnaudov.fanpilot"

    /// Where the helper keeps its config. Root: system-wide. Dev runs as a
    /// normal user (LaunchAgent, dry run) keep theirs in the user's Library.
    public static var helperConfigURL: URL {
        if getuid() == 0 {
            return URL(fileURLWithPath: "/Library/Application Support/FanPilot/config.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FanPilot/helper-config.json")
    }
}
