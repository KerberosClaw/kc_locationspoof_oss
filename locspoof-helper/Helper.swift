import Foundation

enum HelperError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    case tunnelStartFailed(String)
    case dvtStartFailed(String)
    case injectFailed(String)
    case clearFailed(String)
    case notReady

    var description: String {
        switch self {
        case .binaryNotFound(let p): return "binary not found: \(p)"
        case .tunnelStartFailed(let m): return "tunnel: \(m)"
        case .dvtStartFailed(let m): return "dvt: \(m)"
        case .injectFailed(let m): return "inject: \(m)"
        case .clearFailed(let m): return "clear: \(m)"
        case .notReady: return "dvt stream not ready"
        }
    }
}

enum HelperState: String {
    case waitingForDevice = "waiting_for_device"
    case connecting       = "connecting"
    case ready            = "ready"
    case restarting       = "restarting"
}

private let retrySleepSeconds: Int = 5

final class Helper {
    private let pmdBin: URL
    private let dvtBin: URL

    private var tunnelProc: Process?
    private var dvtProc: Process?
    private var dvtStdin: FileHandle?
    private var dvtStdout: FileHandle?

    private(set) var rsdHost: String?
    private(set) var rsdPort: String?
    private(set) var lastSeq: Int = 0
    private(set) var lastLoc: (Double, Double)?
    private var state: HelperState = .waitingForDevice
    private var shutdownRequested = false

    private let lock = NSLock()
    /// Signalled when a subprocess (tunnel or dvt) terminates. Drained at the
    /// top of each retry iteration so leftover signals from a previous cycle
    /// don't fire prematurely.
    private let subprocessExitSemaphore = DispatchSemaphore(value: 0)
    /// Signalled by requestShutdown() to break out of the retry-loop sleep.
    private let wakeupSemaphore = DispatchSemaphore(value: 0)
    /// Signalled by retryLoop() on exit so requestShutdown() can wait for
    /// final cleanup to complete before the process exits.
    private let shutdownDoneSemaphore = DispatchSemaphore(value: 0)

    init(pmdBin: URL, dvtBin: URL) throws {
        guard FileManager.default.fileExists(atPath: pmdBin.path) else {
            throw HelperError.binaryNotFound(pmdBin.path)
        }
        guard FileManager.default.fileExists(atPath: dvtBin.path) else {
            throw HelperError.binaryNotFound(dvtBin.path)
        }
        self.pmdBin = pmdBin
        self.dvtBin = dvtBin
    }

    func start() throws {
        try startTunnel()
        try startDvtStream()
    }

    /// Run an infinite retry loop on a background queue. Returns immediately.
    /// On subprocess death or startup failure, sleep retrySleepSeconds and try
    /// again. Replaces the old "exit on any failure → launchd respawns me"
    /// design, which fed launchd's KeepAlive throttle and ramped backoff into
    /// minutes after enough quick exits.
    func runForever() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.retryLoop()
        }
    }

    private func retryLoop() {
        defer { shutdownDoneSemaphore.signal() }
        while !shutdownCheck() {
            // Drain leftover signals from prior iteration (e.g. both procs
            // died near-simultaneously, signalling twice).
            while subprocessExitSemaphore.wait(timeout: .now()) == .success {}

            do {
                setState(.connecting)
                try start()
                setState(.ready)
                subprocessExitSemaphore.wait()
                if shutdownCheck() { break }
                log("[retry] subprocess died, will reconnect")
            } catch {
                log("[retry] start failed: \(error)")
            }

            setState(.restarting)
            cleanupSubprocesses()
            if shutdownCheck() { break }
            // Interruptable sleep — requestShutdown() signals wakeupSemaphore
            // so SIGTERM cleanup completes within launchd's exit timeout.
            _ = wakeupSemaphore.wait(timeout: .now() + .seconds(retrySleepSeconds))
        }
        cleanupSubprocesses()
        setState(.waitingForDevice)
        log("[shutdown] retry loop ended")
    }

    /// Tear down the retry loop and any in-flight subprocesses. Blocks up to
    /// `timeout` waiting for retryLoop() to finish, so SIGTERM cleanup
    /// completes within launchd's 5s exit window before exit(0).
    func requestShutdown(timeout: TimeInterval = 4.0) {
        lock.lock()
        shutdownRequested = true
        let tun = tunnelProc
        let dvt = dvtProc
        lock.unlock()
        // Bust any in-progress startup blocked on subprocess I/O (e.g. mid
        // readLine waiting for HOST PORT). Without this, shutdown could stall
        // up to startTunnel's 45s deadline.
        tun?.terminate()
        dvt?.terminate()
        wakeupSemaphore.signal()
        subprocessExitSemaphore.signal()
        _ = shutdownDoneSemaphore.wait(timeout: .now() + .milliseconds(Int(timeout * 1000)))
    }

    private func shutdownCheck() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return shutdownRequested
    }

    private func setState(_ s: HelperState) {
        lock.lock()
        state = s
        lock.unlock()
    }

    private func startTunnel() throws {
        let proc = Process()
        proc.executableURL = pmdBin
        proc.arguments = ["remote", "start-tunnel", "--script-mode"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        // On termination, signal the retry loop instead of exiting the helper.
        // The retry loop owns reconnection; launchd's KeepAlive throttle never
        // sees the device-absent transient failures we're handling here.
        proc.terminationHandler = { [weak self] p in
            log("[tunnel] exited status=\(p.terminationStatus)")
            self?.subprocessExitSemaphore.signal()
        }
        try proc.run()
        // Close the parent's copy of the write ends so drain's read end will
        // see EOF when pmd exits (otherwise we hold the pipe open and drain
        // blocks forever on availableData).
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // On any failure path before stash, close pipe FDs explicitly to avoid
        // leaks across hundreds of retry iterations.
        var success = false
        defer {
            if !success {
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
            }
        }

        // Deadline: kill pmd if HOST PORT line doesn't arrive in time
        // (e.g. iPhone swap with stale pair, lockdownd deadlock, DDI not mounted).
        let deadline = makeDeadline(seconds: 45) { [weak proc] in
            if let proc = proc, proc.isRunning {
                log("[tunnel] timeout waiting for HOST PORT, killing pmd")
                proc.terminate()
            }
        }

        guard let line = readLine(from: stdoutPipe.fileHandleForReading)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty
        else {
            deadline.cancel()
            let err = readAvailable(stderrPipe.fileHandleForReading)
            throw HelperError.tunnelStartFailed("no HOST PORT (timeout?); stderr: \(err)")
        }
        deadline.cancel()
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw HelperError.tunnelStartFailed("unexpected first line: \(line)")
        }
        rsdHost = parts[0]
        rsdPort = parts[1]
        tunnelProc = proc
        success = true
        log("[tunnel] up at \(parts[0]):\(parts[1])")
        // After HOST PORT is consumed, pmd may keep emitting log lines on
        // stdout/stderr while the tunnel is up. If nobody drains them the
        // 64 KB pipe buffer fills and pmd blocks on its next write — tunnel
        // looks alive but is silently stuck. Drain both into the helper log.
        spawnDrain(stdoutPipe.fileHandleForReading, label: "tunnel.out")
        spawnDrain(stderrPipe.fileHandleForReading, label: "tunnel.err")
    }

    private func startDvtStream() throws {
        guard let host = rsdHost, let port = rsdPort else {
            throw HelperError.dvtStartFailed("rsd not ready")
        }
        let proc = Process()
        proc.executableURL = dvtBin
        proc.arguments = [host, port]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.terminationHandler = { [weak self] p in
            log("[dvt] exited status=\(p.terminationStatus)")
            self?.subprocessExitSemaphore.signal()
        }
        try proc.run()
        // Close parent's copies of the ends we don't use, so EOF propagates
        // properly when dvt exits.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        var success = false
        defer {
            if !success {
                try? stdinPipe.fileHandleForWriting.close()
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
            }
        }

        let deadline = makeDeadline(seconds: 30) { [weak proc] in
            if let proc = proc, proc.isRunning {
                log("[dvt] timeout waiting for READY, killing dvt")
                proc.terminate()
            }
        }

        guard let line = readLine(from: stdoutPipe.fileHandleForReading)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            deadline.cancel()
            let err = readAvailable(stderrPipe.fileHandleForReading)
            throw HelperError.dvtStartFailed("no READY (timeout?); stderr: \(err)")
        }
        guard line == "READY" else {
            deadline.cancel()
            let err = readAvailable(stderrPipe.fileHandleForReading)
            throw HelperError.dvtStartFailed("expected READY got \(line); stderr: \(err)")
        }
        deadline.cancel()
        dvtProc = proc
        dvtStdin = stdinPipe.fileHandleForWriting
        dvtStdout = stdoutPipe.fileHandleForReading
        success = true
        log("[dvt] stream ready")
        // dvt-location-stream protocol is request/response on stdin/stdout, so
        // its stdout has nothing to drain (inject/clear consume responses
        // synchronously). stderr can fill though, so drain it.
        spawnDrain(stderrPipe.fileHandleForReading, label: "dvt.err")
    }

    /// Read until EOF on `fh` and forward every line to the helper log,
    /// labelled. Exits naturally when the pipe closes (subprocess died).
    /// Truncates absurdly long lines so a misbehaving subprocess can't push
    /// arbitrary data into our log.
    private func spawnDrain(_ fh: FileHandle, label: String) {
        DispatchQueue.global(qos: .background).async {
            var buffer = Data()
            let maxLine = 4096
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { return }  // EOF — subprocess gone
                for byte in chunk {
                    if byte == 0x0A {
                        let line = String(data: buffer, encoding: .utf8) ?? "<non-utf8>"
                        log("[\(label)] \(line)")
                        buffer.removeAll(keepingCapacity: true)
                    } else {
                        if buffer.count < maxLine { buffer.append(byte) }
                    }
                }
            }
        }
    }

    func inject(lat: Double, lon: Double) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let stdin = dvtStdin, let stdout = dvtStdout else {
            throw HelperError.notReady
        }
        lastSeq += 1
        let seq = lastSeq
        let cmd = "\(seq),\(lat),\(lon)\n"
        // Use throwing variant: writing to a stdin closed by cleanupSubprocesses()
        // would otherwise raise an Obj-C exception and crash the helper.
        do {
            try stdin.write(contentsOf: Data(cmd.utf8))
        } catch {
            throw HelperError.injectFailed("write failed: \(error)")
        }
        // Deadline: if dvt is alive but unresponsive (deadlocked), terminate
        // it so the readLine sees EOF and we release the lock instead of
        // hanging every subsequent HTTP request.
        let deadline = makeDeadline(seconds: 5) { [weak self] in
            log("[inject] response timeout, killing dvt to recover")
            self?.dvtProc?.terminate()
        }
        defer { deadline.cancel() }
        guard let resp = readLine(from: stdout)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw HelperError.injectFailed("no response (timeout?)")
        }
        guard resp.hasPrefix("OK \(seq)") else {
            throw HelperError.injectFailed("rejected: \(resp)")
        }
        lastLoc = (lat, lon)
        return seq
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let stdin = dvtStdin, let stdout = dvtStdout else {
            throw HelperError.notReady
        }
        do {
            try stdin.write(contentsOf: Data("CLEAR\n".utf8))
        } catch {
            throw HelperError.clearFailed("write failed: \(error)")
        }
        let deadline = makeDeadline(seconds: 5) { [weak self] in
            log("[clear] response timeout, killing dvt to recover")
            self?.dvtProc?.terminate()
        }
        defer { deadline.cancel() }
        guard let resp = readLine(from: stdout)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw HelperError.clearFailed("no response (timeout?)")
        }
        guard resp == "CLEARED" else {
            throw HelperError.clearFailed("rejected: \(resp)")
        }
        lastLoc = nil
    }

    /// Tear down current subprocess generation and reset all refs to nil so
    /// the next start() begins from a clean slate. Used both between retry
    /// iterations and on final shutdown.
    ///
    /// Lock discipline: ref-swap happens under `lock` (so concurrent inject()
    /// / clear() either see a complete prior generation or notReady — never a
    /// torn state). The actual QUIT/terminate I/O runs outside the lock so a
    /// slow subprocess can't block HTTP-thread inspection of statusDict.
    private func cleanupSubprocesses() {
        lock.lock()
        let dvt = dvtProc
        let tun = tunnelProc
        let stdin = dvtStdin
        let stdoutH = dvtStdout
        // Detach handlers first: the upcoming terminate() would otherwise
        // signal subprocessExitSemaphore and pollute the next iteration.
        dvt?.terminationHandler = nil
        tun?.terminationHandler = nil
        dvtStdin = nil
        dvtStdout = nil
        dvtProc = nil
        tunnelProc = nil
        rsdHost = nil
        rsdPort = nil
        lock.unlock()

        if let stdin = stdin {
            try? stdin.write(contentsOf: "QUIT\n".data(using: .utf8)!)
            try? stdin.close()
        }
        try? stdoutH?.close()
        if let dvt = dvt, dvt.isRunning {
            DispatchQueue.global().async { dvt.waitUntilExit() }
            Thread.sleep(forTimeInterval: 0.5)
            if dvt.isRunning { dvt.terminate() }
        }
        if let tun = tun, tun.isRunning {
            tun.terminate()
        }
    }

    var statusDict: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var dict: [String: Any] = [
            "state": state.rawValue,
            "tunnel": rsdHost.map { "\($0):\(rsdPort ?? "")" } as Any? ?? NSNull(),
            "dvt_alive": dvtProc?.isRunning ?? false,
            "last_seq": lastSeq,
        ]
        if let (lat, lon) = lastLoc {
            dict["last_loc"] = [lat, lon]
        } else {
            dict["last_loc"] = NSNull()
        }
        return dict
    }
}

/// Schedule a one-shot timer that fires after `seconds`. Returns the source so
/// callers can cancel it on the success path before it fires.
func makeDeadline(seconds: Int, _ handler: @escaping () -> Void) -> DispatchSourceTimer {
    let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    t.schedule(deadline: .now() + .seconds(seconds))
    t.setEventHandler(handler: handler)
    t.resume()
    return t
}

func readLine(from fh: FileHandle) -> String? {
    var buffer = Data()
    while true {
        let chunk = fh.availableData
        if chunk.isEmpty {
            return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
        }
        for byte in chunk {
            buffer.append(byte)
            if byte == 0x0A {
                return String(data: buffer, encoding: .utf8)
            }
        }
    }
}

func readAvailable(_ fh: FileHandle) -> String {
    let data = fh.availableData
    return String(data: data, encoding: .utf8) ?? ""
}

func log(_ message: String) {
    let line = "\(Date()) \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
}
