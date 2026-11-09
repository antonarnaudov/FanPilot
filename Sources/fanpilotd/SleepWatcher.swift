import Foundation
import IOKit
import IOKit.pwr_mgt

/// Tells the helper when the Mac is about to sleep and when it woke.
///
/// The SMC firmware resets `Ftst` across sleep, so the helper hands the fans
/// back before sleep and takes them again after wake.
final class SleepWatcher {
    // iokit_common_msg(...) values; the macros don't import into Swift.
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemWillSleep: natural_t = 0xE000_0280
    private static let systemHasPoweredOn: natural_t = 0xE000_0300

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notifyPort: IONotificationPortRef?
    private let queue = DispatchQueue(label: "com.antonarnaudov.fanpilot.power")
    private let onSleep: () -> Void
    private let onWake: () -> Void

    init(onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.onSleep = onSleep
        self.onWake = onWake
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            Unmanaged<SleepWatcher>.fromOpaque(refcon).takeUnretainedValue().handle(messageType, argument)
        }, &notifier)
        if rootPort != 0, let notifyPort {
            IONotificationPortSetDispatchQueue(notifyPort, queue)
        }
    }

    private func handle(_ messageType: natural_t, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemWillSleep:
            onSleep()
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }
}
