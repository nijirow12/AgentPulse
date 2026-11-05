import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Minimal `Process` wrapper. Blocking, so call it off the main actor.
public enum Shell {
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 5,
        environment: [String: String]? = nil
    ) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector()
        let readers = DispatchGroup()

        func drain(_ handle: FileHandle, _ sink: @escaping @Sendable (Data) -> Void) {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = handle.readDataToEndOfFile()
                sink(data)
                readers.leave()
            }
        }

        drain(outPipe.fileHandleForReading) { collector.setStdout($0) }
        drain(errPipe.fileHandleForReading) { collector.setStderr($0) }

        do {
            try process.run()
        } catch {
            // No child ever owned the pipes; close our ends so the readers see EOF.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            _ = readers.wait(timeout: .now() + 1)
            return ShellResult(status: -1, stderr: error.localizedDescription)
        }

        // EOF for the readers should only depend on the child now.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut

        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }

        // Readers finish once the pipes reach EOF (the child is gone).
        _ = readers.wait(timeout: .now() + 2)

        let status = timedOut ? -1 : process.terminationStatus
        return ShellResult(
            status: status,
            stdout: collector.stdout,
            stderr: collector.stderr,
            timedOut: timedOut
        )
    }
}

/// Thread-safe byte buffer shared with the pipe-reading queues.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func setStdout(_ data: Data) {
        lock.lock()
        out = data
        lock.unlock()
    }

    func setStderr(_ data: Data) {
        lock.lock()
        err = data
        lock.unlock()
    }

    var stdout: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }

    var stderr: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: err, as: UTF8.self)
    }
}
