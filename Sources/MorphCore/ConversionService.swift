import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct ConversionContext: Sendable {
    public let route: ConversionRoute
    public let request: ConversionRequest
    public let temporaryOutputURL: URL
    public let cancellation: CancellationToken

    public init(route: ConversionRoute, request: ConversionRequest, temporaryOutputURL: URL, cancellation: CancellationToken) {
        self.route = route
        self.request = request
        self.temporaryOutputURL = temporaryOutputURL
        self.cancellation = cancellation
    }
}

public protocol ConversionEngine: Sendable {
    var id: EngineID { get }
    func convert(context: ConversionContext) throws
}

public final class ConversionService {
    public let registry: EngineRegistry
    private let engines: [EngineID: any ConversionEngine]

    public init(registry: EngineRegistry, engines customEngines: [any ConversionEngine]? = nil) {
        self.registry = registry
        let adapters = Self.defaultEngines(for: registry) + (customEngines ?? [])
        self.engines = Dictionary(adapters.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
    }

    @discardableResult
    public func convert(_ request: ConversionRequest, cancellation: CancellationToken = CancellationToken()) throws -> ConversionResult {
        guard FileManager.default.fileExists(atPath: request.inputURL.path) else {
            throw MorphError.invalidInput("The selected file no longer exists.")
        }
        let knownExtensions = Set(registry.routes.map(\.inputExtension))
        guard let inputExtension = request.inputURL.morphExtension(knownExtensions: knownExtensions) else {
            throw MorphError.unsupportedInput(request.inputURL)
        }
        let candidateRoutes = registry.routes(from: inputExtension, to: request.outputFormat.fileExtension)
        guard !candidateRoutes.isEmpty else {
            throw MorphError.unsupportedConversion(inputExtension, request.outputFormat.fileExtension)
        }
        let runnableRoutes = candidateRoutes.filter { registry.isAvailable($0.engine) }
        guard !runnableRoutes.isEmpty else { throw MorphError.missingEngine(candidateRoutes[0].engine) }
        if cancellation.isCancelled { throw MorphError.cancelled }

        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let finalURL = uniqueOutputURL(for: request, knownExtensions: knownExtensions)
        var lastFailure: String?
        for route in runnableRoutes {
            guard let engine = engines[route.engine] else {
                lastFailure = "No conversion adapter is registered for \(route.engine.displayName)."
                continue
            }
            let stagingDirectory = request.outputDirectory.appendingPathComponent(".morph-\(UUID().uuidString).staging", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
            } catch {
                lastFailure = "Morph could not create a safe staging folder: \(error.localizedDescription)"
                continue
            }
            defer { try? FileManager.default.removeItem(at: stagingDirectory) }
            let temporaryURL = stagingDirectory.appendingPathComponent("output.partial.\(request.outputFormat.fileExtension)")
            let context = ConversionContext(route: route, request: request, temporaryOutputURL: temporaryURL, cancellation: cancellation)
            do {
                try engine.convert(context: context)
                if cancellation.isCancelled { throw MorphError.cancelled }
                try OutputValidator.validate(temporaryURL, format: request.outputFormat, engine: route.engine)
                do { try FileManager.default.moveItem(at: temporaryURL, to: finalURL) }
                catch { throw MorphError.processFailed("Morph could not safely save the output: \(error.localizedDescription)") }
                return ConversionResult(inputURL: request.inputURL, outputURL: finalURL, engine: route.engine, completedAt: Date())
            } catch {
                if cancellation.isCancelled { throw MorphError.cancelled }
                if let morphError = error as? MorphError, case .cancelled = morphError { throw MorphError.cancelled }
                lastFailure = "\(route.engine.displayName): \(error.localizedDescription)"
            }
        }
        if let lastFailure { throw MorphError.processFailed("All available conversion engines failed. \(lastFailure)") }
        throw MorphError.processFailed("Morph could not run this conversion with the registered engines.")
    }

    private func uniqueOutputURL(for request: ConversionRequest, knownExtensions: Set<String>) -> URL {
        let sourceName = request.inputURL.lastPathComponent
        let matchedExtension = request.inputURL.morphExtension(knownExtensions: knownExtensions) ?? request.inputURL.pathExtension.lowercased()
        let baseName: String
        if matchedExtension.isEmpty {
            baseName = request.inputURL.deletingPathExtension().lastPathComponent
        } else if sourceName.lowercased().hasSuffix(".\(matchedExtension)") {
            baseName = String(sourceName.dropLast(matchedExtension.count + 1))
        } else {
            baseName = request.inputURL.deletingPathExtension().lastPathComponent
        }
        let ext = request.outputFormat.fileExtension
        var candidate = request.outputDirectory.appendingPathComponent("\(baseName).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = request.outputDirectory.appendingPathComponent("\(baseName)-\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }

    private static func defaultEngines(for registry: EngineRegistry) -> [any ConversionEngine] {
        var adapters: [any ConversionEngine] = [
            NativeImageConversionEngine(), NativePDFConversionEngine(), StructuredDataConversionEngine(), ArchiveConversionEngine(),
        ]
        func add(_ id: EngineID, _ factory: (URL) -> any ConversionEngine) {
            if let executable = registry.status(for: id)?.executableURL { adapters.append(factory(executable)) }
        }
        add(.ffmpeg) { FFmpegConversionEngine(executable: $0) }
        add(.imageMagick) { ImageMagickConversionEngine(executable: $0) }
        add(.pandoc) { PandocConversionEngine(executable: $0) }
        add(.poppler) { PopplerConversionEngine(executable: $0) }
        add(.sevenZip) { SevenZipConversionEngine(executable: $0) }
        add(.libreOffice) { LibreOfficeConversionAdapter(executable: $0) }
        return adapters
    }
}

public struct NativeImageConversionEngine: ConversionEngine {
    public let id: EngineID = .nativeImage
    public init() {}
    public func convert(context: ConversionContext) throws {
        try NativeImageEngine.convert(input: context.request.inputURL, output: context.temporaryOutputURL, quality: context.request.imageQuality)
    }
}

public struct NativePDFConversionEngine: ConversionEngine {
    public let id: EngineID = .nativePDF
    public init() {}
    public func convert(context: ConversionContext) throws {
        try NativePDFEngine.imageToPDF(input: context.request.inputURL, output: context.temporaryOutputURL)
    }
}

public struct StructuredDataConversionEngine: ConversionEngine {
    public let id: EngineID = .structuredData
    public init() {}
    public func convert(context: ConversionContext) throws {
        try StructuredDataEngine.convert(input: context.request.inputURL, output: context.temporaryOutputURL)
    }
}

public struct ArchiveConversionEngine: ConversionEngine {
    public let id: EngineID = .archive
    public init() {}
    public func convert(context: ConversionContext) throws {
        try ArchiveEngine.convert(input: context.request.inputURL, output: context.temporaryOutputURL, cancellation: context.cancellation)
    }
}

public struct SevenZipConversionEngine: ConversionEngine {
    public let id: EngineID = .sevenZip
    private let executable: URL

    public init(executable: URL) { self.executable = executable }

    public func convert(context: ConversionContext) throws {
        try SevenZipArchiveEngine.convert(
            executable: executable,
            input: context.request.inputURL,
            output: context.temporaryOutputURL,
            cancellation: context.cancellation
        )
    }
}

public struct FFmpegConversionEngine: ConversionEngine {
    public let id: EngineID = .ffmpeg
    private let executable: URL
    public init(executable: URL) { self.executable = executable }
    public func convert(context: ConversionContext) throws {
        try FFmpegEngine.convert(executable: executable, input: context.request.inputURL, output: context.temporaryOutputURL, cancellation: context.cancellation)
    }
}

public struct ImageMagickConversionEngine: ConversionEngine {
    public let id: EngineID = .imageMagick
    private let executable: URL
    public init(executable: URL) { self.executable = executable }
    public func convert(context: ConversionContext) throws {
        try ImageMagickEngine.convert(executable: executable, input: context.request.inputURL, output: context.temporaryOutputURL, quality: context.request.imageQuality, cancellation: context.cancellation)
    }
}

public struct PandocConversionEngine: ConversionEngine {
    public let id: EngineID = .pandoc
    private let executable: URL
    public init(executable: URL) { self.executable = executable }
    public func convert(context: ConversionContext) throws {
        try PandocEngine.convert(executable: executable, input: context.request.inputURL, output: context.temporaryOutputURL, cancellation: context.cancellation)
    }
}

public struct PopplerConversionEngine: ConversionEngine {
    public let id: EngineID = .poppler
    private let executable: URL
    public init(executable: URL) { self.executable = executable }
    public func convert(context: ConversionContext) throws {
        try PopplerEngine.convert(executable: executable, input: context.request.inputURL, output: context.temporaryOutputURL, cancellation: context.cancellation)
    }
}

public struct LibreOfficeConversionAdapter: ConversionEngine {
    public let id: EngineID = .libreOffice
    private let executable: URL
    public init(executable: URL) { self.executable = executable }
    public func convert(context: ConversionContext) throws {
        try LibreOfficeEngine.convert(executable: executable, input: context.request.inputURL, output: context.temporaryOutputURL, cancellation: context.cancellation)
    }
}

public enum NativeImageEngine {
    public static func convert(input: URL, output: URL, quality: Double) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MorphError.invalidInput("macOS could not decode this image.")
        }
        guard let outputType = UTType(filenameExtension: output.pathExtension),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, outputType.identifier as CFString, 1, nil) else {
            throw MorphError.invalidOutput("macOS cannot write this image format.")
        }

        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var properties = sourceProperties
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MorphError.invalidOutput("ImageIO could not finish writing the image.")
        }
    }
}

public enum NativePDFEngine {
    public static func imageToPDF(input: URL, output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else {
            throw MorphError.invalidInput("macOS could not decode this image as a PDF page.")
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: output) else { throw MorphError.invalidOutput("PDFKit could not write the PDF.") }
    }
}

public enum ImageMagickEngine {
    public static func convert(executable: URL, input: URL, output: URL, quality: Double, cancellation: CancellationToken) throws {
        var arguments = [input.path]
        if output.pathExtension.lowercased() == "ico" {
            arguments += ["-resize", "256x256>", "-define", "icon:auto-resize=256,128,64,48,32,16"]
        }
        arguments += ["-quality", String(Int((quality * 100).rounded())), output.path]
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            cancellation: cancellation
        )
        guard result.status == 0 else { throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

public enum FFmpegEngine {
    public static func convert(executable: URL, input: URL, output: URL, cancellation: CancellationToken) throws {
        let ext = output.pathExtension.lowercased()
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", input.path, "-map_metadata", "0"]

        switch ext {
        case "mp3": arguments += ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "wav": arguments += ["-vn", "-c:a", "pcm_s16le"]
        case "flac": arguments += ["-vn", "-c:a", "flac"]
        case "aac": arguments += ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "m4a": arguments += ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "ogg": arguments += ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case "opus": arguments += ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "aiff", "aif": arguments += ["-vn", "-c:a", "pcm_s16be"]
        case "mp4", "mov": arguments += ["-c:v", "libx264", "-preset", "medium", "-crf", "22", "-c:a", "aac", "-b:a", "192k"]
        case "webm": arguments += ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]
        case "mkv": arguments += ["-c:v", "libx264", "-preset", "medium", "-crf", "22", "-c:a", "aac"]
        case "avi": arguments += ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "libmp3lame", "-q:a", "3"]
        case "gif": arguments += ["-vf", "fps=12,scale=640:-1:flags=lanczos", "-an", "-loop", "0"]
        case "mpeg", "mpg": arguments += ["-c:v", "mpeg2video", "-q:v", "5", "-c:a", "mp2"]
        case "wmv": arguments += ["-c:v", "wmv2", "-c:a", "wmav2"]
        case "flv": arguments += ["-c:v", "flv", "-c:a", "aac"]
        default: throw MorphError.unsupportedConversion(input.pathExtension, ext)
        }

        if ext == "mp4" { arguments += ["-movflags", "+faststart"] }
        arguments.append(output.path)
        let result = try ProcessRunner.run(executable: executable, arguments: arguments, cancellation: cancellation)
        guard result.status == 0 else { throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

public enum PandocEngine {
    private static let formatNames: [String: String] = [
        "md": "markdown", "markdown": "markdown", "txt": "plain", "html": "html", "htm": "html",
        "docx": "docx", "odt": "odt", "rtf": "rtf", "epub": "epub", "pptx": "pptx", "xlsx": "xlsx",
        "org": "org", "rst": "rst", "tex": "latex", "json": "json", "xml": "xml", "tsv": "tsv",
    ]

    public static func convert(executable: URL, input: URL, output: URL, cancellation: CancellationToken) throws {
        guard let inputFormat = formatNames[input.pathExtension.lowercased()],
              let outputFormat = formatNames[output.pathExtension.lowercased()] else {
            throw MorphError.unsupportedConversion(input.pathExtension, output.pathExtension)
        }
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: ["--from=\(inputFormat)", "--to=\(outputFormat)", "--output=\(output.path)", input.path],
            cancellation: cancellation
        )
        guard result.status == 0 else { throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

public enum PopplerEngine {
    public static func convert(executable: URL, input: URL, output: URL, cancellation: CancellationToken) throws {
        let result = try ProcessRunner.run(executable: executable, arguments: ["-layout", input.path, output.path], cancellation: cancellation)
        guard result.status == 0 else { throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

public enum LibreOfficeEngine {
    public static func convert(executable: URL, input: URL, output: URL, cancellation: CancellationToken) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("morph-office-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let profile = temporaryDirectory.appendingPathComponent("profile", isDirectory: true)
        let profileURL = URL(fileURLWithPath: profile.path, isDirectory: true).absoluteString
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: ["-env:UserInstallation=\(profileURL)", "--headless", "--convert-to", output.pathExtension, "--outdir", temporaryDirectory.path, input.path],
            cancellation: cancellation
        )
        guard result.status == 0 else { throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let produced = temporaryDirectory.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension(output.pathExtension)
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw MorphError.invalidOutput("LibreOffice reported success but did not create the requested output.")
        }
        do { try FileManager.default.moveItem(at: produced, to: output) }
        catch { throw MorphError.processFailed("Could not stage the LibreOffice output: \(error.localizedDescription)") }
    }
}

public enum ArchiveEngine {
    public static func convert(input: URL, output: URL, cancellation: CancellationToken) throws {
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("morph-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let inputExt = archiveExtension(for: input)
        guard ["zip", "tar.gz"].contains(inputExt) else {
            throw MorphError.unsupportedConversion(inputExt, output.pathExtension)
        }
        try extract(input: input, to: workDirectory, cancellation: cancellation)

        guard let tar = ExecutableLocator.resolve(["tar"]),
              let zip = ExecutableLocator.resolve(["zip"]) else {
            throw MorphError.processFailed("Required macOS ZIP or TAR creation tools are unavailable.")
        }

        if output.pathExtension.lowercased() == "zip" {
            let result = try ProcessRunner.run(executable: zip, arguments: ["-qr", output.path, "."], currentDirectory: workDirectory, cancellation: cancellation)
            guard result.status == 0 else { throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } else if output.lastPathComponent.lowercased().hasSuffix(".tar.gz") {
            let result = try ProcessRunner.run(executable: tar, arguments: ["-czf", output.path, "-C", workDirectory.path, "."], cancellation: cancellation)
            guard result.status == 0 else { throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } else {
            throw MorphError.unsupportedConversion(input.pathExtension, output.pathExtension)
        }
    }

    static func extract(input: URL, to directory: URL, cancellation: CancellationToken) throws {
        let inputExt = archiveExtension(for: input)
        if inputExt == "zip" {
            guard let unzip = ExecutableLocator.resolve(["unzip"]),
                  let ditto = ExecutableLocator.resolve(["ditto"]) else {
                throw MorphError.processFailed("Required macOS ZIP extraction tools are unavailable.")
            }
            let listing = try ProcessRunner.run(executable: unzip, arguments: ["-Z1", input.path], cancellation: cancellation)
            guard listing.status == 0 else { throw MorphError.invalidInput("The ZIP directory could not be read.") }
            try validateArchivePaths(listing.stdout)
            let extracted = try ProcessRunner.run(executable: ditto, arguments: ["-x", "-k", input.path, directory.path], cancellation: cancellation)
            guard extracted.status == 0 else { throw MorphError.invalidInput(extracted.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } else if inputExt == "tar.gz" {
            guard let tar = ExecutableLocator.resolve(["tar"]) else {
                throw MorphError.processFailed("The macOS TAR tool is unavailable.")
            }
            let listing = try ProcessRunner.run(executable: tar, arguments: ["-tzf", input.path], cancellation: cancellation)
            guard listing.status == 0 else { throw MorphError.invalidInput("The TAR.GZ directory could not be read.") }
            try validateArchivePaths(listing.stdout)
            let extracted = try ProcessRunner.run(executable: tar, arguments: ["-xzf", input.path, "-C", directory.path, "--no-same-owner"], cancellation: cancellation)
            guard extracted.status == 0 else { throw MorphError.invalidInput(extracted.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } else {
            throw MorphError.unsupportedConversion(inputExt, "archive contents")
        }
        try ensureExtractedItemsStayInside(directory)
    }

    static func archiveExtension(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "tar.gz" }
        if name.hasSuffix(".zip") { return "zip" }
        if name.hasSuffix(".7z") { return "7z" }
        return url.pathExtension.lowercased()
    }

    static func validateArchivePaths(_ listing: String) throws {
        for rawPath in listing.split(separator: "\n") {
            let path = String(rawPath).replacingOccurrences(of: "\\", with: "/")
            let hasWindowsDrivePrefix = path.range(of: "^[A-Za-z]:/", options: .regularExpression) != nil
            if path.hasPrefix("/") || hasWindowsDrivePrefix || path.split(separator: "/").contains("..") {
                throw MorphError.invalidInput("The archive contains a path that escapes its extraction folder.")
            }
        }
    }

    static func ensureExtractedItemsStayInside(_ directory: URL) throws {
        let root = directory.standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let item as URL in enumerator {
            let resolved = item.standardizedFileURL.resolvingSymlinksInPath().path
            if !resolved.hasPrefix(root) && resolved != directory.standardizedFileURL.path {
                throw MorphError.invalidInput("The archive contains a link that escapes its extraction folder.")
            }
        }
    }
}

enum SevenZipArchiveEngine {
    static func convert(executable: URL, input: URL, output: URL, cancellation: CancellationToken) throws {
        let inputExtension = ArchiveEngine.archiveExtension(for: input)
        guard ["7z", "zip"].contains(inputExtension) else {
            throw MorphError.unsupportedConversion(inputExtension, output.pathExtension)
        }
        let outputExtension = output.pathExtension.lowercased()
        guard ["7z", "zip"].contains(outputExtension) else {
            throw MorphError.unsupportedConversion(inputExtension, outputExtension)
        }

        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("morph-7zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        if inputExtension == "7z" {
            try validateSevenZipListing(executable: executable, input: input, cancellation: cancellation)
            let extracted = try ProcessRunner.run(
                executable: executable,
                arguments: ["x", "-y", "-o\(workDirectory.path)", input.path],
                cancellation: cancellation
            )
            guard extracted.status == 0 else {
                throw MorphError.invalidInput(extracted.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try ArchiveEngine.ensureExtractedItemsStayInside(workDirectory)
        } else {
            try ArchiveEngine.extract(input: input, to: workDirectory, cancellation: cancellation)
        }

        let type = outputExtension == "7z" ? "7z" : "zip"
        let created = try ProcessRunner.run(
            executable: executable,
            arguments: ["a", "-t\(type)", output.path, "."],
            currentDirectory: workDirectory,
            cancellation: cancellation
        )
        guard created.status == 0 else {
            throw MorphError.processFailed(created.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func validateSevenZipListing(executable: URL, input: URL, cancellation: CancellationToken) throws {
        let listing = try ProcessRunner.run(
            executable: executable,
            arguments: ["l", "-slt", "-sccUTF-8", input.path],
            cancellation: cancellation
        )
        guard listing.status == 0 else { throw MorphError.invalidInput("The 7-Zip archive directory could not be read.") }
        try validateListingText(listing.stdout)
    }

    static func validateListingText(_ listing: String) throws {
        var readingEntries = false
        var currentEntry: [String] = []
        var entries: [[String]] = []
        for line in listing.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "----------" {
                if !currentEntry.isEmpty { entries.append(currentEntry); currentEntry = [] }
                readingEntries = true
            } else if readingEntries && line.isEmpty {
                if !currentEntry.isEmpty { entries.append(currentEntry); currentEntry = [] }
            } else if readingEntries {
                currentEntry.append(line)
            }
        }
        if !currentEntry.isEmpty { entries.append(currentEntry) }

        for entry in entries {
            var path: String?
            for field in entry {
                guard let separator = field.firstIndex(of: "=") else {
                    throw MorphError.invalidInput("The 7-Zip directory could not be parsed safely.")
                }
                let key = field[..<separator].trimmingCharacters(in: .whitespaces)
                let value = field[field.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                if key == "Path" { path = value }
                if key == "Symbolic Link" || key == "Hard Link" || (key == "Attributes" && value.uppercased().contains("L")) {
                    throw MorphError.invalidInput("Archives containing symbolic or hard links cannot be converted safely.")
                }
            }
            guard let path, !path.isEmpty else {
                throw MorphError.invalidInput("The 7-Zip directory did not provide a safe path for every entry.")
            }
            try ArchiveEngine.validateArchivePaths(path)
        }
    }
}

public enum OutputValidator {
    public static func validate(_ url: URL, format: MorphFormat, engine: EngineID) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw MorphError.invalidOutput("The output file is missing or empty.")
        }
        switch format.category {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                throw MorphError.invalidOutput("macOS could not decode the generated image.")
            }
        case .document where format.fileExtension == "pdf":
            guard PDFDocument(url: url) != nil else { throw MorphError.invalidOutput("PDFKit could not open the generated PDF.") }
        case .spreadsheet where format.fileExtension == "json":
            guard let data = try? Data(contentsOf: url), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
                throw MorphError.invalidOutput("The generated JSON is not valid.")
            }
        case .spreadsheet where format.fileExtension == "xml":
            guard let data = try? Data(contentsOf: url) else { throw MorphError.invalidOutput("The XML output could not be read.") }
            let parser = XMLParser(data: data)
            let checker = XMLValidityChecker()
            parser.shouldResolveExternalEntities = false
            parser.delegate = checker
            guard parser.parse() else { throw MorphError.invalidOutput("The generated XML is not valid.") }
        case .spreadsheet where ["yaml", "yml", "toml"].contains(format.fileExtension):
            try StructuredDataEngine.validateGeneratedOutput(url, extension: format.fileExtension)
        case .archive:
            try validateArchive(url, format: format, engine: engine)
        case .audio, .video:
            try validateMedia(url)
        default:
            break
        }

        if [.pandoc, .libreOffice].contains(engine) && ["docx", "odt", "epub", "pptx", "xlsx"].contains(format.fileExtension) {
            guard let unzip = ExecutableLocator.resolve(["unzip"]) else { return }
            let result = try ProcessRunner.run(executable: unzip, arguments: ["-t", url.path])
            guard result.status == 0 else { throw MorphError.invalidOutput("The generated Office or EPUB package failed its ZIP integrity check.") }
        }
    }

    private static func validateArchive(_ url: URL, format: MorphFormat, engine: EngineID) throws {
        let outputExt = format.fileExtension
        if engine == .sevenZip {
            guard let executable = ExecutableLocator.resolve(["7zz", "7z"]) else {
                throw MorphError.invalidOutput("7-Zip is unavailable to validate this archive.")
            }
            let result = try ProcessRunner.run(executable: executable, arguments: ["t", url.path])
            guard result.status == 0 else { throw MorphError.invalidOutput("The generated archive failed its 7-Zip integrity check.") }
            return
        }
        let executable = outputExt == "zip" ? ExecutableLocator.resolve(["unzip"]) : ExecutableLocator.resolve(["tar"])
        guard let executable else { throw MorphError.invalidOutput("No archive validation tool is available.") }
        let result = outputExt == "zip"
            ? try ProcessRunner.run(executable: executable, arguments: ["-t", url.path])
            : try ProcessRunner.run(executable: executable, arguments: ["-tzf", url.path])
        guard result.status == 0 else { throw MorphError.invalidOutput("The generated archive failed its integrity check.") }
    }

    private static func validateMedia(_ url: URL) throws {
        guard let ffprobe = ExecutableLocator.resolve(["ffprobe"]) else { return }
        let result = try ProcessRunner.run(executable: ffprobe, arguments: ["-v", "error", "-show_entries", "format=format_name", "-of", "default=noprint_wrappers=1:nokey=1", url.path])
        guard result.status == 0, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MorphError.invalidOutput("FFprobe could not validate the generated media.")
        }
    }
}

private final class XMLValidityChecker: NSObject, XMLParserDelegate {
    var hasError = false
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { hasError = true }
}
