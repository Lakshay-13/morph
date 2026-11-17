import Foundation

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var activeProcess: Process?

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let process = activeProcess
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    fileprivate func attach(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw MorphError.cancelled }
        activeProcess = process
    }

    fileprivate func detach(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if activeProcess === process { activeProcess = nil }
    }
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> ProcessResult {
        if cancellation?.isCancelled == true { throw MorphError.cancelled }
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBox = LockedData()
        let errBox = LockedData()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        do {
            try cancellation?.attach(process)
            try process.run()
            if cancellation?.isCancelled == true { process.terminate() }
        } catch {
            cancellation?.detach(process)
            outPipe.fileHandleForWriting.closeFile()
            errPipe.fileHandleForWriting.closeFile()
            readers.wait()
            if error is MorphError { throw error }
            throw MorphError.processFailed("Could not start \(executable.lastPathComponent): \(error.localizedDescription)")
        }

        process.waitUntilExit()
        cancellation?.detach(process)
        outPipe.fileHandleForWriting.closeFile()
        errPipe.fileHandleForWriting.closeFile()
        readers.wait()

        if cancellation?.isCancelled == true { throw MorphError.cancelled }
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outBox.get(), as: UTF8.self),
            stderr: String(decoding: errBox.get(), as: UTF8.self)
        )
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newValue: Data) {
        lock.lock()
        data = newValue
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
