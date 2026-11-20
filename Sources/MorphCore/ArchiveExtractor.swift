import CArchive
import Darwin
import Foundation

enum ArchivePathCollision {
    static func isCaseSensitive(volumeDescriptor: Int32) -> Bool {
        fpathconf(volumeDescriptor, _PC_CASE_SENSITIVE) == 1
    }

    static func key(_ path: String, caseSensitiveFileSystem: Bool) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        return caseSensitiveFileSystem
            ? normalized
            : normalized.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

enum ArchiveExtractor {
    static let maximumMembers = 10_000
    static let maximumMemberBytes: UInt64 = 512 * 1024 * 1024
    static let maximumExpandedBytes: UInt64 = 2 * 1024 * 1024 * 1024
    private static let maximumInputBytes: UInt64 = 2 * 1024 * 1024 * 1024
    private static let ioBufferSize = 64 * 1024

    private struct ModificationTime {
        let seconds: time_t
        let nanoseconds: Int
    }

    private struct DirectoryMetadata {
        let modificationTime: ModificationTime?
    }

    static func extract(input: URL, to directory: URL, cancellation: CancellationToken, preservePermissions: Bool = false) throws {
        let rootDescriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootDescriptor >= 0 else {
            throw MorphError.invalidOutput("Archive extraction requires a real staging folder.")
        }
        defer { close(rootDescriptor) }
        try extract(input: input, toDirectoryDescriptor: rootDescriptor, cancellation: cancellation, preservePermissions: preservePermissions)
    }

    static func extract(input: URL, toDirectoryDescriptor rootDescriptor: Int32, cancellation: CancellationToken, preservePermissions: Bool = false) throws {
        guard cancellation.isCancelled == false else { throw MorphError.cancelled }
        guard morph_prepare_private_directory(rootDescriptor) == 0 else {
            throw MorphError.invalidOutput("Morph could not remove inherited access from the archive extraction folder.")
        }
        let snapshot = try makePrivateSnapshot(of: input, cancellation: cancellation)
        defer { removePrivateSnapshot(at: snapshot.directory) }
        if snapshot.fileExtension == "zip" {
            try ArchiveEngine.validateZIP(
                snapshot.url,
                cancellation: cancellation,
                caseSensitiveFileSystem: ArchivePathCollision.isCaseSensitive(volumeDescriptor: rootDescriptor)
            )
        }
        try extractSnapshot(
            snapshot.url,
            rootDescriptor: rootDescriptor,
            fileExtension: snapshot.fileExtension,
            cancellation: cancellation,
            caseSensitiveFileSystem: ArchivePathCollision.isCaseSensitive(volumeDescriptor: rootDescriptor),
            preservePermissions: preservePermissions
        )
    }

    static func repackage(input: URL, output: URL, cancellation: CancellationToken) throws {
        let inputExtension = archiveExtensionForInput(input)
        let outputExtension = archiveExtensionForOutput(output)
        guard ArchiveEngine.builtInInputExtensions.contains(inputExtension),
              ArchiveEngine.builtInOutputExtensions.contains(outputExtension) else {
            throw MorphError.unsupportedConversion(inputExtension, outputExtension)
        }

        let snapshot = try makePrivateSnapshot(of: input, cancellation: cancellation)
        defer { removePrivateSnapshot(at: snapshot.directory) }
        if snapshot.fileExtension == "zip" {
            // Archive files preserve case-sensitive member names regardless of
            // the volume holding the single output file. Do not reject valid
            // case-distinct members just because temporary storage is APFS
            // case-insensitive.
            try ArchiveEngine.validateZIP(snapshot.url, cancellation: cancellation, caseSensitiveFileSystem: true)
        }

        guard let reader = archive_read_new(), let writer = archive_write_new() else {
            throw MorphError.processFailed("Morph could not initialize its macOS archive tools.")
        }
        var outputDescriptor: Int32 = -1
        var outputComplete = false
        var writerOpened = false
        var writerClosed = false
        defer {
            if writerOpened && !writerClosed { _ = archive_write_close(writer) }
            _ = archive_read_free(reader)
            _ = archive_write_free(writer)
            if outputDescriptor >= 0 { close(outputDescriptor) }
            if !outputComplete, outputDescriptor >= 0 { _ = output.path.withCString { unlink($0) } }
        }
        try configureReader(reader, fileExtension: snapshot.fileExtension)
        try configureWriter(writer, fileExtension: outputExtension)

        outputDescriptor = output.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard outputDescriptor >= 0 else {
            throw MorphError.invalidOutput("Morph could not safely create the converted archive.")
        }
        guard morph_archive_write_open_descriptor(writer, outputDescriptor) == 0 else {
            throw archiveError(writer, fallback: "Morph could not open the converted archive for writing.")
        }
        writerOpened = true

        let readStatus = snapshot.url.path.withCString { archive_read_open_filename(reader, $0, ioBufferSize) }
        guard readStatus == 0 else { throw archiveError(reader, fallback: "The archive could not be opened safely.") }

        var pathKinds: [String: Bool] = [:]
        var explicitDirectories = Set<String>()
        var filesystemObjects = Set<String>()
        var memberCount = 0
        var expandedBytes: UInt64 = 0
        var validatedFilter = false
        var entryPointer: OpaquePointer?
        var buffer = [UInt8](repeating: 0, count: ioBufferSize)

        while true {
            if cancellation.isCancelled { throw MorphError.cancelled }
            let status = archive_read_next_header(reader, &entryPointer)
            if status == 1 { break }
            guard status == 0, let entry = entryPointer else {
                throw archiveError(reader, fallback: "The archive contains an invalid or unsupported entry.")
            }
            if !validatedFilter {
                let actualFilter = archive_filter_name(reader, 0).flatMap(String.init(validatingUTF8:))
                guard actualFilter == expectedFilterName(for: snapshot.fileExtension) else {
                    throw MorphError.invalidInput("The archive compression does not match its .\(snapshot.fileExtension) extension.")
                }
                validatedFilter = true
            }
            memberCount += 1
            guard memberCount <= maximumMembers,
                  archive_entry_hardlink_utf8(entry) == nil,
                  archive_entry_hardlink(entry) == nil,
                  archive_entry_symlink_utf8(entry) == nil,
                  archive_entry_symlink(entry) == nil,
                  let rawPath = entryPath(entry),
                  let safePath = normalizedRelativePath(rawPath) else {
                throw MorphError.invalidInput("Archive links and unsafe member paths cannot be converted.")
            }
            let fileType = archive_entry_filetype(entry)
            let isDirectory = fileType == mode_t(S_IFDIR)
            guard isDirectory || fileType == mode_t(S_IFREG) else {
                throw MorphError.invalidInput("Archives may contain only regular files and directories.")
            }
            let declaredSize: UInt64?
            if archive_entry_size_is_set(entry) != 0 {
                let size = archive_entry_size(entry)
                guard size >= 0 else { throw MorphError.invalidInput("An archive entry has an invalid size.") }
                declaredSize = UInt64(size)
            } else {
                declaredSize = nil
            }
            if isDirectory {
                guard declaredSize == nil || declaredSize == 0 else {
                    throw MorphError.invalidInput("An archive directory unexpectedly contains file data.")
                }
            } else if let declaredSize {
                guard declaredSize <= maximumMemberBytes,
                      expandedBytes <= maximumExpandedBytes - declaredSize else {
                    throw MorphError.invalidInput("The archive exceeds Morph's 512 MB per-file or 2 GB expanded-size limit.")
                }
            } else {
                throw MorphError.invalidInput("Archive conversion requires each file entry to declare its uncompressed size.")
            }

            let collisionPath = ArchivePathCollision.key(safePath, caseSensitiveFileSystem: true)
            let objectKeys = filesystemObjectKeys(for: safePath, caseSensitiveFileSystem: true)
            let newObjects = objectKeys.reduce(into: 0) { count, key in
                if !filesystemObjects.contains(key) { count += 1 }
            }
            guard newObjects <= maximumMembers - filesystemObjects.count else {
                throw MorphError.invalidInput("Archives may contain no more than 10,000 files and directories.")
            }
            try register(
                path: safePath,
                collisionPath: collisionPath,
                isDirectory: isDirectory,
                caseSensitiveFileSystem: true,
                kinds: &pathKinds,
                explicitDirectories: &explicitDirectories
            )
            filesystemObjects.formUnion(objectKeys)

            if safePath.isEmpty {
                guard isDirectory, declaredSize == nil || declaredSize == 0,
                      archive_read_data_skip(reader) >= 0 else {
                    throw MorphError.invalidInput("The archive contains an invalid root directory entry.")
                }
                continue
            }

            guard let convertedEntry = archive_entry_new() else {
                throw MorphError.processFailed("Morph could not prepare a safe archive entry.")
            }
            defer { archive_entry_free(convertedEntry) }
            safePath.withCString { archive_entry_set_pathname_utf8(convertedEntry, $0) }
            archive_entry_set_filetype(convertedEntry, fileType)
            archive_entry_set_perm(convertedEntry, isDirectory ? safeDirectoryPermissions() : safeFilePermissions(archive_entry_perm(entry)))
            archive_entry_set_size(convertedEntry, Int64(declaredSize ?? 0))
            if archive_entry_mtime_is_set(entry) != 0 {
                archive_entry_set_mtime(convertedEntry, archive_entry_mtime(entry), archive_entry_mtime_nsec(entry))
            }
            guard archive_write_header(writer, convertedEntry) == 0 else {
                throw archiveError(writer, fallback: "Morph could not write a validated archive entry.")
            }

            if isDirectory {
                guard archive_read_data_skip(reader) >= 0,
                      archive_write_finish_entry(writer) == 0 else {
                    throw archiveError(writer, fallback: "Morph could not finish an archive directory entry.")
                }
                continue
            }

            var memberBytes: UInt64 = 0
            while true {
                if cancellation.isCancelled { throw MorphError.cancelled }
                let count = buffer.withUnsafeMutableBytes { bytes in archive_read_data(reader, bytes.baseAddress, bytes.count) }
                if count == 0 { break }
                guard count > 0 else { throw archiveError(reader, fallback: "An archive entry could not be read safely.") }
                let amount = UInt64(count)
                guard memberBytes <= maximumMemberBytes - amount,
                      expandedBytes <= maximumExpandedBytes - amount,
                      declaredSize.map({ memberBytes <= $0 && amount <= $0 - memberBytes }) ?? true else {
                    throw MorphError.invalidInput("The archive expanded beyond Morph's conversion limits.")
                }
                let written = buffer.withUnsafeBytes { bytes in
                    archive_write_data(writer, bytes.baseAddress, count)
                }
                guard written == count else {
                    throw archiveError(writer, fallback: "Morph could not write a converted archive entry.")
                }
                memberBytes += amount
                expandedBytes += amount
            }
            guard declaredSize == memberBytes,
                  archive_write_finish_entry(writer) == 0 else {
                throw MorphError.invalidInput("An archive entry's expanded size did not match its directory record.")
            }
        }

        guard memberCount > 0 else { throw MorphError.invalidInput("The archive is empty.") }
        guard archive_write_close(writer) == 0 else {
            throw archiveError(writer, fallback: "Morph could not finish writing the converted archive.")
        }
        writerClosed = true
        guard fsync(outputDescriptor) == 0 else {
            throw MorphError.processFailed("Morph could not synchronize the converted archive to disk.")
        }
        var outputInfo = stat()
        guard fstat(outputDescriptor, &outputInfo) == 0,
              outputInfo.st_mode & S_IFMT == S_IFREG,
              outputInfo.st_size > 0 else {
            throw MorphError.invalidOutput("Morph could not verify the converted archive.")
        }
        outputComplete = true
    }

    private static func configureReader(_ reader: OpaquePointer, fileExtension: String) throws {
        let filterStatus: Int32
        let formatStatus: Int32
        switch fileExtension {
        case "zip":
            filterStatus = archive_read_support_filter_none(reader)
            formatStatus = archive_read_support_format_zip_seekable(reader)
        case "tar":
            filterStatus = archive_read_support_filter_none(reader)
            formatStatus = archive_read_support_format_tar(reader)
        case "tar.gz":
            let status = archive_read_support_filter_none(reader)
            filterStatus = status >= 0 ? archive_read_support_filter_gzip(reader) : status
            formatStatus = archive_read_support_format_tar(reader)
        case "tar.bz2":
            let status = archive_read_support_filter_none(reader)
            filterStatus = status >= 0 ? archive_read_support_filter_bzip2(reader) : status
            formatStatus = archive_read_support_format_tar(reader)
        case "tar.xz":
            let status = archive_read_support_filter_none(reader)
            filterStatus = status >= 0 ? archive_read_support_filter_xz(reader) : status
            formatStatus = archive_read_support_format_tar(reader)
        case "7z":
            filterStatus = archive_read_support_filter_none(reader)
            formatStatus = archive_read_support_format_7zip(reader)
        default:
            throw MorphError.unsupportedConversion(fileExtension, "archive contents")
        }
        guard filterStatus >= 0, formatStatus >= 0 else {
            throw MorphError.processFailed("Morph could not enable the expected macOS archive reader.")
        }
    }

    private static func configureWriter(_ writer: OpaquePointer, fileExtension: String) throws {
        let formatStatus: Int32
        switch fileExtension {
        case "zip": formatStatus = archive_write_set_format_zip(writer)
        case "tar", "tar.gz", "tar.bz2", "tar.xz": formatStatus = archive_write_set_format_pax_restricted(writer)
        default: throw MorphError.unsupportedConversion("archive contents", fileExtension)
        }
        guard formatStatus == 0 else { throw archiveError(writer, fallback: "Morph could not select a safe archive format.") }
        let filterStatus: Int32
        switch fileExtension {
        case "tar.gz": filterStatus = archive_write_add_filter_gzip(writer)
        case "tar.bz2": filterStatus = archive_write_add_filter_bzip2(writer)
        case "tar.xz": filterStatus = archive_write_add_filter_xz(writer)
        default: filterStatus = archive_write_add_filter_none(writer)
        }
        guard filterStatus == 0 else { throw archiveError(writer, fallback: "Morph could not enable the requested archive compression.") }
    }

    private static func archiveExtensionForInput(_ input: URL) -> String {
        ArchiveEngine.archiveExtension(for: input)
    }

    private static func archiveExtensionForOutput(_ output: URL) -> String {
        ArchiveEngine.archiveExtension(for: output)
    }

    private static func makePrivateSnapshot(of input: URL, cancellation: CancellationToken) throws -> (url: URL, directory: URL, fileExtension: String) {
        // O_NONBLOCK lets fstat reject a FIFO without waiting for a writer.
        // It has no effect on regular-file reads and follows selected file aliases.
        let source = input.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
        guard source >= 0 else { throw MorphError.invalidInput("The archive could not be opened for a safe snapshot.") }
        defer { close(source) }

        var sourceInfo = stat()
        guard fstat(source, &sourceInfo) == 0,
              sourceInfo.st_mode & S_IFMT == S_IFREG,
              sourceInfo.st_size >= 0,
              UInt64(sourceInfo.st_size) <= maximumInputBytes else {
            throw MorphError.invalidInput("Archives must be regular files no larger than 2 GB.")
        }

        let fileExtension = ArchiveEngine.archiveExtension(for: input)
        let temporaryRoot = FileManager.default.temporaryDirectory
        StaleMorphStageCleanup.remove(in: temporaryRoot)
        let temporaryRootDescriptor = temporaryRoot.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard temporaryRootDescriptor >= 0 else {
            throw MorphError.processFailed("Morph could not safely open its private archive staging folder.")
        }
        defer { close(temporaryRootDescriptor) }
        let snapshotDirectory = temporaryRoot.appendingPathComponent("Morph-archive-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: snapshotDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw MorphError.processFailed("Morph could not create a private archive snapshot folder.")
        }
        let snapshotDescriptor = snapshotDirectory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard snapshotDescriptor >= 0 else {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            throw MorphError.processFailed("Morph could not safely open its private archive snapshot folder.")
        }
        defer { close(snapshotDescriptor) }
        guard morph_prepare_private_directory(snapshotDescriptor) == 0 else {
            removePrivateSnapshot(at: snapshotDirectory)
            throw MorphError.processFailed("Morph could not remove inherited access from its archive snapshot folder.")
        }
        do {
            try StaleMorphStageCleanup.createOwnershipMarker(
                in: temporaryRootDescriptor,
                directoryDescriptor: snapshotDescriptor,
                directoryName: snapshotDirectory.lastPathComponent
            )
        } catch {
            removePrivateSnapshot(at: snapshotDirectory)
            throw error
        }
        let snapshotName = "input.\(fileExtension)"
        let snapshotURL = snapshotDirectory.appendingPathComponent(snapshotName)
        let destination = snapshotName.withCString {
            openat(snapshotDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard destination >= 0 else {
            removePrivateSnapshot(at: snapshotDirectory)
            throw MorphError.processFailed("Morph could not create a private archive snapshot.")
        }
        defer { close(destination) }

        var copiedBytes: UInt64 = 0
        do {
            var buffer = [UInt8](repeating: 0, count: ioBufferSize)
            while true {
                if cancellation.isCancelled { throw MorphError.cancelled }
                let count = buffer.withUnsafeMutableBytes { bytes in read(source, bytes.baseAddress, bytes.count) }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw MorphError.invalidInput("Morph could not read a stable archive snapshot.")
                }
                let amount = UInt64(count)
                guard copiedBytes <= maximumInputBytes - amount else {
                    throw MorphError.invalidInput("Archives must be no larger than 2 GB.")
                }
                copiedBytes += amount
                try writeAll(destination, bytes: buffer, count: count)
            }
            guard fsync(destination) == 0 else { throw MorphError.processFailed("Morph could not finish its private archive snapshot.") }
            if cancellation.isCancelled { throw MorphError.cancelled }
        } catch {
            removePrivateSnapshot(at: snapshotDirectory)
            throw error
        }

        var finalSourceInfo = stat()
        var snapshotInfo = stat()
        guard fstat(source, &finalSourceInfo) == 0,
              fstat(destination, &snapshotInfo) == 0,
              UInt64(sourceInfo.st_size) == copiedBytes,
              sourceRevisionIsUnchanged(sourceInfo, finalSourceInfo),
              snapshotInfo.st_mode & S_IFMT == S_IFREG,
              snapshotInfo.st_uid == geteuid(),
              snapshotInfo.st_nlink == 1,
              snapshotInfo.st_size == sourceInfo.st_size,
              fchmod(destination, mode_t(0o600)) == 0,
              fsync(destination) == 0 else {
            removePrivateSnapshot(at: snapshotDirectory)
            throw MorphError.invalidInput("The selected archive changed while Morph was making a safe snapshot.")
        }
        return (snapshotURL, snapshotDirectory, fileExtension)
    }

    static func sourceRevisionIsUnchanged(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static func removePrivateSnapshot(at directory: URL) {
        let parent = directory.deletingLastPathComponent()
        let parentDescriptor = parent.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard parentDescriptor >= 0 else { return }
        defer { close(parentDescriptor) }
        let name = directory.lastPathComponent
        let stageDescriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard stageDescriptor >= 0 else { return }
        defer { close(stageDescriptor) }
        try? removeContents(of: stageDescriptor)
        var opened = stat()
        var current = stat()
        guard fstat(stageDescriptor, &opened) == 0,
              name.withCString({ fstatat(parentDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
              current.st_mode & S_IFMT == S_IFDIR,
              opened.st_dev == current.st_dev,
              opened.st_ino == current.st_ino,
              name.withCString({ unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 else { return }
        _ = StaleMorphStageCleanup.removeOwnershipMarker(in: parentDescriptor, directoryName: name)
    }

    private static func extractSnapshot(
        _ input: URL,
        rootDescriptor: Int32,
        fileExtension: String,
        cancellation: CancellationToken,
        caseSensitiveFileSystem: Bool,
        preservePermissions: Bool
    ) throws {
        guard let reader = archive_read_new() else {
            throw MorphError.processFailed("Morph could not initialize its macOS archive reader.")
        }
        defer { _ = archive_read_free(reader) }
        let filterStatus: Int32
        let formatStatus: Int32
        switch fileExtension {
        case "zip":
            filterStatus = archive_read_support_filter_none(reader)
            formatStatus = archive_read_support_format_zip_seekable(reader)
        case "tar":
            filterStatus = archive_read_support_filter_none(reader)
            formatStatus = archive_read_support_format_tar(reader)
        case "tar.gz":
            let noneStatus = archive_read_support_filter_none(reader)
            filterStatus = noneStatus >= 0 ? archive_read_support_filter_gzip(reader) : noneStatus
            formatStatus = archive_read_support_format_tar(reader)
        case "tar.bz2":
            let noneStatus = archive_read_support_filter_none(reader)
            filterStatus = noneStatus >= 0 ? archive_read_support_filter_bzip2(reader) : noneStatus
            formatStatus = archive_read_support_format_tar(reader)
        case "tar.xz":
            let noneStatus = archive_read_support_filter_none(reader)
            filterStatus = noneStatus >= 0 ? archive_read_support_filter_xz(reader) : noneStatus
            formatStatus = archive_read_support_format_tar(reader)
        case "7z":
            filterStatus = archive_read_support_filter_none(reader)
            formatStatus = archive_read_support_format_7zip(reader)
        default:
            throw MorphError.unsupportedConversion(fileExtension, "archive contents")
        }
        guard filterStatus >= 0, formatStatus >= 0 else {
            throw MorphError.processFailed("Morph could not enable the expected macOS archive reader.")
        }
        let openStatus = input.path.withCString { archive_read_open_filename(reader, $0, ioBufferSize) }
        guard openStatus == 0 else { throw archiveError(reader, fallback: "The archive could not be opened safely.") }

        var pathKinds: [String: Bool] = [:]
        var explicitDirectories = Set<String>()
        var filesystemObjects = Set<String>()
        var directoryMetadata: [String: DirectoryMetadata] = [:]
        var memberCount = 0
        var expandedBytes: UInt64 = 0
        var validatedFilter = false
        var entryPointer: OpaquePointer?
        var buffer = [UInt8](repeating: 0, count: ioBufferSize)

        while true {
            if cancellation.isCancelled { throw MorphError.cancelled }
            let status = archive_read_next_header(reader, &entryPointer)
            if status == 1 { break }
            guard status == 0, let entry = entryPointer else {
                throw archiveError(reader, fallback: "The archive contains an invalid or unsupported entry.")
            }
            if !validatedFilter {
                let expectedFilter = expectedFilterName(for: fileExtension)
                let actualFilter = archive_filter_name(reader, 0).flatMap(String.init(validatingUTF8:))
                guard actualFilter == expectedFilter else {
                    throw MorphError.invalidInput("The archive compression does not match its .\(fileExtension) extension.")
                }
                validatedFilter = true
            }
            memberCount += 1
            guard memberCount <= maximumMembers else {
                throw MorphError.invalidInput("Archives may contain no more than 10,000 entries.")
            }

            guard archive_entry_hardlink_utf8(entry) == nil,
                  archive_entry_hardlink(entry) == nil,
                  archive_entry_symlink_utf8(entry) == nil,
                  archive_entry_symlink(entry) == nil,
                  let path = entryPath(entry),
                  let safePath = normalizedRelativePath(path) else {
                throw MorphError.invalidInput("Archive links and unsafe member paths cannot be extracted.")
            }
            let type = archive_entry_filetype(entry)
            let isDirectory = type == mode_t(S_IFDIR)
            guard isDirectory || type == mode_t(S_IFREG) else {
                throw MorphError.invalidInput("Archives may contain only regular files and directories.")
            }
            let declaredSize: UInt64?
            if archive_entry_size_is_set(entry) != 0 {
                let size = archive_entry_size(entry)
                guard size >= 0 else { throw MorphError.invalidInput("An archive entry has an invalid size.") }
                declaredSize = UInt64(size)
            } else {
                declaredSize = nil
            }
            if isDirectory {
                guard declaredSize == nil || declaredSize == 0 else {
                    throw MorphError.invalidInput("An archive directory unexpectedly contains file data.")
                }
            } else if let declaredSize {
                guard declaredSize <= maximumMemberBytes,
                      expandedBytes <= maximumExpandedBytes - declaredSize else {
                    throw MorphError.invalidInput("The archive exceeds Morph's 512 MB per-file or 2 GB expanded-size limit.")
                }
            }

            let collisionPath = ArchivePathCollision.key(safePath, caseSensitiveFileSystem: caseSensitiveFileSystem)
            let filesystemObjectKeys = filesystemObjectKeys(for: safePath, caseSensitiveFileSystem: caseSensitiveFileSystem)
            let newObjectCount = filesystemObjectKeys.reduce(into: 0) { count, key in
                if !filesystemObjects.contains(key) { count += 1 }
            }
            guard newObjectCount <= maximumMembers - filesystemObjects.count else {
                throw MorphError.invalidInput("Archives may create no more than 10,000 files and directories.")
            }
            try register(
                path: safePath,
                collisionPath: collisionPath,
                isDirectory: isDirectory,
                caseSensitiveFileSystem: caseSensitiveFileSystem,
                kinds: &pathKinds,
                explicitDirectories: &explicitDirectories
            )
            filesystemObjects.formUnion(filesystemObjectKeys)
            if safePath.isEmpty {
                guard isDirectory, declaredSize == nil || declaredSize == 0,
                      archive_read_data_skip(reader) >= 0 else {
                    throw MorphError.invalidInput("The archive contains an invalid root directory entry.")
                }
                continue
            }
            let components = safePath.split(separator: "/").map(String.init)
            if isDirectory {
                let descriptor = try openOrCreateDirectory(rootDescriptor: rootDescriptor, components: components)
                if preservePermissions {
                    directoryMetadata[safePath] = DirectoryMetadata(modificationTime: modificationTime(of: entry))
                }
                close(descriptor)
            } else {
                let parentDescriptor = try openOrCreateDirectory(rootDescriptor: rootDescriptor, components: Array(components.dropLast()))
                defer { close(parentDescriptor) }
                let descriptor = components.last!.withCString {
                    openat(parentDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
                }
                guard descriptor >= 0 else { throw MorphError.invalidOutput("Morph could not safely create an extracted file.") }
                defer { close(descriptor) }

                var memberBytes: UInt64 = 0
                while true {
                    if cancellation.isCancelled { throw MorphError.cancelled }
                    let count = buffer.withUnsafeMutableBytes { bytes in archive_read_data(reader, bytes.baseAddress, bytes.count) }
                    if count == 0 { break }
                    guard count > 0 else { throw archiveError(reader, fallback: "An archive entry could not be decompressed safely.") }
                    let amount = UInt64(count)
                    guard memberBytes <= maximumMemberBytes - amount,
                          expandedBytes <= maximumExpandedBytes - amount,
                          declaredSize.map({ memberBytes <= $0 && amount <= $0 - memberBytes }) ?? true else {
                        throw MorphError.invalidInput("The archive expanded beyond Morph's extraction limits.")
                    }
                    try writeAll(descriptor, bytes: buffer, count: count)
                    memberBytes += amount
                    expandedBytes += amount
                }
                if let declaredSize, declaredSize != memberBytes {
                    throw MorphError.invalidInput("An archive entry's expanded size did not match its directory record.")
                }
                let safePermissions = safeFilePermissions(archive_entry_perm(entry))
                let modifiedAt = modificationTime(of: entry)
                guard fsync(descriptor) == 0,
                      !preservePermissions || fchmod(descriptor, safePermissions) == 0,
                      !preservePermissions || modifiedAt.map({ setModificationTime($0, on: descriptor) }) ?? true else {
                    throw MorphError.processFailed("Morph could not finish writing an extracted file.")
                }
            }
        }
        guard memberCount > 0 else { throw MorphError.invalidInput("The archive is empty.") }
        if preservePermissions {
            for path in directoryMetadata.keys.sorted(by: { $0.filter { $0 == "/" }.count > $1.filter { $0 == "/" }.count }) {
                let components = path.split(separator: "/").map(String.init)
                let descriptor = try openOrCreateDirectory(rootDescriptor: rootDescriptor, components: components)
                defer { close(descriptor) }
                guard fchmod(descriptor, safeDirectoryPermissions()) == 0,
                      directoryMetadata[path]?.modificationTime.map({ setModificationTime($0, on: descriptor) }) ?? true else {
                    throw MorphError.processFailed("Morph could not preserve safe archive directory permissions.")
                }
            }
        }
        if cancellation.isCancelled { throw MorphError.cancelled }
    }

    private static func expectedFilterName(for fileExtension: String) -> String {
        switch fileExtension {
        case "tar.gz": "gzip"
        case "tar.bz2": "bzip2"
        case "tar.xz": "xz"
        default: "none"
        }
    }

    private static func safeFilePermissions(_ archivePermissions: mode_t) -> mode_t {
        let permissions = archivePermissions & 0o777
        let ownerExecute: mode_t = permissions & 0o111 == 0 ? 0 : 0o100
        return 0o600 | ownerExecute
    }

    private static func safeDirectoryPermissions() -> mode_t {
        0o700
    }

    private static func modificationTime(of entry: OpaquePointer) -> ModificationTime? {
        guard archive_entry_mtime_is_set(entry) != 0 else { return nil }
        return ModificationTime(
            seconds: archive_entry_mtime(entry),
            nanoseconds: Int(archive_entry_mtime_nsec(entry))
        )
    }

    private static func setModificationTime(_ modificationTime: ModificationTime, on descriptor: Int32) -> Bool {
        var times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: modificationTime.seconds, tv_nsec: modificationTime.nanoseconds),
        ]
        return futimens(descriptor, &times) == 0
    }

    static func removeContents(of directoryDescriptor: Int32) throws {
        let duplicate = dup(directoryDescriptor)
        guard duplicate >= 0 else { throw MorphError.invalidOutput("Morph could not clean its private archive staging folder.") }
        guard fcntl(duplicate, F_SETFD, FD_CLOEXEC) == 0,
              let directory = fdopendir(duplicate) else {
            close(duplicate)
            throw MorphError.invalidOutput("Morph could not safely open its private archive staging folder.")
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            var info = stat()
            let statResult = name.withCString { fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
            if statResult != 0, errno == ENOENT { continue }
            guard statResult == 0 else { throw MorphError.invalidOutput("Morph could not inspect a staged archive item during cleanup.") }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = name.withCString { openat(directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
                guard child >= 0 else {
                    if errno == ENOTDIR || errno == ELOOP {
                        guard name.withCString({ unlinkat(directoryDescriptor, $0, 0) }) == 0 || errno == ENOENT else {
                            throw MorphError.invalidOutput("Morph could not remove an unsafe staged archive item.")
                        }
                        continue
                    }
                    throw MorphError.invalidOutput("Morph could not safely open a staged archive folder during cleanup.")
                }
                defer { close(child) }
                try removeContents(of: child)
                var openedInfo = stat()
                var currentInfo = stat()
                guard fstat(child, &openedInfo) == 0,
                      name.withCString({ fstatat(directoryDescriptor, $0, &currentInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
                      openedInfo.st_dev == currentInfo.st_dev,
                      openedInfo.st_ino == currentInfo.st_ino,
                      name.withCString({ unlinkat(directoryDescriptor, $0, AT_REMOVEDIR) }) == 0 || errno == ENOENT else {
                    throw MorphError.invalidOutput("Morph could not safely remove a staged archive folder.")
                }
            } else {
                guard name.withCString({ unlinkat(directoryDescriptor, $0, 0) }) == 0 || errno == ENOENT else {
                    throw MorphError.invalidOutput("Morph could not remove a staged archive item.")
                }
            }
        }
    }

    private static func openOrCreateDirectory(rootDescriptor: Int32, components: [String]) throws -> Int32 {
        let rootCopy = dup(rootDescriptor)
        guard rootCopy >= 0 else {
            throw MorphError.invalidOutput("Morph could not safely access the archive staging folder.")
        }
        guard fcntl(rootCopy, F_SETFD, FD_CLOEXEC) == 0 else {
            close(rootCopy)
            throw MorphError.invalidOutput("Morph could not safely secure access to the archive staging folder.")
        }
        var current = rootCopy
        for component in components {
            let next = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            if next >= 0 {
                close(current)
                current = next
                continue
            }

            let created = component.withCString { mkdirat(current, $0, mode_t(0o700)) }
            guard created == 0 || errno == EEXIST else {
                close(current)
                throw MorphError.invalidOutput("Morph could not safely create an extracted folder.")
            }
            let opened = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard opened >= 0 else {
                close(current)
                throw MorphError.invalidInput("An archive path conflicts with an unsafe or non-directory entry.")
            }
            close(current)
            current = opened
        }
        return current
    }

    private static func entryPath(_ entry: OpaquePointer) -> String? {
        let pointer = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)
        guard let pointer else { return nil }
        return String(validatingUTF8: pointer)
    }

    private static func normalizedRelativePath(_ rawPath: String) -> String? {
        guard !rawPath.isEmpty, rawPath.utf8.count <= 4_096,
              !rawPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/"), path.range(of: "^[A-Za-z]:", options: .regularExpression) == nil else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard components.count <= 128,
              components.allSatisfy({ $0 != ".." && !$0.isEmpty && $0.utf8.count <= 255 }) else { return nil }
        return components.joined(separator: "/")
    }

    private static func filesystemObjectKeys(for path: String, caseSensitiveFileSystem: Bool) -> [String] {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(components.count)
        var prefix = ""
        for component in components {
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            keys.append(ArchivePathCollision.key(prefix, caseSensitiveFileSystem: caseSensitiveFileSystem))
        }
        return keys
    }

    private static func register(
        path: String,
        collisionPath: String,
        isDirectory: Bool,
        caseSensitiveFileSystem: Bool,
        kinds: inout [String: Bool],
        explicitDirectories: inout Set<String>
    ) throws {
        let components = path.split(separator: "/").map(String.init)
        var parent = ""
        for component in components.dropLast() {
            parent = parent.isEmpty ? component : parent + "/" + component
            let key = ArchivePathCollision.key(parent, caseSensitiveFileSystem: caseSensitiveFileSystem)
            if let existing = kinds[key], existing == false {
                throw MorphError.invalidInput("An archive file is used as a parent directory.")
            }
            kinds[key] = true
        }
        if isDirectory, let existing = kinds[collisionPath], existing {
            guard explicitDirectories.insert(collisionPath).inserted else {
                throw MorphError.invalidInput("The archive contains duplicate directory paths.")
            }
            return
        }
        guard kinds[collisionPath] == nil else {
            throw MorphError.invalidInput("The archive contains duplicate or conflicting paths on a Mac filesystem.")
        }
        kinds[collisionPath] = isDirectory
        if isDirectory { explicitDirectories.insert(collisionPath) }
    }

    private static func writeAll(_ descriptor: Int32, bytes: [UInt8], count: Int) throws {
        var offset = 0
        while offset < count {
            let written = bytes.withUnsafeBytes { raw in
                write(descriptor, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw MorphError.processFailed("Morph could not safely write an archive snapshot or extracted file.") }
            offset += written
        }
    }

    private static func archiveError(_ reader: OpaquePointer, fallback: String) -> MorphError {
        guard let message = archive_error_string(reader),
              let detail = String(validatingUTF8: message),
              !detail.isEmpty else { return .invalidInput(fallback) }
        return .invalidInput("\(fallback) \(detail)")
    }
}
