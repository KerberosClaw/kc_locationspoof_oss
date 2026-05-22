import Foundation
import Darwin

func currentExecutablePath() -> String {
    var size = UInt32(PATH_MAX)
    var buf = [CChar](repeating: 0, count: Int(size) + 1)
    if _NSGetExecutablePath(&buf, &size) != 0 {
        var growBuf = [CChar](repeating: 0, count: Int(size) + 1)
        _ = _NSGetExecutablePath(&growBuf, &size)
        return String(cString: growBuf)
    }
    return String(cString: buf)
}

let executableURL = URL(fileURLWithPath: currentExecutablePath()).resolvingSymlinksInPath()
let macOSDir = executableURL.deletingLastPathComponent()
let contentsDir = macOSDir.deletingLastPathComponent()
let resourcesBin = contentsDir.appendingPathComponent("Resources/bin")

let pmdBin = ProcessInfo.processInfo.environment["PYMOBILEDEVICE3_BIN"]
    .map(URL.init(fileURLWithPath:))
    ?? resourcesBin.appendingPathComponent("pymobiledevice3")
let dvtBin = ProcessInfo.processInfo.environment["DVT_STREAM_BIN"]
    .map(URL.init(fileURLWithPath:))
    ?? resourcesBin.appendingPathComponent("dvt-location-stream")

log("[boot] pmd=\(pmdBin.path)")
log("[boot] dvt=\(dvtBin.path)")

let helper: Helper
do {
    helper = try Helper(pmdBin: pmdBin, dvtBin: dvtBin)
} catch {
    // Only hard config errors (binary not found) fail boot — these aren't
    // recoverable by retry, so let launchd see the failure.
    log("[boot] helper init failed: \(error)")
    exit(2)
}

// Open HTTP listener BEFORE the helper attempts to connect. /api/status will
// answer "waiting_for_device" before the iPhone shows up, so the GUI can
// distinguish "helper alive but device absent" from "helper dead".
let server: HTTPServer
do {
    server = try HTTPServer(helper: helper, port: 8765)
} catch {
    log("[boot] http listener init failed: \(error)")
    exit(3)
}
server.start()

// Helper-internal retry loop: replaces the old "exit-and-let-launchd-respawn"
// pattern. Quick subprocess failures stay in user space so launchd's KeepAlive
// throttle doesn't ramp into multi-minute backoffs after transient issues.
helper.runForever()

let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSrc.setEventHandler {
    log("[shutdown] SIGTERM")
    helper.requestShutdown()
    exit(0)
}
sigtermSrc.resume()
signal(SIGTERM, SIG_IGN)

let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSrc.setEventHandler {
    log("[shutdown] SIGINT")
    helper.requestShutdown()
    exit(0)
}
sigintSrc.resume()
signal(SIGINT, SIG_IGN)

RunLoop.main.run()
