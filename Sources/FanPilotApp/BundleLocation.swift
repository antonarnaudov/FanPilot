import Darwin
import FanPilotCore
import Foundation

/// Where FanPilot is running from, and the clean-up a downloaded copy needs.
enum BundleLocation {
    /// macOS runs apps opened straight from Downloads or a disk image from a
    /// hidden, read-only copy ("App Translocation"). A helper registered from
    /// there would vanish, so fan control waits until the app is in Applications.
    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    static var isOnDiskImage: Bool {
        Bundle.main.bundlePath.hasPrefix("/Volumes/")
    }

    static var canRegisterHelper: Bool { !isTranslocated && !isOnDiskImage }

    static let moveToApplicationsMessage =
        "Move FanPilot to your Applications folder and open it from there to turn on fan control."

    private static let quarantine = "com.apple.quarantine"

    /// A downloaded app carries the quarantine flag on every file. Once the user
    /// has opened FanPilot (approving it in Gatekeeper), the flag is cleared from
    /// the rest of the bundle too, because macOS starts the built-in helper on
    /// its own, without a window to ask in. Only FanPilot's own files are touched.
    static func clearQuarantineAfterApproval() {
        let root = Bundle.main.bundleURL
        guard getxattr(root.path, quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0,
              FileManager.default.isWritableFile(atPath: root.path)
        else { return }
        var urls = [root]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator { urls.append(url) }
        }
        for url in urls {
            removexattr(url.path, quarantine, XATTR_NOFOLLOW)
        }
    }
}

extension FanPilot {
    /// The app's version (Info.plist). Lives in the app target, not the core
    /// module, so changing it never changes the helper's binary.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? version
    }
}
