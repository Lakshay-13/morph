import Darwin
import Foundation

/// Pins one user-selected input into Morph's private workspace before handing
/// it to a parser or conversion engine. APFS can clone same-volume files; other
/// volumes use a bounded, revision-checked stream copy.
final class PrivateInputSnapshot {
    static let maximumInputBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024
    let fileURL: URL
    private let stage: PrivateOutputStage

    init(
        input: URL,
        fileExtension: String,
        maximumBytes: UInt64 = maximumInputBytes,
        requireOwnedUnlinkedInput: Bool = false,
        cancellation: CancellationToken
    ) throws {
        let effectiveMaximumBytes = min(maximumBytes, Self.maximumInputBytes)
        guard input.isFileURL,
              !fileExtension.isEmpty,
              fileExtension.range(of: #"^[a-z0-9.]{1,32}$"#, options: .regularExpression) != nil,
              effectiveMaximumBytes > 0 else {
            throw MorphError.invalidInput("Morph could not safely identify the selected input file.")
        }
        let sourceDescriptor = input.path.withCString {
            open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sourceDescriptor >= 0 else {
            throw MorphError.invalidInput("The selected input is not a readable regular file.")
        }
        defer { close(sourceDescriptor) }

        var before = stat()
        guard fstat(sourceDescriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0,
              (!requireOwnedUnlinkedInput || (before.st_uid == geteuid() && before.st_nlink == 1)),
              UInt64(before.st_size) <= effectiveMaximumBytes else {
            let limitGB = max(1, effectiveMaximumBytes / (1_024 * 1_024 * 1_024))
            throw MorphError.invalidInput("The selected input must be a non-empty regular file no larger than \(limitGB) GB.")
        }
        guard cancellation.isCancelled == false else { throw MorphError.cancelled }

        let name = "input.\(fileExtension)"
        let stage = try PrivateOutputStage(
            parentDirectory: FileManager.default.temporaryDirectory,
            primaryFileName: name
        )
        let stageDescriptor = stage.directoryDescriptorForInputSnapshot
        let destinationDescriptor = name.withCString {
            openat(stageDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard destinationDescriptor >= 0 else {
            throw MorphError.processFailed("Morph could not create a private copy of the selected input.")
        }
        defer { close(destinationDescriptor) }

        let cloned = fcopyfile(sourceDescriptor, destinationDescriptor, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_CLONE)) == 0
        if !cloned {
            let cloneError = errno
            guard cloneError == EXDEV || cloneError == ENOTSUP || cloneError == EOPNOTSUPP || cloneError == EINVAL || cloneError == ENOSYS else {
                _ = name.withCString { unlinkat(stageDescriptor, $0, 0) }
                throw MorphError.processFailed("Morph could not create a private input snapshot.")
            }
            guard ftruncate(destinationDescriptor, 0) == 0,
                  lseek(sourceDescriptor, 0, SEEK_SET) >= 0,
                  lseek(destinationDescriptor, 0, SEEK_SET) >= 0 else {
                _ = name.withCString { unlinkat(stageDescriptor, $0, 0) }
                throw MorphError.processFailed("Morph could not prepare a private input copy.")
            }
            try Self.copyInput(sourceDescriptor, to: destinationDescriptor, expectedSize: before.st_size, cancellation: cancellation)
        }

        var after = stat()
        var copied = stat()
        guard fstat(sourceDescriptor, &after) == 0,
              fstat(destinationDescriptor, &copied) == 0,
              Self.sameRevision(before, after),
              copied.st_mode & S_IFMT == S_IFREG,
              copied.st_uid == geteuid(),
              copied.st_nlink == 1,
              copied.st_size == before.st_size,
              fchmod(destinationDescriptor, mode_t(0o600)) == 0,
              fsync(destinationDescriptor) == 0,
              stage.stagedFileStillMatchesPath(named: name, url: stage.fileURL(named: name)) else {
            _ = name.withCString { unlinkat(stageDescriptor, $0, 0) }
            throw MorphError.invalidInput("The selected input changed while Morph was making a safe snapshot.")
        }
        guard cancellation.isCancelled == false else {
            _ = name.withCString { unlinkat(stageDescriptor, $0, 0) }
            throw MorphError.cancelled
        }

        self.stage = stage
        self.fileURL = stage.fileURL(named: name)
    }

    private static func copyInput(
        _ source: Int32,
        to destination: Int32,
        expectedSize: off_t,
        cancellation: CancellationToken
    ) throws {
        let (availableBytes, overflow) = UInt64(expectedSize).addingReportingOverflow(64 * 1_024 * 1_024)
        let capacityValues = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard !overflow,
              let capacityValues,
              let available = capacityValues.volumeAvailableCapacityForImportantUsage,
              available >= 0,
              UInt64(available) >= availableBytes else {
            throw MorphError.invalidOutput("There is not enough free space to make a private copy of this file.")
        }

        var copied: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            if cancellation.isCancelled { throw MorphError.cancelled }
            let count = buffer.withUnsafeMutableBytes { bytes in read(source, bytes.baseAddress, bytes.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw MorphError.invalidInput("Morph could not read a stable snapshot of the selected file.")
            }
            guard Int64(copied) <= Int64(expectedSize) - Int64(count) else {
                throw MorphError.invalidInput("The selected file grew while Morph was creating a private copy.")
            }
            var offset = 0
            while offset < count {
                if cancellation.isCancelled { throw MorphError.cancelled }
                let written = buffer.withUnsafeBytes { bytes in
                    Darwin.write(destination, bytes.baseAddress!.advanced(by: offset), count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw MorphError.processFailed("Morph could not finish copying the selected input safely.")
                }
                offset += written
            }
            copied += off_t(count)
        }
        guard copied == expectedSize else {
            throw MorphError.invalidInput("The selected file changed while Morph was creating a private copy.")
        }
    }

    private static func sameRevision(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev
            && first.st_ino == second.st_ino
            && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}
