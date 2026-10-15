import Foundation

/// Run command-line tools. Never pass untrusted input through a shell string —
/// use `run(_:_:)` with an argument array. `runAsAdmin` is the only shell-string path
/// and quotes every argument.
enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ executable: String, _ args: [String] = [], timeout: TimeInterval = 60) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        // Read before waiting so large outputs don't deadlock on a full pipe.
        let outBuf = LockedData(), errBuf = LockedData()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outBuf.set(out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter()
        DispatchQueue.global().async { errBuf.set(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        // Every wait is bounded: a stuck child (or a grandchild holding the pipe) must not hang the caller.
        let deadline = DispatchTime.now() + timeout
        var timedOut = group.wait(timeout: deadline) == .timedOut
        if !timedOut { timedOut = exited.wait(timeout: deadline) == .timedOut }
        if timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            _ = group.wait(timeout: .now() + 1)
        }
        return Result(status: p.isRunning ? -1 : p.terminationStatus,
                      stdout: String(decoding: outBuf.get(), as: UTF8.self),
                      stderr: String(decoding: errBuf.get(), as: UTF8.self))
    }

    /// Reader threads may still write after a timeout, so the buffer is lock-guarded.
    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    static func runAsync(_ executable: String, _ args: [String] = [], timeout: TimeInterval = 60) async -> Result {
        await Task.detached(priority: .userInitiated) { run(executable, args, timeout: timeout) }.value
    }

    /// Single-quote an argument for /bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a command with administrator privileges (system password prompt).
    /// `command` is built from quoted args only.
    @discardableResult
    static func runAsAdmin(_ executable: String, _ args: [String], prompt: String = "MacMaster needs administrator access.") -> Result {
        let cmd = ([executable] + args).map(quote).joined(separator: " ")
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let promptEsc = prompt.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with prompt \"\(promptEsc)\" with administrator privileges"
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            return Result(status: Int32((error[NSAppleScript.errorNumber] as? Int) ?? 1), stdout: "",
                          stderr: (error[NSAppleScript.errorMessage] as? String) ?? "Failed")
        }
        return Result(status: 0, stdout: result?.stringValue ?? "", stderr: "")
    }
}
