import Darwin
import Foundation
import CArchive

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private let signalProcessGroup: (pid_t, Int32) -> Void
    private let waitForProcess: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t
    private var cancelled = false
    private var activeProcessGroup: pid_t?

    public convenience init() {
        self.init(
            signalProcessGroup: { processGroup, signal in
                ProcessRunner.terminate(processGroup: processGroup, signal: signal)
            },
            waitForProcess: { process, status, options in
                waitpid(process, status, options)
            }
        )
    }

    init(
        signalProcessGroup: @escaping (pid_t, Int32) -> Void,
        waitForProcess: @escaping (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t
    ) {
        self.signalProcessGroup = signalProcessGroup
        self.waitForProcess = waitForProcess
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        if let processGroup = activeProcessGroup {
            signalProcessGroup(processGroup, SIGTERM)
        }
        lock.unlock()
    }

    func attach(processGroup: pid_t) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw MorphError.cancelled }
        activeProcessGroup = processGroup
    }

    func terminateAndReap(processGroup: pid_t, processStatus: inout Int32) -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        signalProcessGroup(processGroup, SIGKILL)
        var waited: pid_t
        repeat {
            waited = waitForProcess(processGroup, &processStatus, 0)
        } while waited < 0 && errno == EINTR
        if activeProcessGroup == processGroup { activeProcessGroup = nil }
        return waited
    }

    func recoverAfterWaitFailure(processGroup: pid_t, processStatus: inout Int32) {
        lock.lock()
        defer { lock.unlock() }
        var observed: pid_t
        repeat {
            observed = waitForProcess(processGroup, &processStatus, WNOHANG)
        } while observed < 0 && errno == EINTR
        if observed == 0 {
            signalProcessGroup(processGroup, SIGKILL)
            var waited: pid_t
            repeat {
                waited = waitForProcess(processGroup, &processStatus, 0)
            } while waited < 0 && errno == EINTR
        }
        if activeProcessGroup == processGroup { activeProcessGroup = nil }
    }

    func detach(processGroup: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        if activeProcessGroup == processGroup { activeProcessGroup = nil }
    }
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let stdoutWasTruncated: Bool
    public let stderrWasTruncated: Bool
}

public struct ProcessOutputFileLimit: Sendable {
    public let url: URL
    public let maximumBytes: UInt64

    public init(url: URL, maximumBytes: UInt64) {
        self.url = url
        self.maximumBytes = maximumBytes
    }
}

enum ExternalEngineSandbox {
    static let launcher = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    static var profile: String {
        profile(readableDirectories: [], writableDirectories: []) ?? "(version 1) (deny default)"
    }

    static func profile(
        readableDirectories: [URL],
        writableDirectories: [URL],
        executable: URL? = nil
    ) -> String? {
        guard let readPaths = canonicalDirectories(readableDirectories + writableDirectories),
              let writePaths = canonicalDirectories(writableDirectories),
              let canonicalTemporaryDirectory = canonicalPath(FileManager.default.temporaryDirectory.path) else { return nil }
        guard readPaths.allSatisfy(isPrivateStageDirectory),
              writePaths.allSatisfy(isPrivateStageDirectory) else { return nil }

        func quoted(_ path: String) -> String {
            path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        let home = quoted(NSHomeDirectory())
        let temporaryDirectory = quoted(canonicalTemporaryDirectory)
        let sharedPaths = ["/Users/Shared", "/Volumes"]
        let temporaryAliases = ["/var/folders", "/private/var/folders"]
        let protectedWritePaths = ["/opt/homebrew", "/usr/local", "/Applications", "/Library", "/System"]
        var rules = [
            "(version 1)",
            "(allow default)",
            // These operations are independent of ordinary file reads/writes.
            // A writable-stage path must never let an engine link or clone
            // user files into the stage and have Morph publish them.
            "(deny file-link file-clone)",
            // Conversion engines may write only into the explicit private
            // workspaces added below. This closes writable paths outside the
            // user's home and the well-known temporary roots as well.
            "(deny file-write*)",
            "(deny network-outbound)",
            "(deny network-inbound (local ip \"*:*\"))",
            // A conversion child must not hand work to LaunchServices, create
            // launchd jobs, send Apple Events, or detach descendants from the
            // process group Morph supervises. Keep the preference daemon closed
            // because it can read user defaults on behalf of a sandboxed client.
            "(deny appleevent-send)",
            "(deny job-creation)",
            "(deny lsopen)",
            "(deny process-exec)",
            "(deny process-fork)",
            "(deny mach-lookup (global-name \"com.apple.cfprefsd.daemon\"))",
            "(deny mach-lookup (global-name \"com.apple.cfprefsd.agent\"))",
            "(deny mach-lookup (global-name \"com.apple.pasteboard.1\"))",
            "(deny mach-lookup (global-name \"com.apple.windowserver.active\"))",
            "(deny mach-lookup (global-name \"com.apple.CARenderServer\"))",
            // Do not let a compromised engine use preference APIs or signal
            // another process owned by the logged-in user as a second channel.
            "(deny user-preference-read user-preference-write)",
            "(deny signal (target others))",
            // Many CLI tools use /dev/null to discard diagnostics. Keep that
            // single device writable without reopening other filesystem paths.
            "(allow file-write* (literal \"/dev/null\"))",
            "(deny file-read* (subpath \"\(home)\"))",
            "(deny file-write* (subpath \"\(home)\"))",
            "(allow file-read-metadata (literal \"\(home)\"))",
            "(deny file-read* (subpath \"\(temporaryDirectory)\"))",
            "(deny file-write* (subpath \"\(temporaryDirectory)\"))",
            "(deny file-read* (subpath \"/tmp\"))",
            "(deny file-write* (subpath \"/tmp\"))",
            "(deny file-read* (subpath \"/private/tmp\"))",
            "(deny file-write* (subpath \"/private/tmp\"))",
            "(deny file-read* (subpath \"/var/tmp\"))",
            "(deny file-write* (subpath \"/var/tmp\"))",
            "(deny file-read* (subpath \"/private/var/tmp\"))",
            "(deny file-write* (subpath \"/private/var/tmp\"))",
        ]
        for path in sharedPaths {
            rules.append("(deny file-read* (subpath \"\(path)\"))")
            rules.append("(deny file-write* (subpath \"\(path)\"))")
        }
        for path in protectedWritePaths {
            rules.append("(deny file-write* (subpath \"\(path)\"))")
        }
        for path in temporaryAliases {
            rules.append("(deny file-read* (subpath \"\(path)\"))")
            rules.append("(deny file-write* (subpath \"\(path)\"))")
        }
        rules += readPaths.map { "(allow file-read* (subpath \"\(quoted($0))\"))" }
        rules += writePaths.map { "(allow file-write* (subpath \"\(quoted($0))\"))" }
        if let executable, let executablePath = canonicalPath(executable.path) {
            rules.append("(allow file-read* (literal \"\(quoted(executablePath))\"))")
            rules.append("(allow process-exec (literal \"\(quoted(executablePath))\"))")
            let requestedPath = executable.standardizedFileURL.path
            if requestedPath != executablePath {
                rules.append("(allow process-exec (literal \"\(quoted(requestedPath))\"))")
            }
        }
        return rules.joined(separator: " ")
    }

    private static func canonicalDirectories(_ urls: [URL]) -> Set<String>? {
        var paths = Set<String>()
        for url in urls {
            guard url.isFileURL, let path = canonicalPath(url.path) else { return nil }
            paths.insert(path)
        }
        return paths
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let pointer = path.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static func isPrivateStageDirectory(_ url: URL) -> Bool {
        guard url.isFileURL, let path = canonicalPath(url.path) else { return false }
        return isPrivateStageDirectory(path)
    }

    private static func isPrivateStageDirectory(_ path: String) -> Bool {
        let canonical = URL(fileURLWithPath: path, isDirectory: true)
        let name = canonical.lastPathComponent
        let protectedRoots = ["/opt/homebrew", "/usr/local", "/Applications", "/Library", "/System"]
        guard !protectedRoots.contains(where: { canonical.path == $0 || canonical.path.hasPrefix($0 + "/") }) else { return false }
        guard name.hasPrefix(".morph-"), name.hasSuffix(".staging"),
              UUID(uuidString: String(name.dropFirst(".morph-".count).dropLast(".staging".count))) != nil else { return false }
        let descriptor = canonical.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        return fstat(descriptor, &info) == 0
            && info.st_mode & S_IFMT == S_IFDIR
            && info.st_uid == geteuid()
            && info.st_mode & 0o777 == 0o700
            && morph_object_acl_state(descriptor) == 0
    }
}

public enum HomebrewProcessEnvironment {
    private static let proxyKeys = [
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
    ]

    public static func overrides(from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var overrides = [
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
        ]
        for key in proxyKeys {
            guard let value = environment[key], !value.isEmpty,
                  value.utf8.count <= 8_192,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            overrides[key] = value
        }
        return overrides
    }
}

public enum ProcessRunner {
    private static let terminationGracePeriod: TimeInterval = 1

    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        cancellation: CancellationToken? = nil,
        maximumOutputBytes: Int = 1_048_576,
        timeout: TimeInterval = 60 * 60,
        environmentOverrides: [String: String] = [:],
        outputFileLimit: ProcessOutputFileLimit? = nil,
        sandboxReadableDirectories: [URL] = [],
        sandboxWritableDirectories: [URL] = [],
        restrictedSandbox: Bool = false
    ) throws -> ProcessResult {
        guard cancellation?.isCancelled != true else { throw MorphError.cancelled }
        let launchExecutable = restrictedSandbox ? ExternalEngineSandbox.launcher : executable
        guard !restrictedSandbox || FileManager.default.isExecutableFile(atPath: launchExecutable.path) else {
            throw MorphError.processFailed("Morph requires macOS's restricted process sandbox for this conversion engine.")
        }
        guard executable.isFileURL,
              executable.path.hasPrefix("/"),
              maximumOutputBytes >= 0,
              timeout.isFinite, timeout > 0,
              !executable.path.utf8.contains(0),
              outputFileLimit.map({ $0.url.isFileURL && $0.url.path.hasPrefix("/") && !$0.url.path.utf8.contains(0) && $0.maximumBytes > 0 }) ?? true,
              arguments.allSatisfy({ !$0.utf8.contains(0) }),
              arguments.reduce(launchExecutable.path.utf8.count, { $0 + $1.utf8.count + 1 }) <= 1_048_576 else {
            throw MorphError.processFailed("The process request contains an invalid executable or argument list.")
        }
        if let outputFileLimit {
            guard case .missing = fileOutputState(at: outputFileLimit.url) else {
                throw MorphError.invalidOutput("The generated-file path must be absent before a conversion starts.")
            }
        }
        let sandboxHomeStage = restrictedSandbox
            ? try PrivateOutputStage(parentDirectory: FileManager.default.temporaryDirectory)
            : nil
        let sandboxCacheDirectory = sandboxHomeStage?.directoryURL.appendingPathComponent("cache", isDirectory: true)
        let sandboxTemporaryDirectory = sandboxHomeStage?.directoryURL.appendingPathComponent("tmp", isDirectory: true)
        let sandboxFontConfig = sandboxHomeStage?.directoryURL.appendingPathComponent("fonts.conf", isDirectory: false)
        if let sandboxCacheDirectory {
            try FileManager.default.createDirectory(
                at: sandboxCacheDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if let sandboxTemporaryDirectory {
            try FileManager.default.createDirectory(
                at: sandboxTemporaryDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if let sandboxFontConfig {
            let contents = """
            <?xml version="1.0"?>
            <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
            <fontconfig>
              <dir>/System/Library/Fonts</dir>
              <dir>/Library/Fonts</dir>
              <dir>/opt/homebrew/share/fonts</dir>
              <dir>/usr/local/share/fonts</dir>
              <cachedir prefix="xdg">fontconfig</cachedir>
            </fontconfig>
            """
            try Data(contents.utf8).write(to: sandboxFontConfig, options: .atomic)
            guard chmod(sandboxFontConfig.path, mode_t(0o600)) == 0 else {
                throw MorphError.processFailed("Morph could not prepare private font configuration for the conversion engine.")
            }
        }
        var resolvedEnvironmentOverrides = environmentOverrides
        let launchArguments: [String]
        if let sandboxHomeStage {
            resolvedEnvironmentOverrides["HOME"] = resolvedEnvironmentOverrides["HOME"] ?? sandboxHomeStage.directoryURL.path
            resolvedEnvironmentOverrides["XDG_CACHE_HOME"] = sandboxCacheDirectory?.path
            resolvedEnvironmentOverrides["TMPDIR"] = sandboxTemporaryDirectory?.path
            resolvedEnvironmentOverrides["TMP"] = sandboxTemporaryDirectory?.path
            resolvedEnvironmentOverrides["TEMP"] = sandboxTemporaryDirectory?.path
            resolvedEnvironmentOverrides["FONTCONFIG_FILE"] = sandboxFontConfig?.path
            let writableScopes = sandboxWritableDirectories + [sandboxHomeStage.directoryURL]
            let readableScopes = sandboxReadableDirectories + [sandboxHomeStage.directoryURL]
            guard let profile = ExternalEngineSandbox.profile(
                readableDirectories: readableScopes,
                writableDirectories: writableScopes,
                executable: executable
            ) else {
                let invalidReadable = readableScopes
                    .filter { !ExternalEngineSandbox.isPrivateStageDirectory($0) }
                    .map(\.lastPathComponent)
                let invalidWritable = writableScopes
                    .filter { !ExternalEngineSandbox.isPrivateStageDirectory($0) }
                    .map(\.lastPathComponent)
                throw MorphError.processFailed("Morph could not validate private sandbox stages (read: \(invalidReadable.joined(separator: ", ")); write: \(invalidWritable.joined(separator: ", "))).")
            }
            launchArguments = ["-p", profile, executable.path] + arguments
            guard launchArguments.allSatisfy({ !$0.utf8.contains(0) }),
                  launchArguments.reduce(launchExecutable.path.utf8.count, { $0 + $1.utf8.count + 1 }) <= 1_048_576 else {
                throw MorphError.processFailed("The restricted process request contains an invalid argument list.")
            }
        } else {
            launchArguments = arguments
        }
        let resolvedWorkingDirectory = currentDirectory ?? sandboxHomeStage?.directoryURL
        guard let workingDirectory = resolvedWorkingDirectory,
              workingDirectory.isFileURL,
              workingDirectory.path.hasPrefix("/"),
              !workingDirectory.path.utf8.contains(0) else {
            if resolvedWorkingDirectory != nil {
                throw MorphError.processFailed("The process working directory must be a local absolute path.")
            }
            return try spawnAndWait(
                executable: launchExecutable,
                arguments: launchArguments,
                currentDirectory: nil,
                cancellation: cancellation,
                maximumOutputBytes: maximumOutputBytes,
                timeout: timeout,
                environmentOverrides: resolvedEnvironmentOverrides,
                outputFileLimit: outputFileLimit
            )
        }
        return try spawnAndWait(
            executable: launchExecutable,
            arguments: launchArguments,
            currentDirectory: workingDirectory,
            cancellation: cancellation,
            maximumOutputBytes: maximumOutputBytes,
            timeout: timeout,
            environmentOverrides: resolvedEnvironmentOverrides,
            outputFileLimit: outputFileLimit
        )
    }

    fileprivate static func terminate(processGroup: pid_t, signal: Int32) {
        // Never fall back to a bare PID: the leader may already have exited
        // and that PID could have been reused by an unrelated process.
        _ = kill(-processGroup, signal)
    }

    private static func spawnAndWait(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        cancellation: CancellationToken?,
        maximumOutputBytes: Int,
        timeout: TimeInterval,
        environmentOverrides: [String: String],
        outputFileLimit: ProcessOutputFileLimit?
    ) throws -> ProcessResult {
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&stdoutPipe) == 0 else {
            throw MorphError.processFailed("Morph could not create the process output pipe.")
        }
        guard pipe(&stderrPipe) == 0 else {
            closePair(stdoutPipe)
            throw MorphError.processFailed("Morph could not create the process error pipe.")
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closePair(stdoutPipe)
            closePair(stderrPipe)
            throw MorphError.processFailed("Morph could not prepare the process file actions.")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var actionStatus = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        if actionStatus == 0 { actionStatus = posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO) }
        if actionStatus == 0 { actionStatus = posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO) }
        if actionStatus == 0 { actionStatus = posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]) }
        if actionStatus == 0 { actionStatus = posix_spawn_file_actions_addclose(&actions, stderrPipe[0]) }
        if actionStatus == 0 { actionStatus = posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]) }
        if actionStatus == 0 { actionStatus = posix_spawn_file_actions_addclose(&actions, stderrPipe[1]) }
        if actionStatus == 0, let currentDirectory {
            actionStatus = currentDirectory.path.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        }
        guard actionStatus == 0 else {
            closePair(stdoutPipe)
            closePair(stderrPipe)
            throw MorphError.processFailed("Morph could not configure the process output or working directory.")
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            closePair(stdoutPipe)
            closePair(stderrPipe)
            throw MorphError.processFailed("Morph could not prepare the process attributes.")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var childSignalMask = sigset_t()
        var childDefaultSignals = sigset_t()
        guard sigemptyset(&childSignalMask) == 0,
              sigfillset(&childDefaultSignals) == 0 else {
            closePair(stdoutPipe)
            closePair(stderrPipe)
            throw MorphError.processFailed("Morph could not prepare child-process signal handling.")
        }
        let spawnFlags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_SETSIGDEF
        )
        let attributeStatus = posix_spawnattr_setflags(&attributes, spawnFlags)
            .withSuccess { posix_spawnattr_setpgroup(&attributes, 0) }
            .withSuccess { posix_spawnattr_setsigmask(&attributes, &childSignalMask) }
            .withSuccess { posix_spawnattr_setsigdefault(&attributes, &childDefaultSignals) }
        guard attributeStatus == 0 else {
            closePair(stdoutPipe)
            closePair(stderrPipe)
            throw MorphError.processFailed("Morph could not isolate the conversion process group.")
        }

        let strings = [executable.path] + arguments
        let cArguments = strings.map { strdup($0) }
        defer { cArguments.forEach { free($0) } }
        guard cArguments.allSatisfy({ $0 != nil }) else {
            closePair(stdoutPipe)
            closePair(stderrPipe)
            throw MorphError.processFailed("Morph could not prepare the process arguments.")
        }
        var argv = cArguments.map { $0 } + [nil]

        var safeEnvironment = [
            "HOME": NSHomeDirectory(),
            "LC_ALL": "en_US.UTF-8",
            "PATH": ExecutableLocator.engineSearchPath,
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        let pathOverrides: Set<String> = [
            "HOME", "XDG_CACHE_HOME", "TMPDIR", "TMP", "TEMP",
            "MAGICK_CONFIGURE_PATH", "MAGICK_TEMPORARY_PATH", "FONTCONFIG_FILE",
        ]
        let homebrewOverrides: Set<String> = [
            "HOMEBREW_NO_ANALYTICS", "HOMEBREW_NO_AUTO_UPDATE",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        ]
        let permittedOverrides = pathOverrides.union(homebrewOverrides)
        guard Set(environmentOverrides.keys).isSubset(of: permittedOverrides),
              environmentOverrides.allSatisfy({ key, value in
                  guard value.utf8.count <= 8_192, !value.utf8.contains(0),
                        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
                  if pathOverrides.contains(key) { return value.hasPrefix("/") }
                  guard homebrewOverrides.contains(key) else { return false }
                  if key.hasPrefix("HOMEBREW_") { return value == "1" }
                  return true
              }) else {
            closePair(stdoutPipe)
            closePair(stderrPipe)
            throw MorphError.processFailed("Morph rejected an unsafe conversion-engine environment override.")
        }
        safeEnvironment.merge(environmentOverrides, uniquingKeysWith: { _, override in override })
        let environmentStrings = safeEnvironment.map { "\($0.key)=\($0.value)" }.sorted()
        let environmentSize = environmentStrings.reduce(0) { $0 + $1.utf8.count + 1 }
        guard environmentSize <= 1_048_576,
              environmentStrings.allSatisfy({ !$0.utf8.contains(0) }) else {
            closePair(stdoutPipe)
            closePair(stderrPipe)
            throw MorphError.processFailed("Morph could not prepare a safe process environment.")
        }
        let cEnvironment = environmentStrings.map { strdup($0) }
        defer { cEnvironment.forEach { free($0) } }
        guard cEnvironment.allSatisfy({ $0 != nil }) else {
            closePair(stdoutPipe)
            closePair(stderrPipe)
            throw MorphError.processFailed("Morph could not prepare a safe process environment.")
        }
        var envp = cEnvironment.map { $0 } + [nil]
        var processID: pid_t = 0
        let spawnStatus = executable.path.withCString { executablePath in
            argv.withUnsafeMutableBufferPointer { argumentBuffer in
                envp.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(&processID, executablePath, &actions, &attributes, argumentBuffer.baseAddress!, environmentBuffer.baseAddress!)
                }
            }
        }
        guard spawnStatus == 0 else {
            closePair(stdoutPipe)
            closePair(stderrPipe)
            throw MorphError.processFailed("Could not start \(executable.lastPathComponent): \(String(cString: strerror(spawnStatus)))")
        }

        close(stdoutPipe[1])
        stdoutPipe[1] = -1
        close(stderrPipe[1])
        stderrPipe[1] = -1

        guard fcntl(stdoutPipe[0], F_SETFL, O_NONBLOCK) == 0,
              fcntl(stderrPipe[0], F_SETFL, O_NONBLOCK) == 0 else {
            terminate(processGroup: processID, signal: SIGKILL)
            _ = waitpid(processID, nil, 0)
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw MorphError.processFailed("Morph could not configure bounded process output readers.")
        }

        do {
            try cancellation?.attach(processGroup: processID)
        } catch {
            terminate(processGroup: processID, signal: SIGKILL)
            _ = waitpid(processID, nil, 0)
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw error
        }

        let stdout = LockedData(limit: maximumOutputBytes)
        let stderr = LockedData(limit: maximumOutputBytes)
        let stdoutDescriptor = stdoutPipe[0]
        let stderrDescriptor = stderrPipe[0]
        let readerStopFlag = ReaderStopFlag()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(stdoutDescriptor, into: stdout, stopFlag: readerStopFlag)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(stderrDescriptor, into: stderr, stopFlag: readerStopFlag)
            readers.leave()
        }

        let startedAt = Date()
        var terminationAt: Date?
        var timedOut = false
        var outputLimitExceeded = false
        var outputFileRejected = false
        var processStatus: Int32 = 0
        while true {
            let now = Date()
            if terminationAt == nil, let outputFileLimit {
                switch fileOutputState(at: outputFileLimit.url) {
                case .regular(let size) where size > outputFileLimit.maximumBytes:
                    outputLimitExceeded = true
                case .unsafe:
                    outputFileRejected = true
                case .missing, .regular:
                    break
                }
                if outputLimitExceeded || outputFileRejected {
                    terminate(processGroup: processID, signal: SIGTERM)
                    terminationAt = now
                }
            }
            if cancellation?.isCancelled == true, terminationAt == nil {
                terminate(processGroup: processID, signal: SIGTERM)
                terminationAt = now
            } else if now.timeIntervalSince(startedAt) >= timeout, terminationAt == nil {
                timedOut = true
                terminate(processGroup: processID, signal: SIGTERM)
                terminationAt = now
            } else if let terminationAt, now.timeIntervalSince(terminationAt) >= terminationGracePeriod {
                terminate(processGroup: processID, signal: SIGKILL)
            }

            var childState = siginfo_t()
            let waitStatus = waitid(P_PID, id_t(processID), &childState, WEXITED | WNOHANG | WNOWAIT)
            if waitStatus == 0, childState.si_pid != 0 {
                // Conversion tools must not outlive their leader, including a
                // successful shell that started a detached background child.
                // WNOWAIT keeps the leader PID reserved while the group signal
                // is sent, avoiding a process-group ID reuse race.
                var waited: pid_t
                if let cancellation {
                    waited = cancellation.terminateAndReap(processGroup: processID, processStatus: &processStatus)
                } else {
                    terminate(processGroup: processID, signal: SIGKILL)
                    repeat {
                        waited = waitpid(processID, &processStatus, 0)
                    } while waited < 0 && errno == EINTR
                }
                guard waited == processID else {
                    cancellation?.detach(processGroup: processID)
                    throw MorphError.processFailed("Morph could not reap the completed conversion process.")
                }
                break
            }
            if waitStatus == -1, errno != EINTR {
                if let cancellation {
                    cancellation.recoverAfterWaitFailure(processGroup: processID, processStatus: &processStatus)
                } else {
                    var observed: pid_t
                    repeat {
                        observed = waitpid(processID, &processStatus, WNOHANG)
                    } while observed < 0 && errno == EINTR
                    if observed == 0 {
                        terminate(processGroup: processID, signal: SIGKILL)
                        var waited: pid_t
                        repeat {
                            waited = waitpid(processID, &processStatus, 0)
                        } while waited < 0 && errno == EINTR
                    }
                }
                throw MorphError.processFailed("Morph could not wait for the conversion process.")
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        cancellation?.detach(processGroup: processID)

        if readers.wait(timeout: .now() + 2) == .timedOut {
            // The leader has already been reaped, so its process-group ID can
            // eventually be reused. Stop nonblocking readers without signaling
            // that stale ID; descendants in the original group were killed
            // before the leader was reaped above.
            readerStopFlag.requestStop()
            _ = readers.wait(timeout: .now() + 1)
        }

        if outputFileRejected { throw MorphError.invalidOutput("Morph stopped a process that replaced its generated-file path with a non-regular file.") }
        if outputLimitExceeded { throw MorphError.invalidOutput("The generated file exceeded Morph's configured size limit and was stopped.") }
        if let outputFileLimit {
            switch fileOutputState(at: outputFileLimit.url) {
            case .regular(let size) where size > outputFileLimit.maximumBytes:
                throw MorphError.invalidOutput("The generated file exceeded Morph's configured size limit.")
            case .unsafe:
                throw MorphError.invalidOutput("The generated-file path is not a regular file.")
            case .missing, .regular:
                break
            }
        }
        if cancellation?.isCancelled == true { throw MorphError.cancelled }
        if timedOut { throw MorphError.processFailed("\(executable.lastPathComponent) exceeded Morph's \(Int(timeout))-second execution limit and was stopped.") }

        let exitStatus: Int32
        let terminatingSignal = processStatus & 0x7f
        if terminatingSignal == 0 {
            exitStatus = (processStatus >> 8) & 0xff
        } else if terminatingSignal != 0x7f {
            exitStatus = 128 + terminatingSignal
        } else {
            exitStatus = processStatus
        }
        let stdoutResult = stdout.snapshot()
        let stderrResult = stderr.snapshot()
        return ProcessResult(
            status: exitStatus,
            stdout: String(decoding: stdoutResult.data, as: UTF8.self),
            stderr: String(decoding: stderrResult.data, as: UTF8.self),
            stdoutWasTruncated: stdoutResult.wasTruncated,
            stderrWasTruncated: stderrResult.wasTruncated
        )
    }

    private enum FileOutputState {
        case missing
        case regular(UInt64)
        case unsafe
    }

    private static func fileOutputState(at url: URL) -> FileOutputState {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result != 0, errno == ENOENT { return .missing }
        guard result == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { return .unsafe }
        return .regular(UInt64(info.st_size))
    }

    private static func closePair(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
    }

    private static func drain(_ descriptor: Int32, into storage: LockedData, stopFlag: ReaderStopFlag) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !stopFlag.shouldStop {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                storage.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                Thread.sleep(forTimeInterval: 0.025)
            } else {
                break
            }
        }
        close(descriptor)
    }
}

private final class ReaderStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func requestStop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var wasTruncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ bytes: [UInt8], count: Int) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        let captured = min(remaining, count)
        if captured > 0 { data.append(contentsOf: bytes.prefix(captured)) }
        if captured < count { wasTruncated = true }
    }

    func snapshot() -> (data: Data, wasTruncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, wasTruncated)
    }
}

private extension Int32 {
    func withSuccess(_ next: () -> Int32) -> Int32 {
        self == 0 ? next() : self
    }
}
