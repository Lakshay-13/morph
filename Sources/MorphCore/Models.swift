import Darwin
import Foundation

public enum FormatCategory: String, CaseIterable, Codable, Sendable {
    case image = "Images"
    case video = "Video"
    case audio = "Audio"
    case document = "Documents"
    case spreadsheet = "Spreadsheets & data"
    case archive = "Archives"
}

enum MediaMetadataPolicy {
    static let ffmpegLocationRemovalArguments = [
        "-metadata", "location=", "-metadata:s", "location=",
        "-metadata", "location-eng=", "-metadata:s", "location-eng=",
        "-metadata", "com.apple.quicktime.location.ISO6709=", "-metadata:s", "com.apple.quicktime.location.ISO6709=",
        "-metadata", "com.apple.quicktime.location.name=", "-metadata:s", "com.apple.quicktime.location.name=",
        "-metadata", "com.apple.quicktime.location.body=", "-metadata:s", "com.apple.quicktime.location.body=",
        "-metadata", "com.apple.quicktime.location.note=", "-metadata:s", "com.apple.quicktime.location.note=",
    ]
}

public enum PDFCompressionPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case compact
    case balanced
    case printQuality

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .compact: "Compact file"
        case .balanced: "Balanced"
        case .printQuality: "Print quality"
        }
    }

    var ghostscriptSetting: String {
        switch self {
        case .compact: "/screen"
        case .balanced: "/ebook"
        case .printQuality: "/printer"
        }
    }
}

public enum VideoCompressionQuality: String, CaseIterable, Codable, Identifiable, Sendable {
    case compact
    case balanced
    case higherQuality

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .compact: "Smaller file"
        case .balanced: "Balanced"
        case .higherQuality: "Higher quality"
        }
    }

    var ffmpegCRF: Int {
        switch self {
        case .compact: 30
        case .balanced: 26
        case .higherQuality: 22
        }
    }

    var audioBitrate: String {
        switch self {
        case .compact: "96k"
        case .balanced: "128k"
        case .higherQuality: "192k"
        }
    }
}

public enum VideoResolutionLimit: String, CaseIterable, Codable, Identifiable, Sendable {
    case fullHD
    case hd
    case original

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fullHD: "Up to 1080p"
        case .hd: "Up to 720p"
        case .original: "Keep original size"
        }
    }

    func ffmpegFilter(sourceWidth: Int, sourceHeight: Int) -> String {
        let portrait = sourceHeight > sourceWidth
        let fullHD = portrait ? (width: 1080, height: 1920) : (width: 1920, height: 1080)
        let hd = portrait ? (width: 720, height: 1280) : (width: 1280, height: 720)
        switch self {
        case .fullHD:
            return "scale=w='min(\(fullHD.width),iw)':h='min(\(fullHD.height),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
        case .hd:
            return "scale=w='min(\(hd.width),iw)':h='min(\(hd.height),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
        case .original:
            return "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        }
    }

    func maximumDimensions(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let portrait = sourceHeight > sourceWidth
        switch self {
        case .fullHD:
            return portrait
                ? (min(sourceWidth, 1080), min(sourceHeight, 1920))
                : (min(sourceWidth, 1920), min(sourceHeight, 1080))
        case .hd:
            return portrait
                ? (min(sourceWidth, 720), min(sourceHeight, 1280))
                : (min(sourceWidth, 1280), min(sourceHeight, 720))
        case .original:
            return (sourceWidth, sourceHeight)
        }
    }
}

public struct VideoCompressionOptions: Hashable, Sendable {
    public let quality: VideoCompressionQuality
    public let resolutionLimit: VideoResolutionLimit

    public init(quality: VideoCompressionQuality = .balanced, resolutionLimit: VideoResolutionLimit = .fullHD) {
        self.quality = quality
        self.resolutionLimit = resolutionLimit
    }
}

public enum ConversionPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case imagesToJPEG
    case imagesToWebP80
    case videoToMP4H264
    case extractAudioToMP3
    case documentsToPDF

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .imagesToJPEG: "Images to JPEG"
        case .imagesToWebP80: "Images to WebP · 80%"
        case .videoToMP4H264: "Video to MP4 · H.264"
        case .extractAudioToMP3: "Extract audio to MP3"
        case .documentsToPDF: "Documents to PDF"
        }
    }

    public var symbol: String {
        switch self {
        case .imagesToJPEG, .imagesToWebP80: "photo"
        case .videoToMP4H264: "film"
        case .extractAudioToMP3: "waveform"
        case .documentsToPDF: "doc.text"
        }
    }

    public var outputExtension: String {
        switch self {
        case .imagesToJPEG: "jpg"
        case .imagesToWebP80: "webp"
        case .videoToMP4H264: "mp4"
        case .extractAudioToMP3: "mp3"
        case .documentsToPDF: "pdf"
        }
    }

    public var imageQualityOverride: Double? {
        self == .imagesToWebP80 ? 0.8 : nil
    }

    public func isAvailable(inputExtensions: Set<String>, outputExtensions: Set<String>) -> Bool {
        guard !inputExtensions.isEmpty, outputExtensions.contains(outputExtension) else { return false }
        return inputExtensions.allSatisfy { self.inputExtensions.contains($0.lowercased()) }
    }

    private var inputExtensions: Set<String> {
        switch self {
        case .imagesToJPEG, .imagesToWebP80:
            ["png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff", "bmp", "gif", "svg", "ico", "avif"]
        case .videoToMP4H264:
            ["mp4", "m4v", "mov", "mkv", "avi", "webm", "gif", "mpeg", "mpg", "wmv", "flv", "3gp", "3g2"]
        case .extractAudioToMP3:
            ["mp4", "m4v", "mov", "mkv", "avi", "webm", "mpeg", "mpg", "wmv", "flv", "3gp", "3g2", "mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "aiff", "aif", "wma"]
        case .documentsToPDF:
            ["doc", "docx", "odt", "rtf", "txt", "html", "htm", "md", "markdown", "epub", "ppt", "pptx", "odp", "xls", "xlsx", "ods", "csv"]
        }
    }
}

public struct MorphFormat: Hashable, Identifiable, Codable, Sendable {
    public let fileExtension: String
    public let displayName: String
    public let category: FormatCategory

    public var id: String { fileExtension }

    public init(_ fileExtension: String, _ displayName: String, _ category: FormatCategory) {
        self.fileExtension = fileExtension.lowercased()
        self.displayName = displayName
        self.category = category
    }
}

public enum EngineID: String, CaseIterable, Codable, Sendable {
    case nativeImage
    case nativePDF
    case structuredData
    case archive
    case ffmpeg
    case imageMagick
    case libvips
    case pandoc
    case ghostscript
    case sevenZip
    case libreOffice

    public var displayName: String {
        switch self {
        case .nativeImage: "Apple ImageIO"
        case .nativePDF: "Apple PDFKit"
        case .structuredData: "Morph structured-data engine"
        case .archive: "macOS archive tools"
        case .ffmpeg: "FFmpeg"
        case .imageMagick: "ImageMagick"
        case .libvips: "libvips"
        case .pandoc: "Pandoc"
        case .ghostscript: "Ghostscript"
        case .sevenZip: "7-Zip"
        case .libreOffice: "LibreOffice"
        }
    }

    public var homebrewPackageName: String? {
        switch self {
        case .ffmpeg: "ffmpeg"
        case .imageMagick: "imagemagick"
        case .libvips: "vips"
        case .pandoc: "pandoc"
        case .ghostscript: "ghostscript"
        case .sevenZip: "sevenzip"
        case .libreOffice: "libreoffice"
        default: nil
        }
    }

    public static let homebrewMetadataRefreshArguments = ["update"]

    public var homebrewPackageFlag: String? {
        switch self {
        case .libreOffice: "--cask"
        case .ffmpeg, .imageMagick, .libvips, .pandoc, .ghostscript, .sevenZip: "--formula"
        default: nil
        }
    }

    public func homebrewArguments(action: String) -> [String]? {
        guard let packageName = homebrewPackageName, let packageFlag = homebrewPackageFlag,
              ["install", "uninstall", "outdated", "upgrade"].contains(action) else { return nil }
        if action == "outdated" { return [action, "--quiet", packageFlag, packageName] }
        return [action, packageFlag, packageName]
    }

    public func isHomebrewPackageOutdated(
        exitStatus: Int32,
        standardOutput: String,
        standardError: String
    ) throws -> Bool {
        guard let packageName = homebrewPackageName else {
            throw MorphError.processFailed("No Homebrew package is configured for \(displayName).")
        }

        let reportedPackages = standardOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if reportedPackages.isEmpty {
            guard exitStatus == 0 else {
                throw MorphError.processFailed("Homebrew exited with status \(exitStatus) while checking \(displayName). \(standardError)")
            }
            return false
        }

        guard (exitStatus == 0 || exitStatus == 1),
              reportedPackages.count == 1,
              reportedPackages[0].caseInsensitiveCompare(packageName) == .orderedSame else {
            let diagnostic = [standardOutput, standardError]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            throw MorphError.processFailed("Homebrew returned an unexpected result while checking \(displayName) (status \(exitStatus)). \(diagnostic)")
        }
        return true
    }

    public static func homebrewUpgradeBatches(for engines: [EngineID]) -> [[String]] {
        var formulaNames = Set<String>()
        var caskNames = Set<String>()
        for engine in Set(engines) {
            guard let packageName = engine.homebrewPackageName else { continue }
            switch engine.homebrewPackageFlag {
            case "--formula": formulaNames.insert(packageName)
            case "--cask": caskNames.insert(packageName)
            default: continue
            }
        }

        var batches: [[String]] = []
        if !formulaNames.isEmpty {
            batches.append(["upgrade", "--no-ask", "--formula"] + formulaNames.sorted())
        }
        if !caskNames.isEmpty {
            batches.append(["upgrade", "--no-ask", "--cask"] + caskNames.sorted())
        }
        return batches
    }

    public var executableNames: [String] {
        switch self {
        case .ffmpeg: ["ffmpeg"]
        case .imageMagick: ["magick"]
        case .libvips: ["vips"]
        case .pandoc: ["pandoc"]
        case .ghostscript: ["gs"]
        case .sevenZip: ["7zz", "7z"]
        case .libreOffice: ["soffice"]
        case .nativeImage, .nativePDF, .structuredData, .archive: []
        }
    }

    public var summary: String {
        switch self {
        case .nativeImage: "Convert formats supported by macOS ImageIO."
        case .nativePDF: "Create PDFs from images, render PDF pages as PNG images, and perform PDF page operations."
        case .structuredData: "Convert JSON, YAML, TOML, CSV, TSV and XML locally."
        case .archive: "Repackage ZIP and TAR archives with macOS tools."
        case .ffmpeg: "Convert common audio and video formats using the installed FFmpeg build."
        case .imageMagick: "Additional image formats and image transformations."
        case .libvips: "Memory-efficient conversion and resizing for large images."
        case .pandoc: "Convert supported documents, markup and presentations."
        case .ghostscript: "Compress PDFs locally with selectable Ghostscript presets."
        case .sevenZip: "Create and unpack 7z archives and convert them to and from ZIP."
        case .libreOffice: "Office document, spreadsheet and presentation conversions."
        }
    }
}

enum EngineSecurityPolicy {
    static func validateExecutable(
        _ executable: URL,
        for engine: EngineID,
        cancellation: CancellationToken? = nil
    ) throws {
        guard [.ffmpeg, .imageMagick, .libreOffice, .pandoc, .ghostscript, .sevenZip].contains(engine) else { return }
        guard EngineExecutableTrust.isApproved(executable, identifier: engine.rawValue) else {
            throw MorphError.processFailed("Morph has not approved this installed executable. Review the engine in Morph before converting.")
        }
        let unavailableNotice = "Morph could not verify this engine's version, so its conversion is blocked until the version can be verified."
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(
                executable: executable,
                arguments: versionArguments(for: engine),
                cancellation: cancellation,
                maximumOutputBytes: 8_192,
                timeout: 10,
                restrictedSandbox: true
            )
        } catch let error as MorphError {
            if case .cancelled = error { throw error }
            throw MorphError.processFailed(unavailableNotice)
        } catch {
            throw MorphError.processFailed(unavailableNotice)
        }
        if cancellation?.isCancelled == true { throw MorphError.cancelled }
        guard result.status == 0,
              !result.stdoutWasTruncated,
              !result.stderrWasTruncated else {
            throw MorphError.processFailed(unavailableNotice)
        }
        let version = result.stdout + "\n" + result.stderr
        guard let notice = notice(for: engine, version: version, executableName: executable.lastPathComponent) else { return }
        throw MorphError.processFailed(notice)
    }

    static func versionArguments(for engine: EngineID) -> [String] {
        switch engine {
        case .ffmpeg, .imageMagick: ["-version"]
        case .libreOffice, .pandoc, .ghostscript: ["--version"]
        case .sevenZip: ["--help"]
        default: ["--version"]
        }
    }

    static func notice(for engine: EngineID, version: String?) -> String? {
        notice(for: engine, version: version, executableName: nil)
    }

    private static func notice(for engine: EngineID, version: String?, executableName: String?) -> String? {
        guard [.ffmpeg, .imageMagick, .libreOffice, .pandoc, .ghostscript, .sevenZip].contains(engine) else { return nil }
        guard let components = versionComponents(version, for: engine, executableName: executableName) else {
            return "Morph could not verify this engine's version, so its conversion routes are disabled until the version can be verified."
        }

        switch engine {
        case .ffmpeg:
            return isAtLeast(components, [9, 0, 2])
                ? nil
                : "FFmpeg is older than Morph's security floor (9.0.2). Update FFmpeg before converting with it."
        case .imageMagick:
            return isAtLeast(components, [7, 1, 2, 36])
                ? nil
                : "ImageMagick is older than Morph's security floor (7.1.2-36). Update ImageMagick before converting with it."
        case .libreOffice:
            let major = components[0]
            let minor = components[1]
            let supported = major > 26
                || (major == 26 && minor == 2 && isAtLeast(components, [26, 2, 7]))
                || (major == 26 && minor >= 8 && isAtLeast(components, [26, 8, 2]))
            return supported ? nil : "LibreOffice is older than Morph's security floor (26.2.7 or 26.8.2, depending on release branch). Update LibreOffice before converting with it."
        case .pandoc:
            return isAtLeast(components, [3, 14])
                ? nil
                : "Pandoc is older than Morph's security floor (3.14). Update Pandoc before converting with it."
        case .ghostscript:
            return isAtLeast(components, [10, 8, 0])
                ? nil
                : "Ghostscript is older than Morph's security floor (10.08.0). Update Ghostscript before processing PDFs with it."
        case .sevenZip:
            return isAtLeast(components, [26, 6])
                ? nil
                : "7-Zip is older than Morph's security floor (26.06). Update 7-Zip before creating or validating archives with it."
        default:
            return nil
        }
    }

    private static func versionComponents(_ value: String?, for engine: EngineID, executableName: String?) -> [Int]? {
        guard let value else { return nil }
        guard let firstLine = value.split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        let line = String(firstLine)
        let pattern: String
        switch engine {
        case .ffmpeg:
            let expectedBanner = executableName == "ffprobe" ? "ffprobe" : "ffmpeg"
            pattern = #"^\#(expectedBanner) version\s+([0-9]+(?:\.[0-9]+){1,3})(?=[\s+\-]|$)"#
        case .imageMagick:
            pattern = #"^Version:\s+ImageMagick\s+([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9]+)?)(?=[\s+]|$)"#
        case .libreOffice:
            pattern = #"^LibreOffice\s+([0-9]+(?:\.[0-9]+){2,3})(?=[\s+\-]|$)"#
        case .pandoc:
            pattern = #"^pandoc\s+([0-9]+(?:\.[0-9]+){1,3})(?=[\s+\-]|$)"#
        case .ghostscript:
            // `gs --version` prints only the version, while some builds print a
            // Ghostscript-prefixed banner. The first nonempty line is checked
            // below so a later library/compiler or banner cannot satisfy the floor.
            pattern = #"^(?:(?:GPL\s+)?Ghostscript\s+)?([0-9]+\.[0-9]+\.[0-9]+)(?=[\s+\-]|$)"#
        case .sevenZip:
            pattern = #"^7-Zip(?:\s+\([A-Za-z]\))?\s+([0-9]+(?:\.[0-9]+){1,3})(?=[\s+\-]|$)"#
        default:
            return nil
        }
        return capturedVersionComponents(in: line, pattern: pattern)
    }

    private static func capturedVersionComponents(in value: String, pattern: String) -> [Int]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        let normalized = value[range].replacingOccurrences(of: "-", with: ".")
        let components = normalized.split(separator: ".").compactMap { Int($0) }
        return components.count >= 2 ? components : nil
    }

    private static func isAtLeast(_ actual: [Int], _ minimum: [Int]) -> Bool {
        for index in 0..<max(actual.count, minimum.count) {
            let actualValue = index < actual.count ? actual[index] : 0
            let minimumValue = index < minimum.count ? minimum[index] : 0
            if actualValue != minimumValue { return actualValue > minimumValue }
        }
        return true
    }
}

public struct EngineStatus: Codable, Identifiable, Sendable {
    public let id: EngineID
    public let executableURL: URL?
    public let version: String?
    public let supportedInputExtensions: Set<String>
    public let supportedOutputExtensions: Set<String>
    public let requiresApproval: Bool
    public let availabilityNotice: String?

    public var isInstalled: Bool { executableURL != nil || Self.isBuiltIn(id) }
    public var securityNotice: String? {
        if requiresApproval {
            return EngineExecutableTrust.approvalStorageUnavailableReason
                ?? "This executable has not been approved. Review it in Engines before Morph runs it."
        }
        return EngineSecurityPolicy.notice(for: id, version: version)
    }
    public var canConvert: Bool { isInstalled && !requiresApproval && securityNotice == nil && availabilityNotice == nil }
    public var isBuiltIn: Bool { Self.isBuiltIn(id) }

    public init(
        id: EngineID,
        executableURL: URL? = nil,
        version: String? = nil,
        supportedInputExtensions: Set<String> = [],
        supportedOutputExtensions: Set<String> = [],
        requiresApproval: Bool = false,
        availabilityNotice: String? = nil
    ) {
        self.id = id
        self.executableURL = executableURL
        self.version = version
        self.supportedInputExtensions = supportedInputExtensions
        self.supportedOutputExtensions = supportedOutputExtensions
        self.requiresApproval = requiresApproval
        self.availabilityNotice = availabilityNotice
    }

    private enum CodingKeys: String, CodingKey {
        case id, executableURL, version, supportedInputExtensions, supportedOutputExtensions, requiresApproval, availabilityNotice
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(EngineID.self, forKey: .id)
        executableURL = try values.decodeIfPresent(URL.self, forKey: .executableURL)
        version = try values.decodeIfPresent(String.self, forKey: .version)
        supportedInputExtensions = try values.decodeIfPresent(Set<String>.self, forKey: .supportedInputExtensions) ?? []
        supportedOutputExtensions = try values.decodeIfPresent(Set<String>.self, forKey: .supportedOutputExtensions) ?? []
        requiresApproval = try values.decodeIfPresent(Bool.self, forKey: .requiresApproval) ?? false
        availabilityNotice = try values.decodeIfPresent(String.self, forKey: .availabilityNotice)
    }

    private static func isBuiltIn(_ id: EngineID) -> Bool {
        switch id {
        case .nativeImage, .nativePDF, .structuredData, .archive: true
        default: false
        }
    }
}

public struct ConversionRoute: Codable, Hashable, Identifiable, Sendable {
    public let inputExtension: String
    public let output: MorphFormat
    public let engine: EngineID
    public let description: String

    public var id: String { "\(inputExtension)->\(output.fileExtension):\(engine.rawValue)" }

    public init(inputExtension: String, output: MorphFormat, engine: EngineID, description: String) {
        self.inputExtension = inputExtension.lowercased()
        self.output = output
        self.engine = engine
        self.description = description
    }
}

public struct ConversionRequest: Sendable {
    public let inputURL: URL
    public let outputFormat: MorphFormat
    public let outputDirectory: URL
    public let imageQuality: Double
    public let stripLocationMetadata: Bool

    public init(
        inputURL: URL,
        outputFormat: MorphFormat,
        outputDirectory: URL,
        imageQuality: Double = 0.85,
        stripLocationMetadata: Bool = true
    ) {
        self.inputURL = inputURL
        self.outputFormat = outputFormat
        self.outputDirectory = outputDirectory
        self.imageQuality = min(max(imageQuality, 0.1), 1.0)
        self.stripLocationMetadata = stripLocationMetadata
    }
}

public struct ConversionResult: Sendable {
    public let inputURL: URL
    public let outputURL: URL
    public let engine: EngineID
    public let completedAt: Date
}

public struct ConversionHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let inputName: String
    public let outputPath: String
    public let engineName: String
    public let date: Date

    public init(id: UUID = UUID(), inputName: String, outputPath: String, engineName: String, date: Date) {
        self.id = id
        self.inputName = inputName
        self.outputPath = outputPath
        self.engineName = engineName
        self.date = date
    }
}

public enum ConversionHistoryStore {
    private static let maximumBytes = 2 * 1024 * 1024
    private static let maximumEntries = 200

    public static func load(from url: URL) throws -> [ConversionHistoryEntry] {
        try withLock(for: url) {
            try readUnlocked(from: url)
        }
    }

    @discardableResult
    public static func merge(
        _ additions: [ConversionHistoryEntry],
        into url: URL
    ) throws -> [ConversionHistoryEntry] {
        guard !additions.isEmpty else { return try load(from: url) }
        return try withLock(for: url) {
            var merged = try readUnlocked(from: url)
            var knownIDs = Set(merged.map(\.id))
            for entry in additions where knownIDs.insert(entry.id).inserted {
                merged.append(entry)
            }
            merged.sort { $0.date > $1.date }
            merged = Array(merged.prefix(maximumEntries))
            let data = try JSONEncoder().encode(merged)
            guard data.count <= maximumBytes else {
                throw MorphError.invalidOutput("Morph's conversion history exceeded its storage limit.")
            }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: .atomic)
            _ = chmod(url.path, mode_t(0o600))
            return merged
        }
    }

    public static func clear(from url: URL) throws {
        try withLock(for: url) {
            let descriptor = url.path.withCString {
                open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
            if descriptor < 0, errno != ENOENT {
                throw MorphError.processFailed("Morph could not clear conversion history safely.")
            }
            if descriptor >= 0 {
                defer { close(descriptor) }
                var info = stat()
                guard fstat(descriptor, &info) == 0,
                      info.st_mode & S_IFMT == S_IFREG,
                      info.st_uid == geteuid() else {
                    throw MorphError.invalidInput("Morph's history file is not a private regular file; it was left unchanged.")
                }
            }
            try Data("[]".utf8).write(to: url, options: .atomic)
            guard chmod(url.path, mode_t(0o600)) == 0 else {
                throw MorphError.processFailed("Morph could not protect the cleared history file.")
            }
        }
    }

    private static func withLock<T>(for url: URL, _ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(directory.path, mode_t(0o700))
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = lockURL.path.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else {
            throw MorphError.processFailed("Morph could not lock conversion history safely.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              flock(descriptor, LOCK_EX) == 0 else {
            throw MorphError.processFailed("Morph could not lock conversion history safely.")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func readUnlocked(from url: URL) throws -> [ConversionHistoryEntry] {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        if descriptor < 0 {
            if errno == ENOENT { return [] }
            throw MorphError.processFailed("Morph could not read conversion history safely.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            throw MorphError.invalidInput("Morph's history file is not a regular file or exceeds its size limit.")
        }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        while offset < data.count {
            let result = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else {
                throw MorphError.processFailed("Morph could not read the complete conversion history file.")
            }
            offset += Int(result)
        }
        do {
            return try JSONDecoder().decode([ConversionHistoryEntry].self, from: data)
        } catch {
            throw MorphError.invalidInput("Morph's conversion history is malformed; it was left unchanged.")
        }
    }
}

public enum MorphError: LocalizedError {
    case unsupportedInput(URL)
    case unsupportedConversion(String, String)
    case missingEngine(EngineID)
    case invalidInput(String)
    case invalidOutput(String)
    case processFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput(let url): "Morph does not recognize the input format ‘\(url.pathExtension)’."
        case .unsupportedConversion(let input, let output): "Morph cannot convert .\(input) to .\(output) with the engines currently available."
        case .missingEngine(let engine): "\(engine.displayName) is required for this conversion."
        case .invalidInput(let detail): "The input file is invalid: \(detail)"
        case .invalidOutput(let detail): "The conversion produced an invalid output: \(detail)"
        case .processFailed(let detail): detail
        case .cancelled: "Conversion cancelled."
        }
    }
}

public extension URL {
    func morphExtension(knownExtensions: Set<String>) -> String? {
        let lowerName = lastPathComponent.lowercased()
        return knownExtensions
            .sorted { $0.count > $1.count }
            .first { lowerName.hasSuffix(".\($0)") }
    }
}
