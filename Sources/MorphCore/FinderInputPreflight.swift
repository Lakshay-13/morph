import Darwin
import Foundation

public enum FinderInputPreflightError: Error, Equatable, Sendable {
    case invalidPath
    case symbolicLink
    case notRegularFile
    case openFailed(Int32)
}

/// Checks Finder-selected inputs without following links or blocking on special files.
/// Call this away from the UI thread because opening a protected path can trigger TCC.
public enum FinderInputPreflight {
    public static func validate(paths: [String]) throws -> [URL] {
        var inputs: [URL] = []
        inputs.reserveCapacity(paths.count)

        for path in paths {
            guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4_096 else {
                throw FinderInputPreflightError.invalidPath
            }
            let descriptor = path.withCString {
                open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                if errno == ELOOP { throw FinderInputPreflightError.symbolicLink }
                throw FinderInputPreflightError.openFailed(errno)
            }
            defer { close(descriptor) }

            var information = stat()
            guard fstat(descriptor, &information) == 0 else {
                throw FinderInputPreflightError.openFailed(errno)
            }
            guard information.st_mode & S_IFMT == S_IFREG else {
                throw FinderInputPreflightError.notRegularFile
            }
            inputs.append(URL(fileURLWithPath: path).standardizedFileURL)
        }

        return inputs
    }
}
