import FanPilotCore
import Foundation

// fanpilotd — FanPilot's root helper. launchd starts it from
// /Library/LaunchDaemons/com.antonarnaudov.fanpilot.helper.plist.
//
//   --dry-run   never write to the SMC (forced when not running as root)
//   --version   print the version and exit

let arguments = CommandLine.arguments
if arguments.contains("--version") {
    print(FanPilot.version)
    exit(0)
}

var dryRun = arguments.contains("--dry-run")
if getuid() != 0 && !dryRun {
    FileHandle.standardError.write(Data("fanpilotd: not running as root, switching to dry run\n".utf8))
    dryRun = true
}

let helper: Helper
do {
    helper = try Helper(dryRun: dryRun)
} catch {
    FileHandle.standardError.write(Data("fanpilotd: \(error)\n".utf8))
    exit(1)
}

let listener = NSXPCListener(machServiceName: FanPilot.helperLabel)
listener.delegate = helper
listener.resume()
helper.start()

let sleepWatcher = SleepWatcher(onSleep: { helper.prepareForSleep() }, onWake: { helper.didWake() })

// Hand the fans back to macOS on every way launchd or a user stops us.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        helper.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

withExtendedLifetime(sleepWatcher) {
    dispatchMain()
}
