import Foundation
import Darwin
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct ConversionContext: Sendable {
    public let route: ConversionRoute
    /// The output directory exposed to an engine is its private workspace. The
    /// service alone owns the user-selected destination and final publication.
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

        // Pin the user-selected bytes before parsing them or giving them to an
        // external engine. Output naming still uses the original source URL.
        let inputSnapshot = try PrivateInputSnapshot(
            input: request.inputURL,
            fileExtension: inputExtension,
            maximumBytes: inputExtension == "pdf" ? NativePDFEngine.maximumPDFInputBytes : PrivateInputSnapshot.maximumInputBytes,
            cancellation: cancellation
        )

        let nativeImageInputs = registry.status(for: .nativeImage)?.supportedInputExtensions ?? []
        if nativeImageInputs.contains(inputExtension) {
            try NativeImageEngine.validateInput(inputSnapshot.fileURL)
            if let source = CGImageSourceCreateWithURL(inputSnapshot.fileURL as CFURL, nil) {
                try NativeImageEngine.validateSourceFrames(source, cancellation: cancellation)
                if request.outputFormat.category == .image,
                   CGImageSourceGetCount(source) > 1,
                   !["gif", "tif", "tiff"].contains(request.outputFormat.fileExtension.lowercased()) {
                    throw MorphError.invalidInput("This image contains multiple frames or pages. Convert it to GIF or TIFF to preserve every frame.")
                }
            }
        }

        let isPDFPageImages = inputExtension == "pdf" && request.outputFormat.fileExtension == "zip" && candidateRoutes.contains {
            $0.engine == .nativePDF && $0.output.fileExtension == "zip"
        }
        let isSinglePageImage: Bool
        if isPDFPageImages {
            try NativePDFEngine.validateInput(inputSnapshot.fileURL)
            guard let document = PDFDocument(url: inputSnapshot.fileURL) else {
                throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
            }
            try NativePDFEngine.validatePageCount(document.pageCount)
            isSinglePageImage = document.pageCount == 1
        } else {
            isSinglePageImage = false
        }
        let outputFormat = isSinglePageImage ? MorphFormat("png", "PNG image", .image) : request.outputFormat
        let effectiveRequest = ConversionRequest(
            inputURL: request.inputURL,
            outputFormat: outputFormat,
            outputDirectory: request.outputDirectory,
            imageQuality: request.imageQuality,
            stripLocationMetadata: request.stripLocationMetadata
        )

        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let finalURL = uniqueOutputURL(for: effectiveRequest, knownExtensions: knownExtensions)
        let destinationStage = try PrivateOutputStage(outputURL: finalURL)
        let temporaryName = "output.partial.\(outputFormat.fileExtension)"
        var lastFailure: String?
        for route in runnableRoutes {
            guard let engine = engines[route.engine] else {
                lastFailure = "No conversion adapter is registered for \(route.engine.displayName)."
                continue
            }
            guard destinationStage.outputDirectoryStillMatches(for: finalURL) else {
                throw MorphError.invalidOutput("The selected output folder moved before conversion began. Choose it again and retry.")
            }
            let staging = try PrivateOutputStage(
                parentDirectory: FileManager.default.temporaryDirectory,
                primaryFileName: temporaryName
            )
            let temporaryURL = try staging.temporaryOutputURL()
            let engineRequest = ConversionRequest(
                inputURL: inputSnapshot.fileURL,
                outputFormat: outputFormat,
                outputDirectory: staging.directoryURL,
                imageQuality: effectiveRequest.imageQuality,
                stripLocationMetadata: effectiveRequest.stripLocationMetadata
            )
            let context = ConversionContext(route: route, request: engineRequest, temporaryOutputURL: temporaryURL, cancellation: cancellation)
            do {
                try engine.convert(context: context)
                if cancellation.isCancelled { throw MorphError.cancelled }
                guard staging.stagedFileStillMatchesPath(named: temporaryName, url: temporaryURL) else {
                    throw MorphError.invalidOutput("The private conversion workspace changed while the engine was running.")
                }
                try ConversionOutputLimits.validate(temporaryURL)
                guard destinationStage.outputDirectoryStillMatches(for: finalURL) else {
                    throw MorphError.invalidOutput("The selected output folder moved during conversion. Choose it again and retry.")
                }
                try OutputValidator.validate(temporaryURL, format: outputFormat, engine: route.engine, cancellation: cancellation)
                if cancellation.isCancelled { throw MorphError.cancelled }
                guard staging.stagedFileStillMatchesPath(named: temporaryName, url: temporaryURL),
                      destinationStage.outputDirectoryStillMatches(for: finalURL) else {
                    throw MorphError.invalidOutput("The conversion workspace or selected output folder changed before Morph could publish the result.")
                }
                if inputExtension != "pdf",
                   route.output.category == .image,
                   let source = CGImageSourceCreateWithURL(inputSnapshot.fileURL as CFURL, nil),
                   CGImageSourceGetCount(source) > 1,
                   let generated = CGImageSourceCreateWithURL(temporaryURL as CFURL, nil),
                   CGImageSourceGetCount(generated) != CGImageSourceGetCount(source) {
                    throw MorphError.invalidOutput("The selected engine did not preserve every image frame or page.")
                }
            } catch {
                if cancellation.isCancelled { throw MorphError.cancelled }
                if let morphError = error as? MorphError, case .cancelled = morphError { throw MorphError.cancelled }
                if !destinationStage.outputDirectoryStillMatches(for: finalURL) {
                    throw MorphError.invalidOutput("The selected output folder moved during conversion. Choose it again and retry.")
                }
                lastFailure = "\(route.engine.displayName): \(error.localizedDescription)"
                continue
            }
            try destinationStage.copyValidatedFile(
                named: temporaryName,
                from: staging,
                to: temporaryName,
                for: finalURL,
                cancellation: cancellation
            )
            let publishedURL = try destinationStage.publishUnique(fileName: temporaryName, to: finalURL)
            return ConversionResult(inputURL: request.inputURL, outputURL: publishedURL, engine: route.engine, completedAt: Date())
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
            guard registry.isAvailable(id), let executable = ExecutableLocator.resolveEngine(id) else { return }
            adapters.append(factory(executable))
        }
        add(.ffmpeg) { FFmpegConversionEngine(executable: $0) }
        add(.imageMagick) { ImageMagickConversionEngine(executable: $0) }
        add(.pandoc) { PandocConversionEngine(executable: $0) }
        add(.sevenZip) { SevenZipConversionEngine(executable: $0) }
        add(.libreOffice) { LibreOfficeConversionAdapter(executable: $0) }
        return adapters
    }
}

public struct NativeImageConversionEngine: ConversionEngine {
    public let id: EngineID = .nativeImage
    public init() {}
    public func convert(context: ConversionContext) throws {
        try NativeImageEngine.convert(
            input: context.request.inputURL,
            output: context.temporaryOutputURL,
            quality: context.request.imageQuality,
            stripLocationMetadata: context.request.stripLocationMetadata,
            cancellation: context.cancellation
        )
    }
}

public struct NativePDFConversionEngine: ConversionEngine {
    public let id: EngineID = .nativePDF
    public init() {}
    public func convert(context: ConversionContext) throws {
        if context.route.inputExtension == "pdf", context.route.output.fileExtension == "zip" {
            if context.temporaryOutputURL.pathExtension.lowercased() == "png" {
                try NativePDFEngine.singlePageToPNG(
                    input: context.request.inputURL,
                    output: context.temporaryOutputURL,
                    cancellation: context.cancellation
                )
            } else {
                try NativePDFEngine.pagesToPNGZip(
                    input: context.request.inputURL,
                    output: context.temporaryOutputURL,
                    cancellation: context.cancellation
                )
            }
        } else if context.route.inputExtension == "pdf", context.route.output.fileExtension == "txt" {
            try NativePDFEngine.extractText(
                input: context.request.inputURL,
                output: context.temporaryOutputURL,
                cancellation: context.cancellation
            )
        } else {
            try NativePDFEngine.imageToPDF(
                input: context.request.inputURL,
                output: context.temporaryOutputURL,
                cancellation: context.cancellation
            )
        }
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
        try ArchiveExtractor.repackage(input: context.request.inputURL, output: context.temporaryOutputURL, cancellation: context.cancellation)
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
        try FFmpegEngine.convert(
            executable: executable,
            input: context.request.inputURL,
            output: context.temporaryOutputURL,
            cancellation: context.cancellation,
            stripLocationMetadata: context.request.stripLocationMetadata
        )
    }
}

public struct ImageMagickConversionEngine: ConversionEngine {
    public let id: EngineID = .imageMagick
    private let executable: URL
    public init(executable: URL) { self.executable = executable }
    public func convert(context: ConversionContext) throws {
        try ImageMagickEngine.convert(
            executable: executable,
            input: context.request.inputURL,
            output: context.temporaryOutputURL,
            quality: context.request.imageQuality,
            cancellation: context.cancellation,
            stripLocationMetadata: context.request.stripLocationMetadata
        )
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

public struct LibreOfficeConversionAdapter: ConversionEngine {
    public let id: EngineID = .libreOffice
    private let executable: URL
    public init(executable: URL) { self.executable = executable }
    public func convert(context: ConversionContext) throws {
        try LibreOfficeEngine.convert(executable: executable, input: context.request.inputURL, output: context.temporaryOutputURL, cancellation: context.cancellation)
    }
}

enum ConversionOutputLimits {
    static let maximumGeneratedBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024

    static func validate(_ url: URL, maximumBytes: UInt64 = maximumGeneratedBytes) throws {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw MorphError.invalidOutput("Morph could not safely open the generated output.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0,
              UInt64(info.st_size) <= maximumBytes else {
            throw MorphError.invalidOutput("Generated files must be regular files no larger than Morph's output limit.")
        }
    }
}

enum NativeMediaLimits {
    static let maximumOutputBytes = ConversionOutputLimits.maximumGeneratedBytes

    static func validate(_ url: URL) throws {
        try ConversionOutputLimits.validate(url)
    }
}

public enum NativeImageEngine {
    static let maximumInputBytes: UInt64 = 512 * 1_024 * 1_024
    static let maximumFrameCount = 250
    static let maximumFramePixels: UInt64 = 32_000_000
    static let maximumTotalFramePixels: UInt64 = 256_000_000

    static func validateInput(_ input: URL) throws {
        let descriptor = input.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw MorphError.invalidInput("The image is not a readable regular file.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0,
              UInt64(info.st_size) <= maximumInputBytes else {
            throw MorphError.invalidInput("Image inputs must be regular files no larger than 512 MB.")
        }
        guard let expectedType = supportedType(for: input.pathExtension),
              let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let actualIdentifier = CGImageSourceGetType(source) as String?,
              actualIdentifier == expectedType.identifier else {
            throw MorphError.invalidInput("The file contents do not match the selected image format.")
        }
    }

    private static func supportedType(for fileExtension: String) -> UTType? {
        let supportedExtensions: Set<String> = [
            "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
        ]
        let normalized = fileExtension.lowercased()
        guard supportedExtensions.contains(normalized) else { return nil }
        return UTType(filenameExtension: normalized)
    }

    static func validateFramePixelCounts(_ pixelCounts: [UInt64]) throws {
        guard !pixelCounts.isEmpty, pixelCounts.count <= maximumFrameCount else {
            throw MorphError.invalidInput("Animated images are limited to 250 frames per conversion.")
        }
        var totalPixels: UInt64 = 0
        for count in pixelCounts {
            guard count > 0, count <= maximumFramePixels,
                  totalPixels <= maximumTotalFramePixels - count else {
                throw MorphError.invalidInput("Images are limited to 32 million pixels per frame and 256 million pixels total.")
            }
            totalPixels += count
        }
    }

    static func validateSourceFrames(_ source: CGImageSource, cancellation: CancellationToken? = nil) throws {
        let imageCount = CGImageSourceGetCount(source)
        guard imageCount > 0 else { throw MorphError.invalidInput("macOS could not decode an image frame.") }
        guard imageCount <= maximumFrameCount else {
            throw MorphError.invalidInput("Animated images are limited to 250 frames per conversion.")
        }
        var framePixelCounts: [UInt64] = []
        framePixelCounts.reserveCapacity(imageCount)
        for index in 0..<imageCount {
            if cancellation?.isCancelled == true { throw MorphError.cancelled }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.int64Value > 0, height.int64Value > 0 else {
                throw MorphError.invalidInput("macOS could not safely inspect image frame \(index + 1).")
            }
            let (pixelCount, overflow) = UInt64(width.int64Value).multipliedReportingOverflow(by: UInt64(height.int64Value))
            guard !overflow else { throw MorphError.invalidInput("Image frame dimensions are too large to convert safely.") }
            framePixelCounts.append(pixelCount)
        }
        try validateFramePixelCounts(framePixelCounts)
    }

    static func properties(
        preservingLocationMetadata: Bool,
        from sourceProperties: [CFString: Any]
    ) -> [CFString: Any] {
        guard !preservingLocationMetadata else { return sourceProperties }
        var properties = sourceProperties
        properties.removeValue(forKey: kCGImagePropertyGPSDictionary)
        if var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            let locationKeys: [CFString] = [
                kCGImagePropertyIPTCContentLocationCode,
                kCGImagePropertyIPTCContentLocationName,
                kCGImagePropertyIPTCCity,
                kCGImagePropertyIPTCSubLocation,
                kCGImagePropertyIPTCProvinceState,
                kCGImagePropertyIPTCCountryPrimaryLocationCode,
                kCGImagePropertyIPTCCountryPrimaryLocationName,
                kCGImagePropertyIPTCExtLocationCreated,
                kCGImagePropertyIPTCExtLocationCity,
                kCGImagePropertyIPTCExtLocationCountryCode,
                kCGImagePropertyIPTCExtLocationCountryName,
                kCGImagePropertyIPTCExtLocationGPSAltitude,
                kCGImagePropertyIPTCExtLocationGPSLatitude,
                kCGImagePropertyIPTCExtLocationGPSLongitude,
                kCGImagePropertyIPTCExtLocationIdentifier,
                kCGImagePropertyIPTCExtLocationLocationId,
                kCGImagePropertyIPTCExtLocationLocationName,
                kCGImagePropertyIPTCExtLocationProvinceState,
                kCGImagePropertyIPTCExtLocationSublocation,
                kCGImagePropertyIPTCExtLocationWorldRegion,
                kCGImagePropertyIPTCExtLocationShown,
                kCGImagePropertyIPTCExtRatingRegionCity,
                kCGImagePropertyIPTCExtRatingRegionCountryCode,
                kCGImagePropertyIPTCExtRatingRegionCountryName,
                kCGImagePropertyIPTCExtRatingRegionGPSAltitude,
                kCGImagePropertyIPTCExtRatingRegionGPSLatitude,
                kCGImagePropertyIPTCExtRatingRegionGPSLongitude,
                kCGImagePropertyIPTCExtRatingRegionIdentifier,
                kCGImagePropertyIPTCExtRatingRegionLocationId,
                kCGImagePropertyIPTCExtRatingRegionLocationName,
                kCGImagePropertyIPTCExtRatingRegionProvinceState,
                kCGImagePropertyIPTCExtRatingRegionSublocation,
                kCGImagePropertyIPTCExtRatingRegionWorldRegion,
            ]
            for key in locationKeys { iptc.removeValue(forKey: key) }
            properties[kCGImagePropertyIPTCDictionary] = iptc
        }
        return properties
    }

    public static func convert(
        input: URL,
        output: URL,
        quality: Double,
        stripLocationMetadata: Bool = true,
        cancellation: CancellationToken = CancellationToken()
    ) throws {
        if cancellation.isCancelled { throw MorphError.cancelled }
        try validateInput(input)
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw MorphError.invalidInput("macOS could not decode this image.")
        }
        let imageCount = CGImageSourceGetCount(source)
        try validateSourceFrames(source, cancellation: cancellation)
        if imageCount > 1, !["gif", "tif", "tiff"].contains(output.pathExtension.lowercased()) {
            throw MorphError.invalidInput("This image contains multiple frames or pages. Convert it to GIF or TIFF to preserve every frame.")
        }
        guard let outputType = UTType(filenameExtension: output.pathExtension),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, outputType.identifier as CFString, imageCount, nil) else {
            throw MorphError.invalidOutput("macOS cannot write this image format.")
        }

        for index in 0..<imageCount {
            if cancellation.isCancelled { throw MorphError.cancelled }
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw MorphError.invalidInput("macOS could not decode image frame \(index + 1).")
            }
            let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            var properties = Self.properties(
                preservingLocationMetadata: !stripLocationMetadata,
                from: sourceProperties
            )
            properties[kCGImageDestinationLossyCompressionQuality] = quality
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        if cancellation.isCancelled { throw MorphError.cancelled }
        guard CGImageDestinationFinalize(destination) else {
            throw MorphError.invalidOutput("ImageIO could not finish writing the image.")
        }
        guard let expectedOutputType = UTType(filenameExtension: output.pathExtension),
              let generated = CGImageSourceCreateWithURL(output as CFURL, nil),
              let generatedType = CGImageSourceGetType(generated) as String?,
              generatedType == expectedOutputType.identifier,
              CGImageSourceGetCount(generated) == imageCount else {
            throw MorphError.invalidOutput("The generated image did not preserve every source frame or page.")
        }
    }
}

public enum NativePDFEngine {
    static let maximumPDFInputBytes: UInt64 = 512 * 1_024 * 1_024
    static let maximumPageCount = 1_000
    static let maximumPagePixels: UInt64 = 16_000_000
    static let maximumTotalRasterPixels: UInt64 = 256_000_000
    static let maximumGeneratedBytes: UInt64 = 1_024 * 1_024 * 1_024
    static let maximumCombinedInputBytes: UInt64 = 1_024 * 1_024 * 1_024

    static func addingMergedInputBytes(_ currentTotal: UInt64, nextFileBytes: UInt64) throws -> UInt64 {
        let (combined, overflow) = currentTotal.addingReportingOverflow(nextFileBytes)
        guard currentTotal <= maximumCombinedInputBytes,
              nextFileBytes > 0,
              nextFileBytes <= maximumPDFInputBytes,
              !overflow,
              combined <= maximumCombinedInputBytes else {
            throw MorphError.invalidInput("PDF merges are limited to 1 GB of input across at most 1,000 files.")
        }
        return combined
    }

    static func validateInput(_ input: URL) throws {
        let descriptor = input.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw MorphError.invalidInput("The PDF is not a readable regular file.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0,
              UInt64(info.st_size) <= maximumPDFInputBytes else {
            throw MorphError.invalidInput("PDF inputs must be regular files no larger than 512 MB.")
        }
        guard hasPDFHeader(input) else {
            throw MorphError.invalidInput("The selected file does not have a PDF header.")
        }
    }

    static func validateHeaderForGhostscript(_ input: URL) throws {
        guard hasPDFHeader(input) else {
            throw MorphError.invalidInput("Ghostscript compression accepts PDF files, not PostScript or dual-format files.")
        }
    }

    static func hasPDFHeader(_ input: URL) -> Bool {
        let descriptor = input.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 5 else { return false }
        var prefix = [UInt8](repeating: 0, count: 5)
        let count = prefix.withUnsafeMutableBytes { bytes in
            pread(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        return count == prefix.count && Array(prefix) == Array("%PDF-".utf8)
    }

    static func validatePageCount(_ count: Int) throws {
        guard count > 0, count <= maximumPageCount else {
            throw MorphError.invalidInput("PDF operations are limited to 1,000 pages per file.")
        }
    }

    public static func extractText(input: URL, output: URL, cancellation: CancellationToken) throws {
        if cancellation.isCancelled { throw MorphError.cancelled }
        try validateInput(input)
        guard let document = PDFDocument(url: input), document.pageCount > 0 else {
            throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
        }
        if cancellation.isCancelled { throw MorphError.cancelled }
        try validatePageCount(document.pageCount)
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw MorphError.invalidOutput("Morph could not create a private text output for this PDF.")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        let maximumOutputBytes = 20 * 1_024 * 1_024
        var writtenBytes = 0
        var extractedPageCount = 0
        for index in 0..<document.pageCount {
            if cancellation.isCancelled { throw MorphError.cancelled }
            guard let page = document.page(at: index) else {
                throw MorphError.invalidInput("Morph could not read PDF page \(index + 1).")
            }
            guard let pageText = page.string else { continue }
            if cancellation.isCancelled { throw MorphError.cancelled }
            guard !pageText.isEmpty else { continue }
            let prefix = extractedPageCount == 0 ? "" : "\n\n"
            let data = Data((prefix + pageText + "\n").utf8)
            guard data.count <= maximumOutputBytes - writtenBytes else {
                throw MorphError.invalidInput("The extracted PDF text exceeds Morph's 20 MB output limit.")
            }
            try handle.write(contentsOf: data)
            writtenBytes += data.count
            extractedPageCount += 1
        }

        guard extractedPageCount > 0 else {
            throw MorphError.invalidInput("This PDF contains no extractable text.")
        }
        try handle.synchronize()
    }

    public static func imageToPDF(input: URL, output: URL, cancellation: CancellationToken = CancellationToken()) throws {
        if cancellation.isCancelled { throw MorphError.cancelled }
        try NativeImageEngine.validateInput(input)
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw MorphError.invalidInput("macOS could not decode this image as a PDF page.")
        }
        try NativeImageEngine.validateSourceFrames(source, cancellation: cancellation)
        let imageCount = CGImageSourceGetCount(source)
        let document = PDFDocument()
        for index in 0..<imageCount {
            if cancellation.isCancelled { throw MorphError.cancelled }
            guard let decoded = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw MorphError.invalidInput("macOS could not decode image frame \(index + 1) as a PDF page.")
            }
            let image = try pixelOnlyImage(decoded)
            guard let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else {
                throw MorphError.invalidInput("macOS could not create a metadata-free PDF page from image frame \(index + 1).")
            }
            document.insert(page, at: document.pageCount)
        }
        if cancellation.isCancelled { throw MorphError.cancelled }
        guard document.pageCount == imageCount,
              document.write(to: output) else {
            throw MorphError.invalidOutput("PDFKit could not write every image frame as a PDF page.")
        }
        if cancellation.isCancelled { throw MorphError.cancelled }
        try ConversionOutputLimits.validate(output, maximumBytes: maximumGeneratedBytes)
        guard Self.hasPDFHeader(output),
              let generated = PDFDocument(url: output), generated.pageCount == imageCount else {
            throw MorphError.invalidOutput("The generated PDF did not preserve every source frame as a page.")
        }
    }

    private static func pixelOnlyImage(_ image: CGImage) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw MorphError.invalidInput("Morph could not safely rasterize the selected image for PDF output.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else {
            throw MorphError.invalidInput("Morph could not create a metadata-free PDF page image.")
        }
        return result
    }

    public static func pagesToPNGZip(input: URL, output: URL, cancellation: CancellationToken) throws {
        if cancellation.isCancelled { throw MorphError.cancelled }
        try validateInput(input)
        guard let document = PDFDocument(url: input), document.pageCount > 0 else {
            throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
        }
        if cancellation.isCancelled { throw MorphError.cancelled }
        try validatePageCount(document.pageCount)
        guard let zip = ExecutableLocator.resolveSystemTool("zip") else {
            throw MorphError.processFailed("The macOS ZIP creation tool is unavailable.")
        }

        var totalPixels: UInt64 = 0
        for pageIndex in 0..<document.pageCount {
            if cancellation.isCancelled { throw MorphError.cancelled }
            guard let page = document.page(at: pageIndex) else {
                throw MorphError.invalidInput("Morph could not read PDF page \(pageIndex + 1).")
            }
            let dimensions = try pixelDimensions(for: page, pageIndex: pageIndex)
            guard totalPixels <= maximumTotalRasterPixels - dimensions.pixelCount else {
                throw MorphError.invalidInput("PDF page images may use no more than 256 million rendered pixels per conversion.")
            }
            totalPixels += dimensions.pixelCount
        }
        try ensureAvailableSpace(for: totalPixels, at: output.deletingLastPathComponent(), copies: 2)

        let workStage = try PrivateOutputStage(parentDirectory: output.deletingLastPathComponent())
        let workDirectory = workStage.directoryURL

        var totalPNGBytes: UInt64 = 0
        for pageIndex in 0..<document.pageCount {
            if cancellation.isCancelled { throw MorphError.cancelled }
            guard let page = document.page(at: pageIndex) else {
                throw MorphError.invalidInput("Morph could not read PDF page \(pageIndex + 1).")
            }
            let pageName = String(format: "page-%0*d.png", String(document.pageCount).count, pageIndex + 1)
            let pageBytes = try render(
                page,
                pageIndex: pageIndex,
                output: workDirectory.appendingPathComponent(pageName),
                cancellation: cancellation
            )
            guard totalPNGBytes <= maximumGeneratedBytes - pageBytes else {
                throw MorphError.invalidOutput("PDF page images may not exceed Morph's 1 GB conversion limit.")
            }
            totalPNGBytes += pageBytes
        }

        let result = try ProcessRunner.run(
            executable: zip,
            arguments: ["-q", "-r", output.path, "."],
            currentDirectory: workDirectory,
            cancellation: cancellation,
            sandboxReadableDirectories: [workDirectory],
            sandboxWritableDirectories: [workDirectory, output.deletingLastPathComponent()],
            restrictedSandbox: true
        )
        guard result.status == 0 else {
            throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        _ = try validateGeneratedSize(output)
    }

    public static func singlePageToPNG(input: URL, output: URL, cancellation: CancellationToken) throws {
        if cancellation.isCancelled { throw MorphError.cancelled }
        try validateInput(input)
        guard let document = PDFDocument(url: input) else {
            throw MorphError.invalidInput("A readable single-page PDF is required for direct PNG output.")
        }
        if cancellation.isCancelled { throw MorphError.cancelled }
        try validatePageCount(document.pageCount)
        guard document.pageCount == 1,
              let page = document.page(at: 0) else {
            throw MorphError.invalidInput("A single-page PDF is required for direct PNG output.")
        }
        if cancellation.isCancelled { throw MorphError.cancelled }
        try render(page, pageIndex: 0, output: output, cancellation: cancellation)
    }

    private struct PixelDimensions {
        let width: Int
        let height: Int
        let pixelCount: UInt64
        let scale: Double
    }

    private static func pixelDimensions(for page: PDFPage, pageIndex: Int) throws -> PixelDimensions {
        let pageBounds = page.bounds(for: .cropBox).standardized
        let pageWidth = Double(pageBounds.width)
        let pageHeight = Double(pageBounds.height)
        let pageArea = pageWidth * pageHeight
        guard pageWidth.isFinite, pageHeight.isFinite, pageWidth > 0, pageHeight > 0 else {
            throw MorphError.invalidInput("PDF page \(pageIndex + 1) has invalid dimensions.")
        }
        guard pageArea.isFinite, pageArea > 0 else {
            throw MorphError.invalidInput("PDF page \(pageIndex + 1) has dimensions that are too large to render safely.")
        }

        let maximumDimension = 16_384.0
        let desiredScale = 2.0
        let areaScale = sqrt(Double(maximumPagePixels) / pageArea)
        let dimensionScale = maximumDimension / max(pageWidth, pageHeight)
        let scale = min(desiredScale, areaScale, dimensionScale)
        let pixelWidth = max(1, Int(ceil(pageWidth * scale)))
        let pixelHeight = max(1, Int(ceil(pageHeight * scale)))
        let pixelCount = UInt64(pixelWidth) * UInt64(pixelHeight)
        guard pixelCount <= maximumPagePixels else {
            throw MorphError.invalidInput("PDF page \(pageIndex + 1) exceeds Morph's 16-million-pixel rendering limit.")
        }
        return PixelDimensions(width: pixelWidth, height: pixelHeight, pixelCount: pixelCount, scale: scale)
    }

    @discardableResult
    private static func render(
        _ page: PDFPage,
        pageIndex: Int,
        output: URL,
        cancellation: CancellationToken
    ) throws -> UInt64 {
        if cancellation.isCancelled { throw MorphError.cancelled }
        let pageBounds = page.bounds(for: .cropBox).standardized
        let dimensions = try pixelDimensions(for: page, pageIndex: pageIndex)
        try ensureAvailableSpace(for: dimensions.pixelCount, at: output.deletingLastPathComponent(), copies: 2)
        guard let context = CGContext(
            data: nil,
            width: dimensions.width,
            height: dimensions.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw MorphError.invalidOutput("Morph could not allocate an image for PDF page \(pageIndex + 1).")
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height))
        context.interpolationQuality = .high
        context.saveGState()
        context.scaleBy(x: dimensions.scale, y: dimensions.scale)
        context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
        if cancellation.isCancelled { throw MorphError.cancelled }

        guard let image = context.makeImage() else {
            throw MorphError.invalidOutput("Morph could not render PDF page \(pageIndex + 1).")
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
            throw MorphError.invalidOutput("Morph could not create the PNG for PDF page \(pageIndex + 1).")
        }
        CGImageDestinationAddImage(destination, image, nil)
        if cancellation.isCancelled { throw MorphError.cancelled }
        guard CGImageDestinationFinalize(destination) else {
            throw MorphError.invalidOutput("Morph could not finish the PNG for PDF page \(pageIndex + 1).")
        }
        if cancellation.isCancelled { throw MorphError.cancelled }
        return try validateGeneratedSize(output)
    }

    private static func validateGeneratedSize(_ output: URL) throws -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0,
              UInt64(size.int64Value) <= maximumGeneratedBytes else {
            throw MorphError.invalidOutput("PDF image output may not exceed Morph's 1 GB conversion limit.")
        }
        return UInt64(size.int64Value)
    }

    private static func ensureAvailableSpace(for pixels: UInt64, at directory: URL, copies: UInt64) throws {
        let (rawBytes, rawOverflow) = pixels.multipliedReportingOverflow(by: 4)
        let (renderBytes, renderOverflow) = rawBytes.multipliedReportingOverflow(by: copies)
        let (requiredBytes, marginOverflow) = renderBytes.addingReportingOverflow(64 * 1_024 * 1_024)
        guard !rawOverflow, !renderOverflow, !marginOverflow else {
            throw MorphError.invalidInput("Morph could not estimate safe temporary storage for PDF images.")
        }
        guard let available = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else {
            return
        }
        guard available >= 0, UInt64(available) >= requiredBytes else {
            throw MorphError.invalidOutput("There is not enough free disk space for the requested PDF page images.")
        }
    }
}

public enum ImageMagickEngine {
    public static func convert(
        executable: URL,
        input: URL,
        output: URL,
        quality: Double,
        cancellation: CancellationToken,
        stripLocationMetadata: Bool = true
    ) throws {
        try EngineSecurityPolicy.validateExecutable(executable, for: .imageMagick, cancellation: cancellation)
        let policyStage = try PrivateOutputStage(parentDirectory: output.deletingLastPathComponent())
        let policyDirectory = policyStage.directoryURL
        let policyURL = policyDirectory.appendingPathComponent("policy.xml")
        let policy = """
        <policymap>
          <policy domain="resource" name="memory" value="512MiB"/>
          <policy domain="resource" name="map" value="1GiB"/>
          <policy domain="resource" name="disk" value="1GiB"/>
          <policy domain="resource" name="width" value="32768"/>
          <policy domain="resource" name="height" value="32768"/>
          <policy domain="resource" name="area" value="128MP"/>
          <policy domain="resource" name="list-length" value="64"/>
          <policy domain="resource" name="thread" value="4"/>
          <policy domain="resource" name="time" value="60"/>
          <policy domain="delegate" rights="none" pattern="*"/>
          <policy domain="filter" rights="none" pattern="*"/>
          <policy domain="path" rights="none" pattern="@*"/>
          <policy domain="system" name="filename:literal" value="true"/>
          <policy domain="coder" rights="none" pattern="*"/>
          <policy domain="coder" rights="read|write" pattern="{BMP,GIF,HEIC,HEIF,ICO,JPEG,JPG,JNG,JP2,J2K,PNG,PNG24,PNG32,PPM,PGM,PBM,PNM,TIFF,TIF,WEBP,AVIF}"/>
        </policymap>
        """
        do {
            try Data(policy.utf8).write(to: policyURL, options: .atomic)
            _ = chmod(policyURL.path, mode_t(0o600))
        } catch {
            throw MorphError.processFailed("Morph could not write its restrictive ImageMagick policy.")
        }
        var arguments = [
            "-limit", "memory", "512MiB",
            "-limit", "map", "1GiB",
            "-limit", "disk", "1GiB",
            "-limit", "width", "32768",
            "-limit", "height", "32768",
            "-limit", "area", "128MP",
            "-limit", "thread", "4",
            "-limit", "time", "60",
            "\(input.pathExtension.lowercased()):\(input.path)",
        ]
        if stripLocationMetadata {
            // ImageMagick cannot reliably remove only GPS fields across every
            // supported container. Drop location-bearing metadata profiles but
            // retain ICC color profiles and the decoded image data.
            arguments += ["+profile", "exif", "+profile", "xmp", "+profile", "iptc"]
        }
        if output.pathExtension.lowercased() == "ico" {
            arguments += ["-resize", "256x256>", "-define", "icon:auto-resize=256,128,64,48,32,16"]
        }
        arguments += ["-quality", String(Int((quality * 100).rounded())), output.path]
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            cancellation: cancellation,
            timeout: 70,
            environmentOverrides: [
                "HOME": policyDirectory.path,
                "MAGICK_CONFIGURE_PATH": policyDirectory.path,
                "MAGICK_TEMPORARY_PATH": policyDirectory.path,
            ],
            sandboxReadableDirectories: [input.deletingLastPathComponent(), policyDirectory],
            sandboxWritableDirectories: [policyDirectory, output.deletingLastPathComponent()],
            restrictedSandbox: true
        )
        guard result.status == 0 else { throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

public enum FFmpegEngine {
    public static func convert(
        executable: URL,
        input: URL,
        output: URL,
        cancellation: CancellationToken,
        stripLocationMetadata: Bool = true
    ) throws {
        try EngineSecurityPolicy.validateExecutable(executable, for: .ffmpeg, cancellation: cancellation)
        let ext = output.pathExtension.lowercased()
        guard let formatWhitelist = FFmpegInputFormat.whitelist(for: input.pathExtension) else {
            throw MorphError.unsupportedInput(input)
        }
        var arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-protocol_whitelist", "file", "-format_whitelist", formatWhitelist,
            "-i", input.path, "-map_metadata", "0",
        ]
        if stripLocationMetadata {
            arguments += MediaMetadataPolicy.ffmpegLocationRemovalArguments
        }

        switch ext {
        case "mp3": arguments += ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "wav": arguments += ["-vn", "-c:a", "pcm_s16le"]
        case "flac": arguments += ["-vn", "-c:a", "flac"]
        case "aac": arguments += ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "m4a": arguments += ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "ogg": arguments += ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case "opus": arguments += ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "aiff", "aif": arguments += ["-vn", "-c:a", "pcm_s16be"]
        case "wma": arguments += ["-vn", "-c:a", "wmav2", "-b:a", "128k"]
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
        arguments += ["-fs", String(NativeMediaLimits.maximumOutputBytes)]
        arguments.append(output.path)
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            cancellation: cancellation,
            outputFileLimit: ProcessOutputFileLimit(url: output, maximumBytes: NativeMediaLimits.maximumOutputBytes),
            sandboxReadableDirectories: [input.deletingLastPathComponent()],
            sandboxWritableDirectories: [output.deletingLastPathComponent()],
            restrictedSandbox: true
        )
        guard result.status == 0 else { throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        try NativeMediaLimits.validate(output)
    }
}

public enum PandocEngine {
    private static let formatNames: [String: String] = [
        "md": "commonmark_x", "markdown": "commonmark_x", "txt": "plain", "html": "html", "htm": "html",
        "docx": "docx", "odt": "odt", "rtf": "rtf", "epub": "epub", "pptx": "pptx", "xlsx": "xlsx",
        "org": "org", "rst": "rst", "tex": "latex", "xml": "xml", "tsv": "tsv",
    ]

    public static func convert(
        executable: URL,
        input: URL,
        output: URL,
        cancellation: CancellationToken
    ) throws {
        try EngineSecurityPolicy.validateExecutable(executable, for: .pandoc, cancellation: cancellation)
        guard let inputFormat = formatNames[input.pathExtension.lowercased()],
              let outputFormat = formatNames[output.pathExtension.lowercased()] else {
            throw MorphError.unsupportedConversion(input.pathExtension, output.pathExtension)
        }
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: ["+RTS", "-M512m", "-RTS", "--sandbox", "--from=\(inputFormat)", "--to=\(outputFormat)", "--output=\(output.path)", input.path],
            cancellation: cancellation,
            timeout: 5 * 60,
            sandboxReadableDirectories: [input.deletingLastPathComponent()],
            sandboxWritableDirectories: [output.deletingLastPathComponent()],
            restrictedSandbox: true
        )
        guard result.status == 0 else { throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

public enum LibreOfficeEngine {
    static var networkRestrictedSandboxProfile: String { ExternalEngineSandbox.profile }

    public static func convert(
        executable: URL,
        input: URL,
        output: URL,
        cancellation: CancellationToken,
        timeout: TimeInterval = 5 * 60
    ) throws {
        try EngineSecurityPolicy.validateExecutable(executable, for: .libreOffice, cancellation: cancellation)
        let temporaryStage = try PrivateOutputStage(parentDirectory: output.deletingLastPathComponent())
        let temporaryDirectory = temporaryStage.directoryURL
        let profile = temporaryDirectory.appendingPathComponent("profile", isDirectory: true)
        let profileURL = URL(fileURLWithPath: profile.path, isDirectory: true).absoluteString
        let inputExtension = input.pathExtension.lowercased()
        let produced = temporaryDirectory.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension(output.pathExtension)
        let importFilter: String?
        switch inputExtension {
        case "csv":
            importFilter = "Text - txt - csv (StarCalc):44,34,76,1,,0,false,false,true,false,false,0,false"
        case "tsv":
            importFilter = "Text - txt - csv (StarCalc):9,34,76,1,,0,false,false,true,false,false,0,false"
        default:
            importFilter = nil
        }
        var arguments = ["-env:UserInstallation=\(profileURL)", "--headless", "--convert-to", output.pathExtension,
                         "--outdir", temporaryDirectory.path]
        if let importFilter { arguments.insert("--infilter=\(importFilter)", at: 2) }
        arguments.append(input.path)
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            cancellation: cancellation,
            timeout: timeout,
            outputFileLimit: ProcessOutputFileLimit(url: produced, maximumBytes: ConversionOutputLimits.maximumGeneratedBytes),
            sandboxReadableDirectories: [input.deletingLastPathComponent(), temporaryDirectory],
            sandboxWritableDirectories: [temporaryDirectory],
            restrictedSandbox: true
        )
        guard result.status == 0 else { throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        // Do not validate or publish a path that the engine can still mutate.
        // Snapshot it into a separate Morph-owned directory first; the sandbox
        // grants the child no write access to that directory.
        let safeOutput = try PrivateInputSnapshot(
            input: produced,
            fileExtension: output.pathExtension.lowercased(),
            maximumBytes: ConversionOutputLimits.maximumGeneratedBytes,
            requireOwnedUnlinkedInput: true,
            cancellation: cancellation
        )
        try ConversionOutputLimits.validate(safeOutput.fileURL)
        if output.pathExtension.lowercased() == "csv" || output.pathExtension.lowercased() == "tsv" {
            try StructuredDataEngine.sanitizeDelimitedFile(at: safeOutput.fileURL)
        }
        do { try FileManager.default.copyItem(at: safeOutput.fileURL, to: output) }
        catch { throw MorphError.processFailed("Could not stage the LibreOffice output: \(error.localizedDescription)") }
    }
}

public enum ArchiveEngine {
    private static let maximumMembers = 10_000
    private static let maximumMemberBytes: UInt64 = 512 * 1024 * 1024
    private static let maximumExpandedBytes: UInt64 = 2 * 1024 * 1024 * 1024
    private static let maximumZIPDirectoryBytes = 16 * 1024 * 1024

    static let builtInInputExtensions: Set<String> = ["zip", "tar", "tar.gz", "tgz", "tar.bz2", "tbz", "tbz2", "tar.xz", "txz"]
    static let builtInOutputExtensions: Set<String> = ["zip", "tar", "tar.gz", "tar.bz2", "tar.xz"]

    public static func convert(input: URL, output: URL, cancellation: CancellationToken) throws {
        let archiveExtension = archiveExtension(for: output)
        let temporaryName = "output.partial.\(archiveExtension)"
        let transaction = try PrivateOutputTransaction(outputURL: output, temporaryFileName: temporaryName)
        try ArchiveExtractor.repackage(input: input, output: transaction.temporaryOutputURL, cancellation: cancellation)
        try transaction.publish(cancellation: cancellation)
    }

    static func extract(input: URL, to directory: URL, cancellation: CancellationToken, preservePermissions: Bool = false) throws {
        let inputExt = archiveExtension(for: input)
        if !["zip", "tar", "tar.gz", "tar.bz2", "tar.xz", "7z"].contains(inputExt) {
            throw MorphError.unsupportedConversion(inputExt, "archive contents")
        }
        try ArchiveExtractor.extract(input: input, to: directory, cancellation: cancellation, preservePermissions: preservePermissions)
    }

    static func archiveExtension(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "tar.gz" }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") || name.hasSuffix(".tbz") { return "tar.bz2" }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return "tar.xz" }
        if name.hasSuffix(".tar") { return "tar" }
        if name.hasSuffix(".zip") { return "zip" }
        if name.hasSuffix(".7z") { return "7z" }
        return url.pathExtension.lowercased()
    }

    static func validateZIP(
        _ url: URL,
        cancellation: CancellationToken? = nil,
        caseSensitiveFileSystem: Bool = false
    ) throws {
        if cancellation?.isCancelled == true { throw MorphError.cancelled }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw MorphError.invalidInput("The ZIP directory could not be read.") }
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let searchBytes = UInt64(22 + Int(UInt16.max))
        let tailSize = Int(min(fileSize, searchBytes))
        try handle.seek(toOffset: fileSize - UInt64(tailSize))
        let tail = Array(try handle.read(upToCount: tailSize) ?? Data())
        guard tail.count >= 22,
              let endIndex = (0...(tail.count - 22)).reversed().first(where: { readUInt32($0, in: tail) == 0x06054b50 }) else {
            throw MorphError.invalidInput("The ZIP directory is missing or malformed.")
        }
        let commentLength = Int(readUInt16(endIndex + 20, in: tail))
        guard endIndex + 22 + commentLength == tail.count else {
            throw MorphError.invalidInput("The ZIP directory has an invalid end record.")
        }
        let diskNumber = readUInt16(endIndex + 4, in: tail)
        let directoryDisk = readUInt16(endIndex + 6, in: tail)
        let entriesOnDisk = readUInt16(endIndex + 8, in: tail)
        let entryCount = readUInt16(endIndex + 10, in: tail)
        let directorySize = UInt64(readUInt32(endIndex + 12, in: tail))
        let directoryOffset = UInt64(readUInt32(endIndex + 16, in: tail))
        let endOffset = fileSize - UInt64(tail.count) + UInt64(endIndex)
        guard diskNumber == 0,
              directoryDisk == 0,
              entriesOnDisk == entryCount,
              entryCount > 0,
              entryCount != UInt16.max,
              Int(entryCount) <= maximumMembers,
              directorySize > 0,
              directorySize <= UInt64(maximumZIPDirectoryBytes),
              directoryOffset <= endOffset,
              directorySize == endOffset - directoryOffset else {
            throw MorphError.invalidInput("The ZIP uses a split, oversized, or unsupported directory.")
        }
        if endOffset >= 20 {
            try handle.seek(toOffset: endOffset - 20)
            let locator = Array(try handle.read(upToCount: 4) ?? Data())
            guard locator.count == 4, readUInt32(0, in: locator) != 0x07064b50 else {
                throw MorphError.invalidInput("ZIP64 archives are not supported safely.")
            }
        }
        guard commentLength <= 4_096 else {
            throw MorphError.invalidInput("ZIP comments may not exceed 4 KB.")
        }

        try handle.seek(toOffset: directoryOffset)
        let directory = Array(try handle.read(upToCount: Int(directorySize)) ?? Data())
        guard directory.count == Int(directorySize) else {
            throw MorphError.invalidInput("The ZIP directory ended unexpectedly.")
        }

        var index = 0
        var expandedBytes: UInt64 = 0
        var pathKinds: [String: Bool] = [:]
        var parentPaths = Set<String>()
        var localRanges: [(start: UInt64, end: UInt64)] = []
        for _ in 0..<entryCount {
            if cancellation?.isCancelled == true { throw MorphError.cancelled }
            guard index + 46 <= directory.count, readUInt32(index, in: directory) == 0x02014b50 else {
                throw MorphError.invalidInput("A ZIP entry has an invalid directory header.")
            }
            let versionMadeBy = readUInt16(index + 4, in: directory)
            let flags = readUInt16(index + 8, in: directory)
            let method = readUInt16(index + 10, in: directory)
            let compressedBytes = readUInt32(index + 20, in: directory)
            let uncompressedBytes = readUInt32(index + 24, in: directory)
            let nameLength = Int(readUInt16(index + 28, in: directory))
            let extraLength = Int(readUInt16(index + 30, in: directory))
            let entryCommentLength = Int(readUInt16(index + 32, in: directory))
            let entryDisk = readUInt16(index + 34, in: directory)
            let externalAttributes = readUInt32(index + 38, in: directory)
            let localHeaderOffset = readUInt32(index + 42, in: directory)
            let nextIndex = index + 46 + nameLength + extraLength + entryCommentLength
            guard nextIndex <= directory.count,
                  entryDisk == 0,
                  compressedBytes != UInt32.max,
                  uncompressedBytes != UInt32.max,
                  localHeaderOffset != UInt32.max,
                  UInt64(localHeaderOffset) < directoryOffset,
                  flags & 0x0001 == 0 else {
                throw MorphError.invalidInput("ZIP64, encrypted, split, or malformed ZIP entries are not supported safely.")
            }
            guard method == 0 || method == 8 || method == 12 || method == 14 else {
                throw MorphError.invalidInput("The ZIP uses an unsupported compression method.")
            }

            let rawName = Array(directory[(index + 46)..<(index + 46 + nameLength)])
            guard !rawName.isEmpty, rawName.count <= 4_096 else { throw MorphError.invalidInput("The ZIP contains an empty or overlong member name.") }
            let name: String?
            if flags & 0x0800 != 0 {
                name = String(bytes: rawName, encoding: .utf8)
            } else if rawName.allSatisfy({ $0 < 0x80 }) {
                name = String(bytes: rawName, encoding: .ascii)
            } else {
                // macOS /usr/bin/zip emits UTF-8 names without setting bit 11.
                name = String(bytes: rawName, encoding: .utf8)
            }
            guard let name else { throw MorphError.invalidInput("The ZIP contains a member name that is not safe UTF-8.") }
            try validateArchivePath(name)

            let hostOS = versionMadeBy >> 8
            let unixMode = (externalAttributes >> 16) & 0xffff
            let fileType = unixMode & 0xf000
            if hostOS == 3, fileType != 0, fileType != 0x8000, fileType != 0x4000 {
                throw MorphError.invalidInput("ZIP links and special files cannot be extracted safely.")
            }
            let isDirectory = name.hasSuffix("/") || externalAttributes & 0x10 != 0
            if hostOS == 3, fileType != 0,
               (isDirectory ? fileType != 0x4000 : fileType != 0x8000) {
                throw MorphError.invalidInput("A ZIP entry's path and file type do not agree.")
            }
            guard !isDirectory || uncompressedBytes == 0 else {
                throw MorphError.invalidInput("A ZIP directory entry must not contain file data.")
            }

            let normalizedPath = name.replacingOccurrences(of: "\\", with: "/")
            let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty, components.count <= 128,
                  !components.contains("."), !components.contains("..") else {
                throw MorphError.invalidInput("The ZIP contains a path that cannot be represented safely.")
            }
            let collisionKey = ArchivePathCollision.key(
                components.joined(separator: "/"),
                caseSensitiveFileSystem: caseSensitiveFileSystem
            )
            guard pathKinds[collisionKey] == nil else {
                throw MorphError.invalidInput("The ZIP contains duplicate names that collide on a Mac filesystem.")
            }
            var ancestor = ""
            for component in components.dropLast() {
                ancestor = ancestor.isEmpty ? component : ancestor + "/" + component
                let ancestorKey = ArchivePathCollision.key(ancestor, caseSensitiveFileSystem: caseSensitiveFileSystem)
                if pathKinds[ancestorKey] == false {
                    throw MorphError.invalidInput("The ZIP contains a file used as a parent directory.")
                }
                parentPaths.insert(ancestorKey)
            }
            guard isDirectory || !parentPaths.contains(collisionKey) else {
                throw MorphError.invalidInput("The ZIP contains a file path that conflicts with an existing directory.")
            }
            pathKinds[collisionKey] = isDirectory

            let memberSize = isDirectory ? 0 : UInt64(uncompressedBytes)
            guard memberSize <= maximumMemberBytes,
                  expandedBytes <= maximumExpandedBytes - memberSize else {
                throw MorphError.invalidInput("The ZIP exceeds Morph's 2 GB expanded-size or 512 MB per-file extraction limit.")
            }
            expandedBytes += memberSize

            let localOffset = UInt64(localHeaderOffset)
            guard localOffset + 30 <= directoryOffset else {
                throw MorphError.invalidInput("A ZIP local file header is outside the data section.")
            }
            try handle.seek(toOffset: localOffset)
            let localHeader = Array(try handle.read(upToCount: 30) ?? Data())
            guard localHeader.count == 30, readUInt32(0, in: localHeader) == 0x04034b50 else {
                throw MorphError.invalidInput("A ZIP local file header is malformed.")
            }
            let localFlags = readUInt16(6, in: localHeader)
            let localMethod = readUInt16(8, in: localHeader)
            let localCRC = readUInt32(14, in: localHeader)
            let localCompressed = readUInt32(18, in: localHeader)
            let localUncompressed = readUInt32(22, in: localHeader)
            let localNameLength = Int(readUInt16(26, in: localHeader))
            let localExtraLength = Int(readUInt16(28, in: localHeader))
            let dataStart = localOffset + 30 + UInt64(localNameLength) + UInt64(localExtraLength)
            let dataEnd = dataStart + UInt64(compressedBytes)
            guard localFlags == flags, localMethod == method,
                  dataStart <= directoryOffset, dataEnd <= directoryOffset,
                  localNameLength == rawName.count else {
                throw MorphError.invalidInput("ZIP local and central directory records disagree.")
            }
            try handle.seek(toOffset: localOffset + 30)
            let localName = Array(try handle.read(upToCount: localNameLength) ?? Data())
            guard localName == rawName else {
                throw MorphError.invalidInput("A ZIP local file name does not match its directory entry.")
            }
            if flags & 0x0008 == 0 {
                let crc = readUInt32(index + 16, in: directory)
                guard localCRC == crc,
                      localCompressed == compressedBytes,
                      localUncompressed == uncompressedBytes else {
                    throw MorphError.invalidInput("ZIP local and central file sizes do not agree.")
                }
            } else {
                guard (localCompressed == 0 || localCompressed == compressedBytes),
                      (localUncompressed == 0 || localUncompressed == uncompressedBytes) else {
                    throw MorphError.invalidInput("ZIP local and central file sizes do not agree.")
                }
            }
            localRanges.append((localOffset, dataEnd))
            index = nextIndex
        }
        guard index == directory.count else {
            throw MorphError.invalidInput("The ZIP directory contains unrecognized or trailing data.")
        }
        localRanges.sort { $0.start < $1.start }
        for pair in zip(localRanges, localRanges.dropFirst()) where pair.0.end > pair.1.start {
            throw MorphError.invalidInput("ZIP local file entries overlap one another.")
        }
    }

    private static func validateArchivePath(_ rawPath: String) throws {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")
        let hasWindowsDrivePrefix = path.range(of: "^[A-Za-z]:", options: .regularExpression) != nil
        if path.isEmpty || path.hasPrefix("/") || hasWindowsDrivePrefix ||
            path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ||
            path.split(separator: "/").contains("..") {
            throw MorphError.invalidInput("The archive contains a path that escapes its extraction folder or cannot be safely represented.")
        }
    }

    static func ensureExtractedItemsStayInside(_ directory: URL) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw MorphError.invalidInput("Morph could not verify every extracted archive item.")
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw MorphError.invalidInput("Archive links cannot be extracted safely.")
            }
            let resolved = item.standardizedFileURL.resolvingSymlinksInPath().path
            if !resolved.hasPrefix(root) {
                throw MorphError.invalidInput("The archive contains a link that escapes its extraction folder.")
            }
        }
    }

    static func validateExtractedTree(_ directory: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        ) else {
            throw MorphError.invalidInput("Morph could not verify the extracted archive contents.")
        }
        var memberCount = 0
        var expandedBytes: UInt64 = 0
        for case let item as URL in enumerator {
            memberCount += 1
            guard memberCount <= maximumMembers else {
                throw MorphError.invalidInput("The archive contains more than 10,000 extracted items.")
            }
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw MorphError.invalidInput("The archive contains an unsupported special file.")
            }
            if values.isRegularFile == true {
                let size = UInt64(max(0, values.fileSize ?? 0))
                guard size <= maximumMemberBytes,
                      expandedBytes <= maximumExpandedBytes - size else {
                    throw MorphError.invalidInput("The archive exceeds Morph's extraction size limits.")
                }
                expandedBytes += size
            }
        }
    }

    private static func readUInt16(_ index: Int, in bytes: [UInt8]) -> UInt16 {
        UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    private static func readUInt32(_ index: Int, in bytes: [UInt8]) -> UInt32 {
        UInt32(bytes[index]) | (UInt32(bytes[index + 1]) << 8) | (UInt32(bytes[index + 2]) << 16) | (UInt32(bytes[index + 3]) << 24)
    }
}

enum SevenZipArchiveEngine {
    static func convert(executable: URL, input: URL, output: URL, cancellation: CancellationToken) throws {
        try EngineSecurityPolicy.validateExecutable(executable, for: .sevenZip, cancellation: cancellation)
        let inputExtension = ArchiveEngine.archiveExtension(for: input)
        guard ["7z", "zip"].contains(inputExtension) else {
            throw MorphError.unsupportedConversion(inputExtension, output.pathExtension)
        }
        let outputExtension = output.pathExtension.lowercased()
        guard ["7z", "zip"].contains(outputExtension) else {
            throw MorphError.unsupportedConversion(inputExtension, outputExtension)
        }

        let workStage = try PrivateOutputStage(parentDirectory: output.deletingLastPathComponent())
        let workDirectory = workStage.directoryURL

        try ArchiveEngine.extract(input: input, to: workDirectory, cancellation: cancellation, preservePermissions: true)

        let type = outputExtension == "7z" ? "7z" : "zip"
        let created = try ProcessRunner.run(
            executable: executable,
            arguments: ["a", "-t\(type)", output.path, "."],
            currentDirectory: workDirectory,
            cancellation: cancellation,
            sandboxReadableDirectories: [workDirectory],
            sandboxWritableDirectories: [workDirectory, output.deletingLastPathComponent()],
            restrictedSandbox: true
        )
        guard created.status == 0 else {
            throw MorphError.processFailed(created.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

}

public enum OutputValidator {
    public static func validate(
        _ url: URL,
        format: MorphFormat,
        engine: EngineID,
        cancellation: CancellationToken? = nil
    ) throws {
        let usesExternalValidator = [.archive, .audio, .video].contains(format.category)
            || ([.pandoc, .libreOffice].contains(engine)
                && ["docx", "odt", "epub", "pptx", "xlsx"].contains(format.fileExtension))
        if usesExternalValidator,
           !ExternalEngineSandbox.isPrivateStageDirectory(url.deletingLastPathComponent()) {
            let snapshot = try PrivateInputSnapshot(
                input: url,
                fileExtension: format.fileExtension,
                cancellation: cancellation ?? CancellationToken()
            )
            try validate(snapshot.fileURL, format: format, engine: engine, cancellation: cancellation)
            return
        }
        if cancellation?.isCancelled == true { throw MorphError.cancelled }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw MorphError.invalidOutput("The output file is missing or empty.")
        }
        switch format.category {
        case .image:
            guard let expectedType = UTType(filenameExtension: format.fileExtension),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let actualType = CGImageSourceGetType(source) as String?,
                  actualType == expectedType.identifier,
                  CGImageSourceGetCount(source) > 0 else {
                throw MorphError.invalidOutput("macOS could not decode the generated image.")
            }
        case .document where format.fileExtension == "pdf":
            guard NativePDFEngine.hasPDFHeader(url), PDFDocument(url: url) != nil else {
                throw MorphError.invalidOutput("PDFKit could not open a valid generated PDF.")
            }
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
            try validateArchive(url, format: format, engine: engine, cancellation: cancellation)
        case .audio, .video:
            try validateMedia(url, cancellation: cancellation)
        default:
            break
        }

        if [.pandoc, .libreOffice].contains(engine) && ["docx", "odt", "epub", "pptx", "xlsx"].contains(format.fileExtension) {
            guard let unzip = ExecutableLocator.resolveSystemTool("unzip") else { return }
            let result = try ProcessRunner.run(
                executable: unzip,
                arguments: ["-tqq", url.path],
                cancellation: cancellation,
                sandboxReadableDirectories: [url.deletingLastPathComponent()],
                restrictedSandbox: true
            )
            guard result.status == 0, !result.stderrWasTruncated else { throw MorphError.invalidOutput("The generated Office or EPUB package failed its ZIP integrity check.") }
        }
        if cancellation?.isCancelled == true { throw MorphError.cancelled }
    }

    private static func validateArchive(
        _ url: URL,
        format: MorphFormat,
        engine: EngineID,
        cancellation: CancellationToken?
    ) throws {
        let outputExt = format.fileExtension
        if engine == .sevenZip {
            guard let executable = ExecutableLocator.resolve(["7zz", "7z"]) else {
                throw MorphError.invalidOutput("7-Zip is unavailable to validate this archive.")
            }
            try EngineSecurityPolicy.validateExecutable(executable, for: .sevenZip, cancellation: cancellation)
            let result = try ProcessRunner.run(
                executable: executable,
                arguments: ["t", "-bso0", "-bsp0", url.path],
                cancellation: cancellation,
                sandboxReadableDirectories: [url.deletingLastPathComponent()],
                restrictedSandbox: true
            )
            guard result.status == 0, !result.stderrWasTruncated else { throw MorphError.invalidOutput("The generated archive failed its 7-Zip integrity check.") }
            return
        }
        let executable = outputExt == "zip" ? ExecutableLocator.resolveSystemTool("unzip") : ExecutableLocator.resolveSystemTool("tar")
        guard let executable else { throw MorphError.invalidOutput("No archive validation tool is available.") }
        let result = outputExt == "zip"
            ? try ProcessRunner.run(executable: executable, arguments: ["-tqq", url.path], cancellation: cancellation, sandboxReadableDirectories: [url.deletingLastPathComponent()], restrictedSandbox: true)
            : try ProcessRunner.run(executable: executable, arguments: ["-tf", url.path], cancellation: cancellation, maximumOutputBytes: 0, sandboxReadableDirectories: [url.deletingLastPathComponent()], restrictedSandbox: true)
        guard result.status == 0, !result.stderrWasTruncated else { throw MorphError.invalidOutput("The generated archive failed its integrity check.") }
    }

    private static func validateMedia(_ url: URL, cancellation: CancellationToken?) throws {
        guard let ffprobe = ExecutableLocator.resolve(["ffprobe"]) else {
            throw MorphError.invalidOutput("Morph requires FFprobe to validate generated media files.")
        }
        try EngineSecurityPolicy.validateExecutable(ffprobe, for: .ffmpeg, cancellation: cancellation)
        guard let formatWhitelist = FFmpegInputFormat.whitelist(for: url.pathExtension) else {
            throw MorphError.invalidOutput("Morph could not identify the generated media container safely.")
        }
        let result = try ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-protocol_whitelist", "file", "-format_whitelist", formatWhitelist,
            "-show_entries", "format=format_name", "-of", "default=noprint_wrappers=1:nokey=1", url.path,
        ], cancellation: cancellation, sandboxReadableDirectories: [url.deletingLastPathComponent()], restrictedSandbox: true)
        guard result.status == 0, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MorphError.invalidOutput("FFprobe could not validate the generated media.")
        }
    }
}

private final class XMLValidityChecker: NSObject, XMLParserDelegate {
    var hasError = false
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { hasError = true }
}
