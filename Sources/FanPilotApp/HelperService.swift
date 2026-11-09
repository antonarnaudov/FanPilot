import FanPilotCore
import Foundation
import Security
import ServiceManagement

/// The fan-control helper ships inside FanPilot.app
/// (`Contents/Library/LaunchDaemons/com.antonarnaudov.fanpilot.helper.plist`,
/// program `Contents/MacOS/fanpilotd`). FanPilot registers it with
/// SMAppService on first launch; macOS asks the user once to allow it in
/// System Settings › General › Login Items & Extensions, runs it as root, and
/// removes it together with the app. There is no separate installer.
enum HelperService {
    static let plistName = "\(FanPilot.helperLabel).plist"

    static var daemon: SMAppService { SMAppService.daemon(plistName: plistName) }

    static var status: SMAppService.Status { daemon.status }

    static func register() async throws {
        do {
            try daemon.register()
        } catch {
            // A daemon that still needs the user's approval is registered, but
            // register() reports "Operation not permitted", and the status can
            // take a moment to settle. Only a status that never arrives is a failure.
            for _ in 0..<15 {
                if daemon.status == .requiresApproval || daemon.status == .enabled { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard daemon.status == .requiresApproval || daemon.status == .enabled else { throw error }
        }
        rememberBuild()
    }

    static func unregister() async throws {
        try await daemon.unregister()
    }

    /// Replaces the registration so macOS pins and runs the helper inside this
    /// build. Waits until macOS has really dropped the old registration;
    /// registering again too early is silently ignored, and launchd keeps
    /// refusing the new helper (EX_CONFIG / OS_REASON_CODESIGNING).
    static func reregister() async throws {
        try? await unregister()
        for _ in 0..<50 {
            if status == .notRegistered || status == .notFound { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .milliseconds(500))
        try await register()
    }

    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The bundled helper's code-signature hash (cdhash). macOS pins an
    /// approved ad-hoc helper to exactly this, so only a changed helper needs
    /// re-registering; an app update that leaves the helper alone doesn't.
    static var build: String? {
        guard let path = Bundle.main.path(forAuxiliaryExecutable: "fanpilotd") else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let info = info as? [String: Any],
              let hash = info[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static let buildKey = "registeredHelperBuild"

    private static func rememberBuild() {
        UserDefaults.standard.set(build, forKey: buildKey)
    }

    static var registeredCurrentBuild: Bool {
        UserDefaults.standard.string(forKey: buildKey) == build
    }

    /// The Team ID FanPilot is signed with, nil for ad-hoc builds. With a Team ID
    /// macOS recognises every build as the same app: approval and the helper's
    /// launch requirement survive updates. Ad-hoc builds are pinned per build.
    static var teamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess, let info = info as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// First launch registers the helper. After an update of an ad-hoc build,
    /// the registration is replaced so macOS pins the new helper (macOS may then
    /// ask for approval again; a signed build never needs this).
    static func prepare() async throws {
        switch status {
        case .notRegistered, .notFound:
            // A daemon that was never registered reports .notFound; registering
            // is the way to find out whether the bundle really lacks it.
            guard Bundle.main.path(forAuxiliaryExecutable: "fanpilotd") != nil else {
                throw HelperServiceError.notInBundle
            }
            try await register()
        case .enabled, .requiresApproval:
            if !registeredCurrentBuild {
                // Older versions stored "size-date" instead of the cdhash: adopt the
                // running registration rather than re-registering (which can cost the
                // user a re-approval). If the helper did change, the app's self-heal
                // re-registers once it stays silent.
                let storedLegacy = UserDefaults.standard.string(forKey: buildKey)?.contains("-") ?? false
                if teamIdentifier != nil || (storedLegacy && status == .enabled) {
                    rememberBuild()
                } else {
                    try await reregister()
                }
            }
        @unknown default:
            break
        }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? HelperServiceError { return error.description }
        let nsError = error as NSError
        switch nsError.code {
        case 1: return "macOS didn't allow FanPilot to register its helper (Operation not permitted). Move FanPilot to Applications and open it again."
        case 108: return "macOS can't find the helper inside FanPilot. Reinstall the app."
        default: return nsError.localizedDescription
        }
    }
}

enum HelperServiceError: Error, CustomStringConvertible {
    case notInBundle

    var description: String {
        "FanPilot's helper is missing from the app bundle. Build it with make app, or reinstall FanPilot."
    }
}
