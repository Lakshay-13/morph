import Darwin
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers
import os

private enum EngineProbeConfiguration {
    static let timeout: TimeInterval = 10
    static let conversionTimeout: TimeInterval = 10
    static let libreOfficeUnavailableNotice = "LibreOffice is installed, but Morph could not verify a conversion inside its private sandbox. Its routes are disabled; update LibreOffice and refresh engines to try again."
}

public struct EngineRegistry: Codable, Sendable {
    public static let containingAppBundleIdentifier = "com.lakshaychawla.Morph"
    public static let finderSyncPreferencesSnapshotKey = "com.lakshaychawla.Morph.finderSyncPreferencesSnapshot"

    public let statuses: [EngineID: EngineStatus]
    public let routes: [ConversionRoute]

    public init(statuses: [EngineID: EngineStatus], routes: [ConversionRoute]) {
        self.statuses = statuses
        self.routes = routes
    }

    public func status(for id: EngineID) -> EngineStatus? { statuses[id] }
    public func isAvailable(_ id: EngineID) -> Bool { statuses[id]?.canConvert == true }

    public static func loadFinderSyncPreferencesSnapshot() -> FinderSyncPreferencesSnapshot? {
        guard let data = UserDefaults(suiteName: containingAppBundleIdentifier)?
            .data(forKey: finderSyncPreferencesSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(FinderSyncPreferencesSnapshot.self, from: data)
    }

    public static func discover(
        cancellation: CancellationToken? = nil,
        forceCapabilityRefresh: Bool = false
    ) -> EngineRegistry {
        let imageFormats = ImageCapabilities.discover()
        var statuses = nativeStatuses(imageFormats: imageFormats)

        for id in [EngineID.ffmpeg, .imageMagick, .pandoc, .ghostscript, .sevenZip, .libreOffice] {
            if cancellation?.isCancelled == true { break }
            guard let executable = ExecutableLocator.resolveEngine(id) else {
                statuses[id] = EngineStatus(id: id)
                continue
            }
            guard EngineExecutableTrust.isEngineApproved(id) else {
                statuses[id] = EngineStatus(id: id, executableURL: executable, requiresApproval: true)
                continue
            }
            let version = probeVersion(executable, engine: id, cancellation: cancellation)
            let securityNotice = EngineSecurityPolicy.notice(for: id, version: version)
            let capabilities = securityNotice == nil
                ? probeCapabilities(executable, engine: id, cancellation: cancellation, forceCapabilityRefresh: forceCapabilityRefresh)
                : (inputs: Set<String>(), outputs: Set<String>())
            if cancellation?.isCancelled == true { break }
            let availabilityNotice = id == .libreOffice && securityNotice == nil && capabilities.inputs.isEmpty
                ? EngineProbeConfiguration.libreOfficeUnavailableNotice
                : nil
            statuses[id] = EngineStatus(
                id: id,
                executableURL: executable,
                version: version,
                supportedInputExtensions: capabilities.inputs,
                supportedOutputExtensions: capabilities.outputs,
                availabilityNotice: availabilityNotice
            )
        }

        let routes = ConversionCatalog.buildRoutes(statuses: statuses)
        return EngineRegistry(statuses: statuses, routes: routes)
    }

    public static func discoverFinderSync(cancellation: CancellationToken? = nil) -> EngineRegistry {
        if cancellation?.isCancelled == true { return EngineRegistry(statuses: [:], routes: []) }
        let statuses = nativeStatuses(imageFormats: ImageCapabilities.discover())
            .filter { $0.key == .nativeImage || $0.key == .nativePDF || $0.key == .structuredData || $0.key == .archive }
        let routes = ConversionCatalog.buildRoutes(statuses: statuses)
        return EngineRegistry(statuses: statuses, routes: routes)
    }

    private static func nativeStatuses(imageFormats: (inputs: Set<String>, outputs: Set<String>)) -> [EngineID: EngineStatus] {
        [
            .nativeImage: EngineStatus(
                id: .nativeImage,
                supportedInputExtensions: imageFormats.inputs,
                supportedOutputExtensions: imageFormats.outputs
            ),
            .nativePDF: EngineStatus(id: .nativePDF),
            .structuredData: EngineStatus(
                id: .structuredData,
                supportedInputExtensions: ["json", "csv", "tsv", "xml", "yaml", "yml", "toml"],
                supportedOutputExtensions: ["json", "csv", "tsv", "xml", "yaml", "yml", "toml"]
            ),
            .archive: EngineStatus(
                id: .archive,
                supportedInputExtensions: ArchiveEngine.builtInInputExtensions,
                supportedOutputExtensions: ArchiveEngine.builtInOutputExtensions
            ),
        ]
    }

    private static func probeVersion(_ executable: URL, engine: EngineID, cancellation: CancellationToken?) -> String? {
        let arguments = EngineSecurityPolicy.versionArguments(for: engine)
        guard let result = try? ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            cancellation: cancellation,
            timeout: EngineProbeConfiguration.timeout,
            restrictedSandbox: true
        ),
              cancellation?.isCancelled != true,
              result.status == 0,
              !result.stdoutWasTruncated,
              !result.stderrWasTruncated else { return nil }
        let text = (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n").first.map(String.init)
    }

    private static func probeCapabilities(
        _ executable: URL,
        engine: EngineID,
        cancellation: CancellationToken?,
        forceCapabilityRefresh: Bool
    ) -> (inputs: Set<String>, outputs: Set<String>) {
        if cancellation?.isCancelled == true { return ([], []) }
        switch engine {
        case .ffmpeg:
            let demuxers = outputOf(executable, ["-demuxers"], cancellation: cancellation)
            let muxers = outputOf(executable, ["-muxers"], cancellation: cancellation)
            let encoders = outputOf(executable, ["-encoders"], cancellation: cancellation)
            return (
                MediaCapabilities.extensions(from: demuxers, output: false),
                MediaCapabilities.extensions(from: muxers, output: true, encoders: encoders)
            )
        case .imageMagick:
            let formats = outputOf(executable, ["-list", "format"], cancellation: cancellation)
            return ImageMagickCapabilities.extensions(from: formats)
        case .libvips:
            // libvips support is intentionally reported in the engine list only until its
            // installed foreign-load/save operations can be probed by a dedicated adapter.
            return ([], [])
        case .pandoc:
            let inputs = outputOf(executable, ["--list-input-formats"], cancellation: cancellation)
            let outputs = outputOf(executable, ["--list-output-formats"], cancellation: cancellation)
            var capabilities = PandocCapabilities.extensions(inputs: inputs, outputs: outputs)
            if cancellation?.isCancelled != true,
               ExecutableLocator.resolve(["xelatex", "pdflatex", "lualatex", "tectonic", "wkhtmltopdf", "weasyprint"]) == nil {
                capabilities.outputs.remove("pdf")
            }
            return capabilities
        case .ghostscript:
            return ([], [])
        case .sevenZip:
            return (["7z", "zip"], ["7z", "zip"])
        case .libreOffice:
            return OfficeCapabilities.probe(executable, cancellation: cancellation, forceRefresh: forceCapabilityRefresh)
        case .nativeImage, .nativePDF, .structuredData, .archive:
            return ([], [])
        }
    }

    private static func outputOf(_ executable: URL, _ arguments: [String], cancellation: CancellationToken?) -> String {
        guard cancellation?.isCancelled != true,
              let result = try? ProcessRunner.run(
                  executable: executable,
                  arguments: arguments,
                  cancellation: cancellation,
                  timeout: EngineProbeConfiguration.timeout,
                  restrictedSandbox: true
              ),
              cancellation?.isCancelled != true,
              result.status == 0 else { return "" }
        return result.stdout
    }
}

public enum ExecutableLocator {
    /// Fixed discovery roots for optional engines. These are search locations,
    /// not a trust boundary; installed engines are user-managed executables.
    public static let engineSearchPath = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin"

    public static func resolveSystemTool(_ name: String) -> URL? {
        guard ["zip", "unzip", "tar"].contains(name) else { return nil }
        let systemDirectory = URL(fileURLWithPath: "/usr/bin", isDirectory: true)
        let candidate = systemDirectory.appendingPathComponent(name)
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent().standardizedFileURL.path == systemDirectory.standardizedFileURL.path else { return nil }
        var info = stat()
        let isExecutable = resolved.path.withCString { path in
            stat(path, &info) == 0
                && info.st_mode & S_IFMT == S_IFREG
                && info.st_mode & 0o111 != 0
                && info.st_uid == 0
                && info.st_mode & (S_IWGRP | S_IWOTH) == 0
        }
        return isExecutable ? resolved : nil
    }

    public static func resolve(_ names: [String]) -> URL? {
        let directories = engineSearchPath.split(separator: ":").map(String.init)

        for name in names {
            guard name.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil else { continue }
            for directory in directories {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
                var info = stat()
                let existsAsRegularExecutable = candidate.path.withCString { path in
                    stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o111 != 0
                }
                if existsAsRegularExecutable { return candidate.resolvingSymlinksInPath().standardizedFileURL }
            }
        }
        return nil
    }

    public static func resolveEngine(_ engine: EngineID) -> URL? {
        if engine == .libreOffice { return resolveLibreOfficeExecutable() }
        return resolve(engine.executableNames)
    }

    private static func resolveLibreOfficeExecutable() -> URL? {
        guard let launcher = resolve(["soffice"]),
              let attributes = try? FileManager.default.attributesOfItem(atPath: launcher.path),
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 16 * 1_024,
              let data = try? Data(contentsOf: launcher),
              let contents = String(data: data, encoding: .utf8) else { return nil }

        // Only accept Homebrew's two-line launcher form. Execute the native
        // Mach-O directly so the conversion sandbox never launches a shell.
        let lines = contents.split(whereSeparator: \.isNewline)
        guard lines.count == 2, lines[0] == "#!/bin/bash" else { return nil }
        let command = String(lines[1])
        let pattern = #"^exec "([^"\r\n]+/LibreOffice\.app/Contents/MacOS/soffice)"[ \t]+"\$@"$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              match.range.location == 0,
              match.range.length == (command as NSString).length,
              let range = Range(match.range(at: 1), in: command) else { return nil }
        let declaredPath = String(command[range])
        let candidate = URL(fileURLWithPath: declaredPath).standardizedFileURL
        let appBundle = candidate.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard candidate.path == declaredPath,
              candidate.path == appBundle.appendingPathComponent("Contents/MacOS/soffice").path,
              isExpectedLibreOfficeBundlePath(appBundle.path) else { return nil }
        let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
        let canonicalBundle = canonical.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard isExpectedLibreOfficeBundlePath(canonicalBundle.path),
              isMachOExecutable(canonical),
              hasTrustedLibreOfficeSignature(at: canonicalBundle) else { return nil }
        return canonical
    }

    private static func isExpectedLibreOfficeBundlePath(_ path: String) -> Bool {
        if path == "/Applications/LibreOffice.app" { return true }
        for prefix in ["/opt/homebrew/Caskroom/libreoffice/", "/usr/local/Caskroom/libreoffice/"] {
            guard path.hasPrefix(prefix) else { continue }
            let remainder = String(path.dropFirst(prefix.count))
            let components = remainder.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2,
                  components[1] == "LibreOffice.app",
                  components[0].range(of: #"^[0-9]+(?:\.[0-9]+){1,3}$"#, options: .regularExpression) != nil else { continue }
            return true
        }
        return false
    }

    private static func hasTrustedLibreOfficeSignature(at bundle: URL) -> Bool {
        guard isExpectedLibreOfficeBundlePath(bundle.path) else { return false }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            "identifier \"org.libreoffice.script\" and anchor apple generic and certificate leaf[subject.OU] = \"7P5S3ZLCN7\"" as CFString,
            [],
            &requirement
        ) == errSecSuccess,
              let requirement else { return false }
        let validationFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures | kSecCSRestrictSymlinks
        )
        guard SecStaticCodeCheckValidity(staticCode, validationFlags, requirement) == errSecSuccess else { return false }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let signingInformation,
              let information = signingInformation as NSDictionary as? [String: Any],
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = information[kSecCodeInfoIdentifier as String] as? String else {
            return false
        }
        return teamIdentifier == "7P5S3ZLCN7" && identifier == "org.libreoffice.script"
    }

    private static func isMachOExecutable(_ url: URL) -> Bool {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o111 != 0,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0,
              info.st_size >= 4 else { return false }
        var magic = [UInt8](repeating: 0, count: 4)
        guard read(descriptor, &magic, magic.count) == magic.count else { return false }
        let acceptedMagic: [[UInt8]] = [
            [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
        ]
        return acceptedMagic.contains(magic)
    }
}

private enum ImageCapabilities {
    private static let supportedExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]
    private static let cachedCapabilities = probe()

    static func discover() -> (inputs: Set<String>, outputs: Set<String>) {
        cachedCapabilities
    }

    private static func probe() -> (inputs: Set<String>, outputs: Set<String>) {
        let inputIDs = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        let outputIDs = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        let readable = extensions(for: inputIDs).intersection(supportedExtensions)
        let writable = extensions(for: outputIDs).intersection(supportedExtensions)
        return (readable, writableExtensions(from: writable))
    }

    private static func writableExtensions(from candidates: Set<String>) -> Set<String> {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morph-image-capability-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return []
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            return []
        }

        return Set(candidates.filter { fileExtension in
            guard let type = UTType(filenameExtension: fileExtension) else { return false }
            let output = directory.appendingPathComponent("probe.\(fileExtension)")
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
                return false
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination),
                  let source = CGImageSourceCreateWithURL(output as CFURL, nil),
                  CGImageSourceGetCount(source) == 1,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                return false
            }
            return true
        })
    }

    private static func extensions(for identifiers: [String]) -> Set<String> {
        let aliases: [String: [String]] = [
            "public.jpeg": ["jpg", "jpeg"],
            "public.tiff": ["tif", "tiff"],
            "public.heic": ["heic", "heif"],
            "public.png": ["png"],
            "com.compuserve.gif": ["gif"],
            "com.microsoft.bmp": ["bmp"],
            "org.webmproject.webp": ["webp"],
        ]
        var result = Set<String>()
        for identifier in identifiers {
            if let known = aliases[identifier] {
                result.formUnion(known)
                continue
            }
            if let type = UTType(identifier), type.conforms(to: .image),
               let tags = type.tags[.filenameExtension] {
                result.formUnion(tags.map { $0.lowercased() })
            }
        }
        return result
    }
}

enum FFmpegInputFormat {
    private static let demuxersByExtension: [String: String] = [
        "mp4": "mov", "m4v": "mov", "mov": "mov", "qt": "mov",
        "m4a": "mov", "3gp": "mov", "3g2": "mov", "mj2": "mov",
        "mkv": "matroska", "mk3d": "matroska", "mka": "matroska", "webm": "matroska",
        "avi": "avi", "gif": "gif", "mpeg": "mpeg", "mpg": "mpeg",
        "asf": "asf", "wmv": "asf", "wma": "asf", "flv": "flv",
        "mp3": "mp3", "wav": "wav", "flac": "flac", "aac": "aac,adts",
        "ogg": "ogg", "opus": "ogg", "aiff": "aiff", "aif": "aiff", "wv": "wv",
    ]

    static var supportedExtensions: Set<String> { Set(demuxersByExtension.keys) }

    static func whitelist(for fileExtension: String) -> String? {
        demuxersByExtension[fileExtension.lowercased()]
    }
}

private enum MediaCapabilities {
    static func extensions(from listing: String, output: Bool, encoders: String = "") -> Set<String> {
        var aliases = Set<String>()
        for line in listing.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2 else { continue }
            let flags = String(columns[0])
            guard flags.contains(output ? "E" : "D") else { continue }
            aliases.formUnion(columns[1].split(separator: ",").map { String($0).lowercased() })
        }

        var extensions = Set<String>()
        let containerMap: [String: [String]] = [
            "mp4": ["mp4", "m4v"], "mov": ["mov", "qt"], "m4a": ["m4a"],
            "3gp": ["3gp"], "3g2": ["3g2"], "mj2": ["mj2"],
            "matroska": ["mkv", "mk3d", "mka"],
            "webm": ["webm"], "avi": ["avi"], "gif": ["gif"], "mpeg": ["mpeg", "mpg"],
            "asf": ["asf", "wmv", "wma"], "flv": ["flv"], "mp3": ["mp3"], "wav": ["wav"],
            "flac": ["flac"], "aac": ["aac"], "adts": ["aac"], "ipod": ["m4a"], "ogg": ["ogg", "opus"],
            "aiff": ["aiff", "aif"], "wv": ["wv"],
        ]
        for alias in aliases { extensions.formUnion(containerMap[alias] ?? []) }
        if !output {
            extensions.formIntersection(FFmpegInputFormat.supportedExtensions)
            if !aliases.contains(where: { ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"].contains($0) }) {
                extensions.remove("m4a")
            }
        }

        if output {
            let encoderNames = Set(encoders.split(separator: "\n").compactMap { line -> String? in
                let columns = line.split(whereSeparator: \.isWhitespace)
                guard columns.count >= 2, columns[0].contains("A") || columns[0].contains("V") else { return nil }
                return String(columns[1])
            })
            let requirements: [String: [String]] = [
                "mp4": ["libx264", "aac"], "m4v": ["libx264", "aac"], "mov": ["libx264", "aac"],
                "mkv": ["libx264", "aac"], "webm": ["libvpx-vp9", "libopus"], "avi": ["mpeg4", "libmp3lame"],
                "gif": ["gif"], "mpeg": ["mpeg2video", "mp2"], "mpg": ["mpeg2video", "mp2"],
                "wmv": ["wmv2", "wmav2"], "wma": ["wmav2"], "flv": ["flv", "aac"], "mp3": ["libmp3lame"],
                "wav": ["pcm_s16le"], "flac": ["flac"], "aac": ["aac"], "m4a": ["aac"],
                "ogg": ["libvorbis"], "opus": ["libopus"], "aiff": ["pcm_s16be"], "aif": ["pcm_s16be"],
            ]
            for ext in extensions {
                guard let required = requirements[ext] else { continue }
                if !required.allSatisfy({ encoderNames.contains($0) }) { extensions.remove(ext) }
            }
        }
        return extensions
    }
}

private enum ImageMagickCapabilities {
    static func extensions(from listing: String) -> (inputs: Set<String>, outputs: Set<String>) {
        var inputs = Set<String>()
        var outputs = Set<String>()
        let aliases: [String: [String]] = [
            "JPEG": ["jpg", "jpeg"], "JPG": ["jpg", "jpeg"], "PNG": ["png"], "WEBP": ["webp"],
            "HEIC": ["heic", "heif"], "TIFF": ["tif", "tiff"], "BMP": ["bmp"], "GIF": ["gif"],
            "AVIF": ["avif"], "ICO": ["ico"], "JP2": ["jp2"],
        ]
        for line in listing.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 3 else { continue }
            let name = String(columns[0]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            let mode = String(columns[2]).lowercased()
            guard let formats = aliases[name.uppercased()] else { continue }
            if mode.contains("r") { inputs.formUnion(formats) }
            if mode.contains("w") {
                // ImageMagick advertises SVG as writable even when its bitmap
                // vectorization delegate is absent. In that case `magick
                // input.png output.svg` fails at runtime, so keep the route
                // hidden until the required delegate is available.
                if !formats.contains("svg") || ExecutableLocator.resolve(["potrace"]) != nil {
                    outputs.formUnion(formats)
                }
            }
        }
        return (inputs, outputs)
    }
}

private enum PandocCapabilities {
    private static let extensionMap: [String: String] = [
        "md": "markdown", "markdown": "markdown", "txt": "plain", "html": "html", "htm": "html",
        "docx": "docx", "odt": "odt", "rtf": "rtf", "epub": "epub", "pptx": "pptx",
        "org": "org", "rst": "rst", "tex": "latex", "tsv": "tsv",
    ]

    static func extensions(inputs: String, outputs: String) -> (inputs: Set<String>, outputs: Set<String>) {
        let inputNames = Set(inputs.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let outputNames = Set(outputs.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let inputExtensions = Set(extensionMap.compactMap { inputNames.contains($0.value) ? $0.key : nil })
        let outputExtensions = Set(extensionMap.compactMap { outputNames.contains($0.value) ? $0.key : nil })
        return (inputExtensions, outputExtensions)
    }
}

private enum OfficeCapabilities {
    private static let textDocuments: Set<String> = ["doc", "docx", "odt", "rtf", "txt", "html"]
    private static let presentations: Set<String> = ["ppt", "pptx", "odp"]
    private static let spreadsheets: Set<String> = ["xls", "xlsx", "ods", "csv"]
    private static let cacheLock = NSLock()
    private static var probeCache: [String: (inputs: Set<String>, outputs: Set<String>)] = [:]
    private static let logger = Logger(subsystem: EngineRegistry.containingAppBundleIdentifier, category: "engine-capability-probe")

    static func outputs(for input: String) -> Set<String>? {
        if textDocuments.contains(input) { return textDocuments.union(["pdf"]) }
        if presentations.contains(input) { return presentations.union(["pdf"]) }
        if spreadsheets.contains(input) { return spreadsheets.union(["pdf"]) }
        return nil
    }

    static func probe(
        _ executable: URL,
        cancellation: CancellationToken?,
        forceRefresh: Bool
    ) -> (inputs: Set<String>, outputs: Set<String>) {
        guard cancellation?.isCancelled != true,
              let fingerprint = try? EngineExecutableTrust.fingerprint(for: executable) else { return ([], []) }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let cacheKey = "\(executable.standardizedFileURL.path)|\(fingerprint)|\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if !forceRefresh, let cached = probeCache[cacheKey] { return cached }
        let smokeTest = sandboxedConversionProbe(executable, cancellation: cancellation)
        guard cancellation?.isCancelled != true else { return ([], []) }
        guard smokeTest else {
            probeCache[cacheKey] = ([], [])
            return ([], [])
        }
        let inputs = textDocuments.union(presentations).union(spreadsheets)
        let outputs = inputs.union(["pdf"])
        probeCache[cacheKey] = (inputs, outputs)
        return (inputs, outputs)
    }

    private static func sandboxedConversionProbe(_ executable: URL, cancellation: CancellationToken?) -> Bool {
        do {
            let stage = try PrivateOutputStage(
                parentDirectory: FileManager.default.temporaryDirectory,
                primaryFileName: "morph-capability-probe.csv"
            )
            let input = try stage.temporaryOutputURL()
            let output = stage.directoryURL.appendingPathComponent("morph-capability-probe.xlsx")
            try Data("field,value\nMorph,1\n".utf8).write(to: input, options: [.atomic])
            try LibreOfficeEngine.convert(
                executable: executable,
                input: input,
                output: output,
                cancellation: cancellation ?? CancellationToken(),
                timeout: EngineProbeConfiguration.conversionTimeout
            )
            try ConversionOutputLimits.validate(output, maximumBytes: 16 * 1_024 * 1_024)
            let handle = try FileHandle(forReadingFrom: output)
            defer { try? handle.close() }
            let signature = try handle.read(upToCount: 4) ?? Data()
            guard signature.starts(with: [0x50, 0x4b]) else {
                logger.error("LibreOffice sandbox capability check returned an invalid XLSX package.")
                return false
            }
            return true
        } catch {
            guard cancellation?.isCancelled != true else { return false }
            logger.error("LibreOffice sandbox capability check failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}

enum ConversionCatalog {
    static let formats: [MorphFormat] = [
        MorphFormat("png", "PNG", .image), MorphFormat("jpg", "JPEG", .image), MorphFormat("jpeg", "JPEG", .image),
        MorphFormat("webp", "WebP", .image), MorphFormat("heic", "HEIC", .image), MorphFormat("heif", "HEIF", .image),
        MorphFormat("tiff", "TIFF", .image), MorphFormat("tif", "TIFF", .image), MorphFormat("bmp", "BMP", .image),
        MorphFormat("gif", "GIF", .image), MorphFormat("svg", "SVG", .image), MorphFormat("ico", "ICO", .image), MorphFormat("avif", "AVIF", .image),
        MorphFormat("mp4", "MP4", .video), MorphFormat("mov", "MOV", .video), MorphFormat("mkv", "MKV", .video),
        MorphFormat("webm", "WebM", .video), MorphFormat("avi", "AVI", .video), MorphFormat("gif", "GIF", .video),
        MorphFormat("mpeg", "MPEG", .video), MorphFormat("wmv", "WMV", .video), MorphFormat("flv", "FLV", .video),
        MorphFormat("mp3", "MP3", .audio), MorphFormat("wav", "WAV", .audio), MorphFormat("flac", "FLAC", .audio),
        MorphFormat("aac", "AAC", .audio), MorphFormat("m4a", "M4A", .audio), MorphFormat("ogg", "OGG", .audio),
        MorphFormat("opus", "Opus", .audio), MorphFormat("aiff", "AIFF", .audio), MorphFormat("wma", "WMA", .audio),
        MorphFormat("pdf", "PDF", .document), MorphFormat("docx", "Word document", .document), MorphFormat("doc", "Word 97–2003", .document),
        MorphFormat("odt", "OpenDocument text", .document), MorphFormat("rtf", "Rich Text", .document), MorphFormat("txt", "Plain text", .document),
        MorphFormat("html", "HTML", .document), MorphFormat("epub", "EPUB", .document), MorphFormat("md", "Markdown", .document),
        MorphFormat("pptx", "PowerPoint", .document), MorphFormat("ppt", "PowerPoint 97–2003", .document), MorphFormat("odp", "OpenDocument presentation", .document),
        MorphFormat("xlsx", "Excel workbook", .spreadsheet), MorphFormat("xls", "Excel 97–2003", .spreadsheet),
        MorphFormat("csv", "CSV", .spreadsheet), MorphFormat("tsv", "TSV", .spreadsheet), MorphFormat("ods", "OpenDocument spreadsheet", .spreadsheet),
        MorphFormat("json", "JSON", .spreadsheet), MorphFormat("xml", "XML", .spreadsheet), MorphFormat("yaml", "YAML", .spreadsheet), MorphFormat("yml", "YAML", .spreadsheet), MorphFormat("toml", "TOML", .spreadsheet),
        MorphFormat("zip", "ZIP archive", .archive), MorphFormat("7z", "7-Zip archive", .archive),
        MorphFormat("tar", "TAR archive", .archive), MorphFormat("tar.gz", "GZIP TAR archive", .archive),
        MorphFormat("tar.bz2", "BZIP2 TAR archive", .archive), MorphFormat("tar.xz", "XZ TAR archive", .archive),
        MorphFormat("gz", "GZIP stream", .archive), MorphFormat("bz2", "BZIP2 stream", .archive), MorphFormat("xz", "XZ stream", .archive), MorphFormat("rar", "RAR archive", .archive),
    ]

    static func buildRoutes(statuses: [EngineID: EngineStatus]) -> [ConversionRoute] {
        var result: [ConversionRoute] = []
        func add(_ source: String, _ output: String, _ engine: EngineID, _ note: String, category: FormatCategory? = nil) {
            guard let format = formats.first(where: { $0.fileExtension == output && (category == nil || $0.category == category!) }) else { return }
            guard statuses[engine]?.canConvert == true else { return }
            result.append(ConversionRoute(inputExtension: source, output: format, engine: engine, description: note))
        }

        let imageInputs = statuses[.nativeImage]?.supportedInputExtensions ?? []
        let imageOutputs = statuses[.nativeImage]?.supportedOutputExtensions ?? []
        for source in imageInputs {
            for output in imageOutputs where source != output {
                add(source, output, .nativeImage, "Convert using Apple ImageIO", category: .image)
            }
            add(source, "pdf", .nativePDF, "Create a PDF using Apple PDFKit")
        }

        let magickInputs = statuses[.imageMagick]?.supportedInputExtensions ?? []
        let magickOutputs = statuses[.imageMagick]?.supportedOutputExtensions ?? []
        for source in magickInputs {
            for output in magickOutputs where source != output {
                add(source, output, .imageMagick, "Convert using ImageMagick", category: .image)
            }
        }

        let mediaFormats = formats.filter { $0.category == .audio || $0.category == .video }
        let ffmpegInputs = statuses[.ffmpeg]?.supportedInputExtensions ?? []
        let ffmpegOutputs = statuses[.ffmpeg]?.supportedOutputExtensions ?? []
        let audioInputs: Set<String> = ["mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "aiff", "aif", "wma"]
        let videoInputs: Set<String> = ["mp4", "mov", "mkv", "webm", "avi", "gif", "mpeg", "mpg", "wmv", "flv", "3gp", "3g2"]
        for source in ffmpegInputs {
            let sourceIsAudio = audioInputs.contains(source)
            let sourceIsVideo = videoInputs.contains(source)
            guard sourceIsAudio || sourceIsVideo else { continue }
            let sourceCanContainAudio = sourceIsAudio || (sourceIsVideo && source != "gif")
            for format in mediaFormats where format.fileExtension != source && ffmpegOutputs.contains(format.fileExtension) {
                let outputIsAudio = format.category == .audio
                if outputIsAudio && !sourceCanContainAudio { continue }
                if !outputIsAudio && !sourceIsVideo { continue }
                guard let status = statuses[.ffmpeg], status.canConvert else { continue }
                let outputFormat = format.fileExtension == "gif" ? MorphFormat("gif", "GIF animation", .video) : format
                result.append(ConversionRoute(inputExtension: source, output: outputFormat, engine: .ffmpeg, description: "Convert using the installed FFmpeg build"))
            }
        }

        if statuses[.nativePDF]?.isInstalled == true {
            add("pdf", "txt", .nativePDF, "Extract PDF text using Apple PDFKit")
            result.append(ConversionRoute(
                inputExtension: "pdf",
                output: MorphFormat("zip", "PNG images", .archive),
                engine: .nativePDF,
                description: "Export PDF pages as PNG images; single-page PDFs produce one PNG"
            ))
        }

        let pandoc = statuses[.pandoc]
        if let pandoc, pandoc.canConvert {
            let documentFormats = formats.filter { $0.category == .document }
            for source in pandoc.supportedInputExtensions {
                for format in documentFormats where source != format.fileExtension && pandoc.supportedOutputExtensions.contains(format.fileExtension) {
                    result.append(ConversionRoute(inputExtension: source, output: format, engine: .pandoc, description: "Convert using Pandoc"))
                }
            }
        }

        if let office = statuses[.libreOffice], office.isInstalled {
            for source in office.supportedInputExtensions {
                guard let compatibleOutputs = OfficeCapabilities.outputs(for: source) else { continue }
                for output in compatibleOutputs where source != output && office.supportedOutputExtensions.contains(output) {
                    add(source, output, .libreOffice, "Convert using LibreOffice")
                }
            }
        }

        let structuredFormats = ["json", "yaml", "yml", "toml", "csv", "tsv"]
        for source in structuredFormats {
            for output in structuredFormats where source != output {
                add(source, output, .structuredData, "Convert structured data locally")
            }
        }
        for format in ["json", "yaml", "yml", "toml"] {
            add(format, "xml", .structuredData, "Convert structured data locally")
            add("xml", format, .structuredData, "Convert structured data locally")
        }

        if statuses[.archive]?.isInstalled == true {
            let archiveInputs = statuses[.archive]?.supportedInputExtensions ?? []
            let archiveOutputs = statuses[.archive]?.supportedOutputExtensions ?? []
            for source in archiveInputs {
                for output in archiveOutputs where source != output {
                    add(source, output, .archive, "Repackage with built-in macOS archive tools")
                }
            }
        }

        let sevenZip = statuses[.sevenZip]
        if let sevenZip, sevenZip.isInstalled {
            for input in sevenZip.supportedInputExtensions {
                for output in sevenZip.supportedOutputExtensions where input != output {
                    add(input, output, .sevenZip, "Convert with 7-Zip", category: .archive)
                }
            }
        }

        return Array(Set(result)).sorted {
            let firstPriority = enginePriority($0.engine)
            let secondPriority = enginePriority($1.engine)
            if firstPriority != secondPriority { return firstPriority < secondPriority }
            if $0.output.category.rawValue != $1.output.category.rawValue { return $0.output.category.rawValue < $1.output.category.rawValue }
            if $0.output.displayName != $1.output.displayName { return $0.output.displayName < $1.output.displayName }
            return $0.inputExtension < $1.inputExtension
        }
    }

    private static func enginePriority(_ id: EngineID) -> Int {
        switch id {
        case .nativeImage, .nativePDF, .structuredData, .archive: 0
        case .ffmpeg, .pandoc: 1
        case .imageMagick, .libvips, .ghostscript, .sevenZip, .libreOffice: 2
        }
    }
}

public struct FinderSyncPreferencesSnapshot: Codable, Sendable {
    public let registry: EngineRegistry
    public let hiddenOutputExtensions: Set<String>
    public let homeDirectoryPath: String

    public init(registry: EngineRegistry, hiddenOutputExtensions: Set<String>, homeDirectoryPath: String) {
        self.registry = registry
        self.hiddenOutputExtensions = Set(hiddenOutputExtensions.map { $0.lowercased() })
        self.homeDirectoryPath = homeDirectoryPath
    }
}

public extension EngineRegistry {
    func availableOutputs(for inputURL: URL) -> [ConversionRoute] {
        let known = Set(routes.map(\.inputExtension))
        guard let input = inputURL.morphExtension(knownExtensions: known) else { return [] }
        return routes.filter { $0.inputExtension == input }
    }

    func routes(from inputExtension: String, to outputExtension: String) -> [ConversionRoute] {
        let normalizedInput = inputExtension.lowercased()
        let normalizedOutput = outputExtension.lowercased()
        return routes.filter { $0.inputExtension == normalizedInput && $0.output.fileExtension == normalizedOutput }
    }
}
