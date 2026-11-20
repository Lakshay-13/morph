import CryptoKit
import CArchive
import Darwin
import Foundation
import Security

/// Requires explicit approval before Morph executes a user-managed conversion engine.
/// Approvals are stored in the Data Protection Keychain's shared, team-prefixed
/// access group, which is available only to signed Morph app/helper builds.
public enum EngineExecutableTrust {
    private static let keychainService = "com.lakshaychawla.Morph.engine-executable-approvals.v2"
    private static let outputDirectoryAccount = "protected-output-directory"
    private static let appBundleID = "com.lakshaychawla.Morph"

    public static var approvalStorageUnavailableReason: String? {
        protectedKeychainAccessGroup() == nil
            ? "External engines, Homebrew actions, and custom output folders need a signed Morph build with a shared team Keychain access group. This local ad-hoc build cannot safely store those approvals, so those actions are disabled. Built-in conversions remain available."
            : nil
    }

    public static var canStorePersistentApprovals: Bool {
        approvalStorageUnavailableReason == nil
    }

    /// Performs a disposable read/write check for release packaging. The item
    /// is removed before returning and contains no user data.
    public static func verifyPersistentKeychainAccess() -> Bool {
        let account = "release-keychain-self-test.\(UUID().uuidString)"
        guard var addition = keychainQuery(account: account) else { return false }
        let value = Data(UUID().uuidString.utf8)
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addition[kSecValueData as String] = value
        guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { return false }
        defer { _ = SecItemDelete(addition as CFDictionary) }
        return keychainData(account: account) == value
    }

    static func authenticatedStageMarker(for directoryName: String) -> Data? {
        guard protectedKeychainAccessGroup() != nil else { return nil }
        guard let keyData = stageMarkerHMACKey(), keyData.count == 32 else { return nil }
        return stageMarker(for: directoryName, keyData: keyData)
    }

    static func stageMarker(for directoryName: String, keyData: Data) -> Data? {
        guard keyData.count == 32 else { return nil }
        let message = Data("Morph private staging directory v2\n\(directoryName)\n".utf8)
        let key = SymmetricKey(data: keyData)
        let tag = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data("Morph private staging directory v2\n\(directoryName)\n\(Data(tag).base64EncodedString())\n".utf8)
    }

    public static func requiredExecutables(for engine: EngineID) -> [URL] {
        if engine == .libreOffice {
            return ExecutableLocator.resolveEngine(engine).map { [$0] } ?? []
        }
        var names = engine.executableNames
        if engine == .sevenZip {
            names = names.first(where: { ExecutableLocator.resolve([$0]) != nil }).map { [$0] } ?? names
        }
        if engine == .ffmpeg { names.append("ffprobe") }
        var seen = Set<String>()
        return names.compactMap { name in
            guard let url = ExecutableLocator.resolve([name]) else { return nil }
            let path = url.standardizedFileURL.path
            return seen.insert(path).inserted ? url : nil
        }
    }

    public static func isEngineApproved(_ engine: EngineID) -> Bool {
        let executables = requiredExecutables(for: engine)
        return !executables.isEmpty && executables.allSatisfy {
            isApproved($0, identifier: engine.rawValue)
        }
    }

    public static func isApproved(_ executable: URL, identifier: String) -> Bool {
        #if DEBUG
        if let override = TestingApprovalOverride.shared.value(for: identifier, executable: executable) {
            return override
        }
        #endif
        guard protectedKeychainAccessGroup() != nil,
              let fingerprint = try? fingerprintData(for: executable),
              let keychainAccount = try? account(identifier: identifier, executable: executable),
              let approved = keychainData(account: keychainAccount) else {
            return false
        }
        return fingerprint == approved
    }

    /// Returns the SHA-256 fingerprint shown in the executable approval prompt.
    public static func fingerprint(for executable: URL) throws -> String {
        try fingerprintData(for: executable).map { String(format: "%02x", $0) }.joined()
    }

    public static func ownerSummary(for executable: URL) throws -> String {
        let canonical = executable.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = canonical.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw MorphError.invalidInput("Morph could not inspect the executable owner.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw MorphError.invalidInput("Morph could not inspect the executable owner.")
        }
        let label = info.st_uid == 0 ? "root" : (info.st_uid == geteuid() ? "current user" : "other account")
        return "\(label) (UID \(info.st_uid))"
    }

    @discardableResult
    public static func approve(_ executable: URL, identifier: String, expectedFingerprint: String) throws -> String {
        guard protectedKeychainAccessGroup() != nil else {
            throw MorphError.processFailed(approvalStorageUnavailableReason ?? "Morph cannot store a protected engine approval.")
        }
        let fingerprint = try fingerprintData(for: executable)
        let currentFingerprint = fingerprint.map { String(format: "%02x", $0) }.joined()
        guard expectedFingerprint == currentFingerprint else {
            throw MorphError.processFailed("The executable changed after Morph displayed its approval details. Review the new file before approving it.")
        }
        let keychainAccount = try account(identifier: identifier, executable: executable)
        guard let query = keychainQuery(account: keychainAccount) else {
            throw MorphError.processFailed(approvalStorageUnavailableReason ?? "Morph cannot store a protected engine approval.")
        }
        let attributes: [String: Any] = [
            kSecValueData as String: fingerprint,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            attributes.forEach { addition[$0.key] = $0.value }
            status = SecItemAdd(addition as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw MorphError.processFailed("Morph could not save the executable approval in Keychain (status \(status)).")
        }
        return currentFingerprint
    }

    public static func revoke(_ executable: URL, identifier: String) {
        guard let keychainAccount = try? account(identifier: identifier, executable: executable) else { return }
        guard let query = keychainQuery(account: keychainAccount) else { return }
        _ = SecItemDelete(query as CFDictionary)
    }

    public static func homebrewExecutable() -> URL? {
        ExecutableLocator.resolve(["brew"])
    }

    public static func isHomebrewApproved(_ executable: URL) -> Bool {
        isApproved(executable, identifier: "homebrew")
    }

    public static func revokeHomebrew(_ executable: URL) {
        revoke(executable, identifier: "homebrew")
    }

    public static func setProtectedOutputDirectory(_ directory: URL) throws {
        guard protectedKeychainAccessGroup() != nil else {
            throw MorphError.invalidOutput(approvalStorageUnavailableReason ?? "Morph cannot protect the selected output folder.")
        }
        let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = canonical.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw MorphError.invalidOutput("Morph could not protect the selected output folder. Choose a local folder that exists.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw MorphError.invalidOutput("Morph could not verify the selected output folder.")
        }
        let record = ProtectedOutputDirectory(
            path: canonical.path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
        let data = try JSONEncoder().encode(record)
        try storeKeychainData(data, account: revisionedAccount(outputDirectoryAccount))
    }

    public static func protectedOutputDirectoryMatches(_ directory: URL) -> Bool {
        guard let data = keychainData(account: revisionedAccount(outputDirectoryAccount)),
              let record = try? JSONDecoder().decode(ProtectedOutputDirectory.self, from: data),
              directory.standardizedFileURL.path == record.path else { return false }
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        return fstat(descriptor, &info) == 0
            && info.st_mode & S_IFMT == S_IFDIR
            && UInt64(info.st_dev) == record.device
            && UInt64(info.st_ino) == record.inode
    }

    #if DEBUG
    static func setTestingApprovalOverride(_ handler: ((String, URL) -> Bool)?) {
        TestingApprovalOverride.shared.set(handler)
    }
    #endif

    private static func fingerprintData(for executable: URL) throws -> Data {
        guard executable.isFileURL else {
            throw MorphError.invalidInput("Morph could not verify the engine executable path.")
        }
        let canonical = executable.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = canonical.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw MorphError.invalidInput("Morph could not open the engine executable for verification.")
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o111 != 0 else {
            throw MorphError.invalidInput("Morph rejected an executable in a path that is not safely protected.")
        }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              info.st_uid == geteuid() || info.st_uid == 0 else {
            throw MorphError.invalidInput("Morph rejected an executable with unsafe file ownership or permissions.")
        }
        let aclStatus = morph_acl_has_write_grant(descriptor)
        guard aclStatus == 0 else {
            throw MorphError.invalidInput(aclStatus < 0
                ? "Morph could not inspect the executable's access-control list safely."
                : "Morph rejected an executable ACL that grants write or delete access.")
        }
        if let parentFailure = trustedParentDirectoryFailure(canonical) {
            throw MorphError.invalidInput("Morph rejected an executable inside an unsafe parent directory: \(parentFailure).")
        }

        let key = FingerprintCache.Key(url: canonical, stat: info)
        if let cached = FingerprintCache.shared.value(for: key) {
            var afterLookup = stat()
            guard fstat(descriptor, &afterLookup) == 0,
                  afterLookup.st_dev == info.st_dev,
                  afterLookup.st_ino == info.st_ino,
                  afterLookup.st_size == info.st_size,
                  afterLookup.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  afterLookup.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                  afterLookup.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                  afterLookup.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
                throw MorphError.invalidInput("The engine executable changed while Morph was verifying it.")
            }
            return cached
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw MorphError.processFailed("Morph could not finish verifying the engine executable.")
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var afterRead = stat()
        guard fstat(descriptor, &afterRead) == 0,
              afterRead.st_dev == info.st_dev,
              afterRead.st_ino == info.st_ino,
              afterRead.st_size == info.st_size,
              afterRead.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              afterRead.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              afterRead.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
              afterRead.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
            throw MorphError.invalidInput("The engine executable changed while Morph was verifying it.")
        }
        let digest = Data(hasher.finalize())
        FingerprintCache.shared.insert(digest, for: key)
        return digest
    }

    private static func trustedParentDirectoryFailure(_ executable: URL) -> String? {
        let components = executable.standardizedFileURL.path.split(separator: "/")
        let rootDescriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { return "the filesystem root could not be inspected" }
        var currentDescriptor = rootDescriptor
        defer { close(currentDescriptor) }

        var rootInfo = stat()
        guard fstat(currentDescriptor, &rootInfo) == 0,
              rootInfo.st_uid == 0,
              rootInfo.st_mode & (S_IWGRP | S_IWOTH) == 0,
              morph_acl_has_write_grant(currentDescriptor) == 0 else { return "the filesystem root has unsafe ownership, permissions, or ACLs" }

        var path = ""
        for component in components.dropLast() {
            path += "/\(component)"
            let nextDescriptor = String(component).withCString {
                openat(currentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard nextDescriptor >= 0 else { return "\(path) could not be opened without following a symlink" }
            close(currentDescriptor)
            currentDescriptor = nextDescriptor

            var info = stat()
            guard fstat(currentDescriptor, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR else { return "\(path) is not a directory" }
            guard info.st_uid == geteuid() || info.st_uid == 0 else { return "\(path) is owned by an untrusted account" }
            let writableByGroup = info.st_mode & S_IWGRP != 0
            let writableByEveryone = info.st_mode & S_IWOTH != 0
            if writableByGroup || writableByEveryone {
                guard writableByGroup,
                      !writableByEveryone,
                      info.st_gid == Self.adminGroupID() else {
                    return "\(path) is writable by accounts outside the administrator group"
                }
            }
            let aclStatus = morph_acl_has_write_grant(currentDescriptor)
            guard aclStatus == 0 else {
                return aclStatus < 0 ? "\(path) ACL could not be inspected" : "\(path) ACL grants write or delete access"
            }
        }
        return nil
    }

    private static func adminGroupID() -> gid_t? {
        var entry = group()
        var result: UnsafeMutablePointer<group>?
        var storage = [CChar](repeating: 0, count: 1_024)
        let status = "admin".withCString {
            getgrnam_r($0, &entry, &storage, storage.count, &result)
        }
        guard status == 0, result != nil else { return nil }
        return entry.gr_gid
    }

    private static func account(identifier: String, executable: URL) throws -> String {
        let pathDigest = SHA256.hash(data: Data(executable.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(identifier).\(pathDigest)"
    }

    private static func revisionedAccount(_ identifier: String) -> String {
        identifier
    }

    private static func keychainData(account: String) -> Data? {
        guard let query = keychainQuery(account: account) else { return nil }
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func stageMarkerHMACKey() -> Data? {
        let account = "stage-marker-hmac-key"
        if let existing = keychainData(account: account) { return existing }
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = randomBytes.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess,
              var addition = keychainQuery(account: account) else { return nil }
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addition[kSecValueData as String] = Data(randomBytes)
        let status = SecItemAdd(addition as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return nil }
        return keychainData(account: account)
    }

    private static func keychainQuery(account: String) -> [String: Any]? {
        guard let accessGroup = protectedKeychainAccessGroup() else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func storeKeychainData(_ data: Data, account: String) throws {
        guard let query = keychainQuery(account: account) else {
            throw MorphError.processFailed(approvalStorageUnavailableReason ?? "Morph cannot store a protected setting.")
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            attributes.forEach { addition[$0.key] = $0.value }
            status = SecItemAdd(addition as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw MorphError.processFailed("Morph could not save this protected setting in Keychain (status \(status)).")
        }
    }

    private static func protectedKeychainAccessGroup() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let information = signingInformation as? [String: Any],
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamIdentifier.isEmpty,
              let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let groups = entitlements["keychain-access-groups"] as? [String] else { return nil }
        return matchingAccessGroup(
            teamIdentifier: teamIdentifier,
            bundleIdentifier: appBundleID,
            groups: groups
        )
    }

    static func matchingAccessGroup(
        teamIdentifier: String,
        bundleIdentifier: String,
        groups: [String]
    ) -> String? {
        guard !teamIdentifier.isEmpty, !bundleIdentifier.isEmpty else { return nil }
        let expectedGroup = "\(teamIdentifier).\(bundleIdentifier)"
        return groups.first { $0 == expectedGroup }
    }

    private struct ProtectedOutputDirectory: Codable {
        let path: String
        let device: UInt64
        let inode: UInt64
    }

    private final class FingerprintCache: @unchecked Sendable {
        struct Key: Hashable {
            let path: String
            let device: UInt64
            let inode: UInt64
            let size: Int64
            let modifiedSeconds: Int
            let modifiedNanoseconds: Int
            let changedSeconds: Int
            let changedNanoseconds: Int

            init(url: URL, stat info: stat) {
                path = url.path
                device = UInt64(info.st_dev)
                inode = UInt64(info.st_ino)
                size = Int64(info.st_size)
                modifiedSeconds = Int(info.st_mtimespec.tv_sec)
                modifiedNanoseconds = Int(info.st_mtimespec.tv_nsec)
                changedSeconds = Int(info.st_ctimespec.tv_sec)
                changedNanoseconds = Int(info.st_ctimespec.tv_nsec)
            }
        }

        static let shared = FingerprintCache()
        private let lock = NSLock()
        private var digests: [Key: Data] = [:]

        func value(for key: Key) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return digests[key]
        }

        func insert(_ digest: Data, for key: Key) {
            lock.lock()
            defer { lock.unlock() }
            if digests.count >= 64, !digests.keys.contains(key) { digests.removeValue(forKey: digests.keys.first!) }
            digests[key] = digest
        }
    }

    #if DEBUG
    private final class TestingApprovalOverride: @unchecked Sendable {
        static let shared = TestingApprovalOverride()
        private let lock = NSLock()
        private var handler: ((String, URL) -> Bool)?

        func set(_ handler: ((String, URL) -> Bool)?) {
            lock.lock()
            self.handler = handler
            lock.unlock()
        }

        func value(for identifier: String, executable: URL) -> Bool? {
            lock.lock()
            let current = handler
            lock.unlock()
            return current?(identifier, executable)
        }
    }
    #endif
}
