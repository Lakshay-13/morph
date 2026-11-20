import CArchive
import Darwin
import Foundation

struct OutputPublicationCollision: Error {}

enum OutputDirectorySecurity {
    static func hasExtendedACL(_ descriptor: Int32) -> Bool? {
        let state = morph_object_acl_state(descriptor)
        return state < 0 ? nil : state == 1
    }

    static func validate(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw MorphError.invalidOutput("Morph could not validate the selected output folder.")
        }

        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0,
              supportsPrivateStaging(on: UInt64(filesystem.f_flags)) else {
            throw MorphError.invalidOutput("Choose a writable local volume with file ownership enabled for safe output staging.")
        }

        let writableByOthers = info.st_mode & (S_IWGRP | S_IWOTH) != 0
        let ownerProtected = info.st_uid == geteuid() && !writableByOthers
        let stickyProtected = info.st_mode & S_ISVTX != 0 && (info.st_uid == geteuid() || info.st_uid == 0)
        let aclFlags = morph_directory_acl_security_flags(descriptor)
        guard ownerProtected || stickyProtected,
              aclFlags == 0 else {
            throw MorphError.invalidOutput("Choose an output or extraction folder that other accounts cannot rename items in and that does not inherit access to temporary files.")
        }
    }

    static func supportsPrivateStaging(on flags: UInt64) -> Bool {
        let readOnly = UInt64(MNT_RDONLY)
        let local = UInt64(MNT_LOCAL)
        let ignoresOwnership = UInt64(MNT_IGNORE_OWNERSHIP)
        return flags & readOnly == 0
            && flags & local != 0
            && flags & ignoresOwnership == 0
    }
}

/// Reports whether Morph can safely create and publish private staging files in
/// a selected output directory. This lets the UI route filesystems without
/// reliable per-user permissions to Morph Output before starting an operation.
public enum OutputDirectoryPolicy {
    public static func canSafelyStage(in directory: URL) -> Bool {
        guard directory.isFileURL else { return false }
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        do {
            try OutputDirectorySecurity.validate(descriptor)
            return true
        } catch {
            return false
        }
    }
}

enum StaleMorphStageCleanup {
    static let defaultMinimumAge: TimeInterval = 24 * 60 * 60
    static let ownershipMarkerName = ".morph-stage-owner"
    private static let maximumScannedEntries = 5_000
    private static let maximumRemovedStages = 16

    static func createOwnershipMarker(
        in parentDescriptor: Int32,
        directoryDescriptor: Int32,
        directoryName: String
    ) throws {
        guard isSafeStageName(directoryName) else {
            throw MorphError.invalidOutput("Morph could not mark its private staging folder.")
        }
        var stageInfo = stat()
        var entryInfo = stat()
        guard fstat(directoryDescriptor, &stageInfo) == 0,
              fstatat(parentDescriptor, directoryName, &entryInfo, AT_SYMLINK_NOFOLLOW) == 0,
              stageInfo.st_mode & S_IFMT == S_IFDIR,
              entryInfo.st_mode & S_IFMT == S_IFDIR,
              stageInfo.st_dev == entryInfo.st_dev,
              stageInfo.st_ino == entryInfo.st_ino else {
            throw MorphError.invalidOutput("Morph could not verify its private staging folder.")
        }
        let markerName = ownershipMarkerName(for: directoryName)
        let descriptor = markerName.withCString {
            openat(parentDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw MorphError.invalidOutput("Morph could not mark its private staging folder.")
        }
        do {
            let data = markerContents(for: directoryName)
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let result = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                    if result < 0 && errno == EINTR { continue }
                    guard result > 0 else {
                        throw MorphError.invalidOutput("Morph could not finish marking its private staging folder.")
                    }
                    offset += result
                }
            }
            guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
                throw MorphError.invalidOutput("Morph could not finish marking its private staging folder.")
            }
            close(descriptor)
        } catch {
            var markerInfo = stat()
            var currentMarkerInfo = stat()
            if fstat(descriptor, &markerInfo) == 0,
               markerName.withCString({ fstatat(parentDescriptor, $0, &currentMarkerInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
               markerInfo.st_dev == currentMarkerInfo.st_dev,
               markerInfo.st_ino == currentMarkerInfo.st_ino {
                _ = markerName.withCString { unlinkat(parentDescriptor, $0, 0) }
            }
            close(descriptor)
            throw error
        }
    }

    static func markerContents(for directoryName: String) -> Data {
        EngineExecutableTrust.authenticatedStageMarker(for: directoryName)
            ?? Data("Morph untrusted staging directory\n\(directoryName)\n".utf8)
    }

    static func ownershipMarkerName(for directoryName: String) -> String {
        "\(ownershipMarkerName)-\(directoryName)"
    }

    static func removeOwnershipMarker(in parentDescriptor: Int32, directoryName: String) -> Bool {
        guard isSafeStageName(directoryName) else { return false }
        let expectedMarker = markerContents(for: directoryName)
        let markerName = ownershipMarkerName(for: directoryName)
        let descriptor = markerName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard markerContentsMatch(descriptor: descriptor, expectedMarker: expectedMarker) else { return false }
        var opened = stat()
        var current = stat()
        guard fstat(descriptor, &opened) == 0,
              markerName.withCString({ fstatat(parentDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
              opened.st_dev == current.st_dev,
              opened.st_ino == current.st_ino else { return false }
        return markerName.withCString { unlinkat(parentDescriptor, $0, 0) } == 0
    }

    private static func isSafeStageName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }

    private static func markerContentsMatch(descriptor: Int32, expectedMarker: Data) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600,
              info.st_size == expectedMarker.count else { return false }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { return false }
            offset += amount
        }
        return data == expectedMarker
    }

    static func remove(in parentDirectory: URL, olderThan age: TimeInterval = defaultMinimumAge) {
        guard parentDirectory.isFileURL, age.isFinite, age >= defaultMinimumAge else { return }
        let parentFD = parentDirectory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard parentFD >= 0 else { return }
        defer { close(parentFD) }

        let scanFD = dup(parentFD)
        guard scanFD >= 0,
              fcntl(scanFD, F_SETFD, FD_CLOEXEC) == 0,
              let directory = fdopendir(scanFD) else {
            if scanFD >= 0 { close(scanFD) }
            return
        }
        defer { closedir(directory) }

        let cutoff = Date().addingTimeInterval(-age).timeIntervalSince1970
        var scanned = 0
        var removed = 0
        while scanned < maximumScannedEntries, removed < maximumRemovedStages,
              let entry = readdir(directory) {
            scanned += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            guard isMorphStageName(name) else { continue }

            var before = stat()
            guard name.withCString({ fstatat(parentFD, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0,
                  before.st_mode & S_IFMT == S_IFDIR,
                  before.st_uid == geteuid(),
                  before.st_mode & 0o777 == 0o700,
                  Double(before.st_mtimespec.tv_sec) <= cutoff else { continue }

            let stageFD = name.withCString {
                openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard stageFD >= 0 else { continue }
            defer { close(stageFD) }

            var opened = stat()
            guard fstat(stageFD, &opened) == 0,
                  opened.st_uid == geteuid(),
                  opened.st_mode & 0o777 == 0o700,
                  opened.st_dev == before.st_dev,
                  opened.st_ino == before.st_ino,
                  hasValidOwnershipMarker(in: parentFD, directoryName: name) else { continue }
            do { try ArchiveExtractor.removeContents(of: stageFD) }
            catch { continue }

            var current = stat()
            guard name.withCString({ fstatat(parentFD, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
                  current.st_mode & S_IFMT == S_IFDIR,
                  current.st_uid == geteuid(),
                  current.st_dev == opened.st_dev,
                  current.st_ino == opened.st_ino,
                  name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) }) == 0 else { continue }
            _ = removeOwnershipMarker(in: parentFD, directoryName: name)
            removed += 1
        }
    }

    private static func hasValidOwnershipMarker(in parentDescriptor: Int32, directoryName: String) -> Bool {
        guard let expectedMarker = EngineExecutableTrust.authenticatedStageMarker(for: directoryName) else { return false }
        let markerName = ownershipMarkerName(for: directoryName)
        let descriptor = markerName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return markerContentsMatch(descriptor: descriptor, expectedMarker: expectedMarker)
    }

    private static func isMorphStageName(_ name: String) -> Bool {
        matches(name, prefix: ".morph-", suffix: ".staging")
            || matches(name, prefix: ".morph-extract-", suffix: "")
            || matches(name, prefix: "Morph-archive-", suffix: "")
    }

    private static func matches(_ name: String, prefix: String, suffix: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return false }
        let identifier = name.dropFirst(prefix.count).dropLast(suffix.count)
        return UUID(uuidString: String(identifier)) != nil
    }
}

struct PublishedFileIdentity: Sendable {
    let outputURL: URL
    let parentDevice: UInt64
    let parentInode: UInt64
    let fileDevice: UInt64
    let fileInode: UInt64
}

enum PublishedFileCleanup {
    @discardableResult
    static func removeIfUnchanged(_ published: PublishedFileIdentity) -> Bool {
        let parent = published.outputURL.deletingLastPathComponent()
        let descriptor = parent.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var parentInfo = stat()
        guard fstat(descriptor, &parentInfo) == 0,
              UInt64(parentInfo.st_dev) == published.parentDevice,
              UInt64(parentInfo.st_ino) == published.parentInode else { return false }

        let fileName = published.outputURL.lastPathComponent
        var fileInfo = stat()
        let status = fileName.withCString { fstatat(descriptor, $0, &fileInfo, AT_SYMLINK_NOFOLLOW) }
        if status != 0 { return errno == ENOENT }
        guard fileInfo.st_mode & S_IFMT == S_IFREG,
              UInt64(fileInfo.st_dev) == published.fileDevice,
              UInt64(fileInfo.st_ino) == published.fileInode else { return false }
        return fileName.withCString { unlinkat(descriptor, $0, 0) } == 0
    }
}

enum PinnedDirectoryPath {
    static func matches(_ directoryURL: URL, descriptor: Int32) -> Bool {
        guard directoryURL.isFileURL else { return false }
        let currentDescriptor = directoryURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard currentDescriptor >= 0 else { return false }
        defer { close(currentDescriptor) }
        var pinnedInfo = stat()
        var currentInfo = stat()
        return fstat(descriptor, &pinnedInfo) == 0
            && fstat(currentDescriptor, &currentInfo) == 0
            && pinnedInfo.st_dev == currentInfo.st_dev
            && pinnedInfo.st_ino == currentInfo.st_ino
    }

    static func entry(named name: String, in parentDescriptor: Int32, matches expectedDescriptor: Int32) -> Bool {
        var expectedInfo = stat()
        var currentInfo = stat()
        let status = name.withCString { fstatat(parentDescriptor, $0, &currentInfo, AT_SYMLINK_NOFOLLOW) }
        return status == 0
            && currentInfo.st_mode & S_IFMT == S_IFDIR
            && fstat(expectedDescriptor, &expectedInfo) == 0
            && expectedInfo.st_mode & S_IFMT == S_IFDIR
            && expectedInfo.st_dev == currentInfo.st_dev
            && expectedInfo.st_ino == currentInfo.st_ino
    }
}

/// A same-volume, descriptor-anchored staging directory for generated output.
/// Its ACL is removed and mode is forced to 0700 before an engine writes into it.
final class PrivateOutputStage {
    private let parentURL: URL
    let directoryURL: URL
    private let parentDescriptor: Int32
    private let directoryDescriptor: Int32
    private let directoryName: String
    private let primaryFileName: String?
    private(set) var lastPublishedIdentity: PublishedFileIdentity?

    /// File descriptor access for internal helpers that add a private input to
    /// the stage. Callers must keep this stage alive for the descriptor's use.
    var directoryDescriptorForInputSnapshot: Int32 { directoryDescriptor }

    func temporaryOutputURL() throws -> URL {
        guard let primaryFileName, workspacePathStillMatches() else {
            throw MorphError.invalidOutput("Morph could not create a private output file.")
        }
        return fileURL(named: primaryFileName)
    }

    convenience init(outputURL: URL) throws {
        let extensionSuffix = outputURL.pathExtension
        let fileName = extensionSuffix.isEmpty ? "output.partial" : "output.partial.\(extensionSuffix)"
        try self.init(parentDirectory: outputURL.deletingLastPathComponent(), primaryFileName: fileName)
    }

    convenience init(parentDirectory: URL) throws {
        try self.init(parentDirectory: parentDirectory, primaryFileName: nil)
    }

    convenience init(parentDirectory: URL, primaryFileName: String) throws {
        guard Self.isSafeFileName(primaryFileName) else {
            throw MorphError.invalidOutput("Morph could not create a private output file.")
        }
        try self.init(parentDirectory: parentDirectory, primaryFileName: Optional(primaryFileName))
    }

    private init(parentDirectory: URL, primaryFileName: String?) throws {
        guard parentDirectory.isFileURL else {
            throw MorphError.invalidOutput("The output folder must be on this Mac.")
        }
        let parentFD = parentDirectory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard parentFD >= 0 else {
            throw MorphError.invalidOutput("Morph could not safely open the selected output folder.")
        }
        do {
            try OutputDirectorySecurity.validate(parentFD)
        } catch {
            close(parentFD)
            throw error
        }
        StaleMorphStageCleanup.remove(in: parentDirectory)

        let name = ".morph-\(UUID().uuidString).staging"
        let created = name.withCString { mkdirat(parentFD, $0, mode_t(0o700)) }
        guard created == 0 else {
            close(parentFD)
            throw MorphError.invalidOutput("Morph could not create a private staging folder.")
        }
        let stageFD = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard stageFD >= 0 else {
            _ = name.withCString { unlinkat(parentFD, $0, AT_REMOVEDIR) }
            close(parentFD)
            throw MorphError.invalidOutput("Morph could not safely open its staging folder.")
        }
        let prepareStatus = morph_prepare_private_directory(stageFD)
        guard prepareStatus == 0 else {
            let reason = String(cString: strerror(errno))
            close(stageFD)
            _ = name.withCString { unlinkat(parentFD, $0, AT_REMOVEDIR) }
            close(parentFD)
            throw MorphError.invalidOutput("Morph could not remove inherited access from its staging folder: \(reason).")
        }
        do {
            try StaleMorphStageCleanup.createOwnershipMarker(
                in: parentFD,
                directoryDescriptor: stageFD,
                directoryName: name
            )
        } catch {
            try? ArchiveExtractor.removeContents(of: stageFD)
            close(stageFD)
            _ = name.withCString { unlinkat(parentFD, $0, AT_REMOVEDIR) }
            close(parentFD)
            throw error
        }

        self.parentURL = parentDirectory
        self.directoryURL = parentDirectory.appendingPathComponent(name, isDirectory: true)
        self.parentDescriptor = parentFD
        self.directoryDescriptor = stageFD
        self.directoryName = name
        self.primaryFileName = primaryFileName
    }

    func fileURL(named name: String) -> URL {
        directoryURL.appendingPathComponent(name, isDirectory: false)
    }

    func workspacePathStillMatches() -> Bool {
        PinnedDirectoryPath.matches(directoryURL, descriptor: directoryDescriptor)
            && PinnedDirectoryPath.entry(named: directoryName, in: parentDescriptor, matches: directoryDescriptor)
    }

    func outputDirectoryStillMatches(for outputURL: URL) -> Bool {
        outputURL.deletingLastPathComponent().standardizedFileURL.path
            == parentURL.standardizedFileURL.path
            && PinnedDirectoryPath.matches(parentURL, descriptor: parentDescriptor)
    }

    func stagedFileStillMatchesPath(named name: String, url: URL) -> Bool {
        guard Self.isSafeFileName(name), workspacePathStillMatches() else { return false }
        let stagedDescriptor = name.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard stagedDescriptor >= 0 else { return false }
        defer { close(stagedDescriptor) }
        let pathDescriptor = url.path.withCString {
            open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard pathDescriptor >= 0 else { return false }
        defer { close(pathDescriptor) }
        var stagedInfo = stat()
        var pathInfo = stat()
        return fstat(stagedDescriptor, &stagedInfo) == 0
            && fstat(pathDescriptor, &pathInfo) == 0
            && stagedInfo.st_mode & S_IFMT == S_IFREG
            && pathInfo.st_mode & S_IFMT == S_IFREG
            && stagedInfo.st_uid == geteuid()
            && pathInfo.st_uid == geteuid()
            && stagedInfo.st_nlink == 1
            && pathInfo.st_nlink == 1
            && stagedInfo.st_dev == pathInfo.st_dev
            && stagedInfo.st_ino == pathInfo.st_ino
    }

    func copyValidatedFile(
        named sourceName: String,
        from sourceStage: PrivateOutputStage,
        to destinationName: String,
        for outputURL: URL,
        cancellation: CancellationToken
    ) throws {
        guard Self.isSafeFileName(sourceName), Self.isSafeFileName(destinationName),
              sourceStage.workspacePathStillMatches(),
              sourceStage.stagedFileStillMatchesPath(named: sourceName, url: sourceStage.fileURL(named: sourceName)),
              outputDirectoryStillMatches(for: outputURL) else {
            throw MorphError.invalidOutput("Morph could not verify the private conversion workspace or selected output folder.")
        }

        let sourceFD = sourceName.withCString {
            openat(sourceStage.directoryDescriptor, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sourceFD >= 0 else {
            throw MorphError.invalidOutput("Morph could not safely open the validated conversion output.")
        }
        defer { close(sourceFD) }
        var sourceBefore = stat()
        guard fstat(sourceFD, &sourceBefore) == 0,
              sourceBefore.st_mode & S_IFMT == S_IFREG,
              sourceBefore.st_uid == geteuid(),
              sourceBefore.st_nlink == 1,
              sourceBefore.st_size >= 0 else {
            throw MorphError.invalidOutput("The conversion output is not a regular file.")
        }

        let destinationFD = destinationName.withCString {
            openat(directoryDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard destinationFD >= 0 else {
            throw MorphError.invalidOutput("Morph could not create a protected output copy.")
        }
        var completed = false
        defer {
            close(destinationFD)
            if !completed { _ = destinationName.withCString { unlinkat(directoryDescriptor, $0, 0) } }
        }

        var copiedBytes: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if cancellation.isCancelled { throw MorphError.cancelled }
            let count = buffer.withUnsafeMutableBytes { bytes in read(sourceFD, bytes.baseAddress, bytes.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw MorphError.invalidOutput("Morph could not read the validated conversion output.")
            }
            var offset = 0
            while offset < count {
                if cancellation.isCancelled { throw MorphError.cancelled }
                let written = buffer.withUnsafeBytes { bytes in
                    write(destinationFD, bytes.baseAddress!.advanced(by: offset), count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw MorphError.invalidOutput("Morph could not copy the validated conversion output safely.") }
                offset += written
            }
            copiedBytes += off_t(count)
        }

        var sourceAfter = stat()
        var destinationInfo = stat()
        guard fstat(sourceFD, &sourceAfter) == 0,
              fstat(destinationFD, &destinationInfo) == 0,
              Self.sameFileRevision(sourceBefore, sourceAfter),
              sourceAfter.st_uid == geteuid(),
              sourceAfter.st_nlink == 1,
              copiedBytes == sourceBefore.st_size,
              destinationInfo.st_mode & S_IFMT == S_IFREG,
              destinationInfo.st_uid == geteuid(),
              destinationInfo.st_nlink == 1,
              destinationInfo.st_size == copiedBytes,
              fsync(destinationFD) == 0,
              sourceStage.stagedFileStillMatchesPath(named: sourceName, url: sourceStage.fileURL(named: sourceName)),
              outputDirectoryStillMatches(for: outputURL) else {
            throw MorphError.invalidOutput("The conversion output or selected folder changed before Morph could publish it.")
        }
        completed = true
    }

    @discardableResult
    func removePublishedFileIfUnchanged(_ published: PublishedFileIdentity) -> Bool {
        let fileName = published.outputURL.lastPathComponent
        guard Self.isSafeFileName(fileName) else { return false }
        var parentInfo = stat()
        guard fstat(parentDescriptor, &parentInfo) == 0,
              UInt64(parentInfo.st_dev) == published.parentDevice,
              UInt64(parentInfo.st_ino) == published.parentInode else { return false }
        var fileInfo = stat()
        let status = fileName.withCString { fstatat(parentDescriptor, $0, &fileInfo, AT_SYMLINK_NOFOLLOW) }
        if status != 0 { return errno == ENOENT }
        guard fileInfo.st_mode & S_IFMT == S_IFREG,
              UInt64(fileInfo.st_dev) == published.fileDevice,
              UInt64(fileInfo.st_ino) == published.fileInode else { return false }
        return fileName.withCString { unlinkat(parentDescriptor, $0, 0) } == 0
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    private static func sameFileRevision(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev
            && first.st_ino == second.st_ino
            && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    func publish(fileName: String, to outputURL: URL) throws {
        lastPublishedIdentity = nil
        guard outputURL.deletingLastPathComponent().standardizedFileURL.path
                == directoryURL.deletingLastPathComponent().standardizedFileURL.path,
              Self.isSafeFileName(fileName) else {
            throw MorphError.invalidOutput("Morph could not safely publish the generated file.")
        }
        guard pathStillIdentifiesPinnedParent(for: outputURL) else {
            throw MorphError.invalidOutput("The selected output folder moved during conversion. Choose it again and retry.")
        }
        guard workspacePathStillMatches() else {
            throw MorphError.invalidOutput("Morph's private staging folder changed before publication.")
        }
        var sourceInfo = stat()
        let sourceStatus = fileName.withCString { fstatat(directoryDescriptor, $0, &sourceInfo, AT_SYMLINK_NOFOLLOW) }
        guard sourceStatus == 0, sourceInfo.st_mode & S_IFMT == S_IFREG else {
            throw MorphError.invalidOutput("The conversion engine did not create a regular output file.")
        }
        guard pathStillIdentifiesPinnedParent(for: outputURL) else {
            throw MorphError.invalidOutput("The selected output folder moved during conversion. Choose it again and retry.")
        }
        let sourceName = fileName
        let destinationName = outputURL.lastPathComponent
        let result = sourceName.withCString { source in
            destinationName.withCString { destination in
                renameatx_np(directoryDescriptor, source, parentDescriptor, destination, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST || errno == ENOTEMPTY {
                throw OutputPublicationCollision()
            }
            throw MorphError.processFailed("Morph could not safely save the output: \(String(cString: strerror(errno))).")
        }
        guard pathStillIdentifiesPublishedFile(outputURL, expected: sourceInfo) else {
            var publishedInfo = stat()
            if destinationName.withCString({ fstatat(parentDescriptor, $0, &publishedInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
               publishedInfo.st_dev == sourceInfo.st_dev,
               publishedInfo.st_ino == sourceInfo.st_ino,
               publishedInfo.st_mode & S_IFMT == S_IFREG {
                _ = destinationName.withCString { unlinkat(parentDescriptor, $0, 0) }
            }
            throw MorphError.invalidOutput("The selected output folder moved during conversion. Choose it again and retry.")
        }
        var parentInfo = stat()
        guard fstat(parentDescriptor, &parentInfo) == 0 else {
            throw MorphError.invalidOutput("Morph could not verify the published output folder.")
        }
        lastPublishedIdentity = PublishedFileIdentity(
            outputURL: outputURL,
            parentDevice: UInt64(parentInfo.st_dev),
            parentInode: UInt64(parentInfo.st_ino),
            fileDevice: UInt64(sourceInfo.st_dev),
            fileInode: UInt64(sourceInfo.st_ino)
        )
    }

    @discardableResult
    func publishUnique(fileName: String, to outputURL: URL, maximumAttempts: Int = 1_000) throws -> URL {
        guard maximumAttempts > 0 else {
            throw MorphError.invalidOutput("Morph could not allocate a collision-safe output name.")
        }
        let initialName = outputURL.lastPathComponent
        let compoundExtension = ["tar.gz", "tar.bz2", "tar.xz"].first {
            initialName.lowercased().hasSuffix(".\($0)")
        }
        let extensionName = compoundExtension ?? outputURL.pathExtension
        let stem = extensionName.isEmpty
            ? initialName
            : String(initialName.dropLast(extensionName.count + 1))
        for suffix in 0..<maximumAttempts {
            let candidateName = suffix == 0 ? initialName : extensionName.isEmpty
                ? "\(stem)-\(suffix + 1)"
                : "\(stem)-\(suffix + 1).\(extensionName)"
            let candidateURL = outputURL.deletingLastPathComponent().appendingPathComponent(candidateName)
            do {
                try publish(fileName: fileName, to: candidateURL)
                return candidateURL
            } catch is OutputPublicationCollision {
                continue
            }
        }
        throw MorphError.invalidOutput("Morph could not allocate a collision-safe output name after 1,000 attempts.")
    }

    private func pathStillIdentifiesPinnedParent(for outputURL: URL) -> Bool {
        // Follow a stable selected-folder symlink, then compare its target's
        // identity with the directory pinned at staging time.
        PinnedDirectoryPath.matches(outputURL.deletingLastPathComponent(), descriptor: parentDescriptor)
    }

    private func pathStillIdentifiesPublishedFile(_ outputURL: URL, expected: stat) -> Bool {
        guard pathStillIdentifiesPinnedParent(for: outputURL) else { return false }
        let descriptor = outputURL.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var currentInfo = stat()
        return fstat(descriptor, &currentInfo) == 0
            && currentInfo.st_mode & S_IFMT == S_IFREG
            && currentInfo.st_dev == expected.st_dev
            && currentInfo.st_ino == expected.st_ino
    }

    func publishPrimary(to outputURL: URL) throws {
        guard let primaryFileName else {
            throw MorphError.invalidOutput("Morph could not safely publish the generated file.")
        }
        try publish(fileName: primaryFileName, to: outputURL)
    }

    deinit {
        try? ArchiveExtractor.removeContents(of: directoryDescriptor)
        var openedInfo = stat()
        var currentInfo = stat()
        if fstat(directoryDescriptor, &openedInfo) == 0,
           directoryName.withCString({ fstatat(parentDescriptor, $0, &currentInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
           openedInfo.st_dev == currentInfo.st_dev,
           openedInfo.st_ino == currentInfo.st_ino {
            if directoryName.withCString({ unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 {
                _ = StaleMorphStageCleanup.removeOwnershipMarker(in: parentDescriptor, directoryName: directoryName)
            }
        }
        close(directoryDescriptor)
        close(parentDescriptor)
    }
}

/// Keeps writers inside protected temporary storage and publishes only a
/// descriptor-validated copy into the user-selected destination directory.
final class PrivateOutputTransaction {
    let sourceStage: PrivateOutputStage
    let destinationStage: PrivateOutputStage
    let temporaryOutputURL: URL
    private let temporaryFileName: String
    private let outputURL: URL

    init(outputURL: URL, temporaryFileName: String? = nil) throws {
        let name = temporaryFileName ?? (outputURL.pathExtension.isEmpty
            ? "output.partial"
            : "output.partial.\(outputURL.pathExtension)")
        self.outputURL = outputURL
        self.temporaryFileName = name
        destinationStage = try PrivateOutputStage(outputURL: outputURL)
        sourceStage = try PrivateOutputStage(
            parentDirectory: FileManager.default.temporaryDirectory,
            primaryFileName: name
        )
        temporaryOutputURL = try sourceStage.temporaryOutputURL()
    }

    func publish(cancellation: CancellationToken? = nil) throws {
        guard sourceStage.stagedFileStillMatchesPath(named: temporaryFileName, url: temporaryOutputURL) else {
            throw MorphError.invalidOutput("Morph could not verify the private output before saving it.")
        }
        try destinationStage.copyValidatedFile(
            named: temporaryFileName,
            from: sourceStage,
            to: outputURL.lastPathComponent,
            for: outputURL,
            cancellation: cancellation ?? CancellationToken()
        )
        try destinationStage.publish(fileName: outputURL.lastPathComponent, to: outputURL)
    }

    @discardableResult
    func publishUnique(cancellation: CancellationToken? = nil) throws -> URL {
        guard sourceStage.stagedFileStillMatchesPath(named: temporaryFileName, url: temporaryOutputURL) else {
            throw MorphError.invalidOutput("Morph could not verify the private output before saving it.")
        }
        try destinationStage.copyValidatedFile(
            named: temporaryFileName,
            from: sourceStage,
            to: outputURL.lastPathComponent,
            for: outputURL,
            cancellation: cancellation ?? CancellationToken()
        )
        return try destinationStage.publishUnique(fileName: outputURL.lastPathComponent, to: outputURL)
    }
}
