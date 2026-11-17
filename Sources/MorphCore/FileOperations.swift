import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct FileMetadataEntry: Identifiable, Hashable, Sendable {
    public let label: String
    public let value: String

    public var id: String { label }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public enum MorphFileOperations {
    public static func inspectMetadata(_ input: URL) throws -> [FileMetadataEntry] {
        guard FileManager.default.fileExists(atPath: input.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: input.path) else {
            throw MorphError.invalidInput("The selected file is no longer available.")
        }

        let fileExtension = input.pathExtension.lowercased()
        var entries = [
            FileMetadataEntry(label: "Name", value: input.lastPathComponent),
            FileMetadataEntry(label: "Format", value: UTType(filenameExtension: fileExtension)?.localizedDescription ?? fileExtension.uppercased()),
        ]
        if let size = attributes[.size] as? NSNumber {
            entries.append(FileMetadataEntry(label: "File size", value: ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)))
        }
        if let modified = attributes[.modificationDate] as? Date {
            entries.append(FileMetadataEntry(label: "Modified", value: modified.formatted(date: .abbreviated, time: .shortened)))
        }

        if fileExtension == "pdf" {
            guard let document = PDFDocument(url: input), document.pageCount > 0 else {
                throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
            }
            entries.append(FileMetadataEntry(label: "Pages", value: String(document.pageCount)))
            let attributes = document.documentAttributes ?? [:]
            let fields: [(PDFDocumentAttribute, String)] = [
                (.titleAttribute, "Title"),
                (.authorAttribute, "Author"),
                (.subjectAttribute, "Subject"),
                (.keywordsAttribute, "Keywords"),
                (.creatorAttribute, "Creator"),
                (.producerAttribute, "Producer"),
                (.creationDateAttribute, "Created"),
                (.modificationDateAttribute, "Metadata modified"),
            ]
            for (key, label) in fields {
                if let value = attributes[key] {
                    entries.append(FileMetadataEntry(label: label, value: String(describing: value)))
                }
            }
            return entries
        }

        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw MorphError.invalidInput("macOS could not read metadata for this image.")
        }
        if let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            entries.append(FileMetadataEntry(label: "Dimensions", value: "\(width) × \(height) pixels"))
        }
        if let colorModel = properties[kCGImagePropertyColorModel] as? String {
            entries.append(FileMetadataEntry(label: "Color model", value: colorModel))
        }
        if let dpiWidth = properties[kCGImagePropertyDPIWidth] as? NSNumber,
           let dpiHeight = properties[kCGImagePropertyDPIHeight] as? NSNumber {
            entries.append(FileMetadataEntry(label: "Resolution", value: "\(dpiWidth) × \(dpiHeight) DPI"))
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            append(exif[kCGImagePropertyExifDateTimeOriginal], label: "Captured", to: &entries)
            append(exif[kCGImagePropertyExifLensModel], label: "Lens", to: &entries)
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            append(tiff[kCGImagePropertyTIFFMake], label: "Camera make", to: &entries)
            append(tiff[kCGImagePropertyTIFFModel], label: "Camera model", to: &entries)
            append(tiff[kCGImagePropertyTIFFSoftware], label: "Software", to: &entries)
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude] as? NSNumber,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? NSNumber {
            let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            entries.append(FileMetadataEntry(label: "Location", value: "\(latitude)° \(latitudeRef), \(longitude)° \(longitudeRef)"))
        }
        return entries
    }

    private static func append(_ value: Any?, label: String, to entries: inout [FileMetadataEntry]) {
        guard let value else { return }
        entries.append(FileMetadataEntry(label: label, value: String(describing: value)))
    }

    @discardableResult
    public static func resizeImage(_ input: URL, scale: Double, outputDirectory: URL? = nil, quality: Double = 0.85) throws -> URL {
        guard (0.05...1.0).contains(scale) else { throw MorphError.invalidInput("Resize scale must be between 5% and 100%.") }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw MorphError.invalidInput("macOS could not read the image dimensions.")
        }

        let maxDimension = max(1, Int((Double(max(width, height)) * scale).rounded()))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MorphError.invalidInput("macOS could not decode this image for resizing.")
        }

        let directory = outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(baseName: input.deletingPathExtension().lastPathComponent + "-resized", extension: "jpg", directory: directory)
        let temporary = temporaryFile(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let type = UTType(filenameExtension: "jpg"),
              let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else {
            throw MorphError.invalidOutput("macOS could not create a JPEG output.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.1), 1.0)] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MorphError.invalidOutput("macOS could not finish resizing the image.") }
        try commit(temporary, to: output)
        return output
    }

    @discardableResult
    public static func mergePDFs(_ inputs: [URL], outputDirectory: URL? = nil) throws -> URL {
        guard inputs.count >= 2 else { throw MorphError.invalidInput("Choose at least two PDF files to merge.") }
        let documents = try inputs.map { url -> PDFDocument in
            guard url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url), document.pageCount > 0 else {
                throw MorphError.invalidInput("‘\(url.lastPathComponent)’ is not a readable PDF.")
            }
            return document
        }
        let directory = outputDirectory ?? inputs[0].deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(baseName: "Merged PDF", extension: "pdf", directory: directory)
        let temporary = temporaryFile(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let merged = PDFDocument()
        for document in documents {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let copy = page.copy() as? PDFPage else {
                    throw MorphError.invalidInput("Morph could not copy a page from one of the PDFs.")
                }
                merged.insert(copy, at: merged.pageCount)
            }
        }
        guard merged.pageCount > 0, merged.write(to: temporary), PDFDocument(url: temporary)?.pageCount == merged.pageCount else {
            throw MorphError.invalidOutput("PDFKit could not write and verify the merged PDF.")
        }
        try commit(temporary, to: output)
        return output
    }

    public static func splitPDF(_ input: URL, outputDirectory: URL? = nil) throws -> [URL] {
        guard let document = PDFDocument(url: input), document.pageCount > 0 else {
            throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
        }
        let directory = outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var outputs: [URL] = []
        do {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let copy = page.copy() as? PDFPage else {
                    throw MorphError.invalidInput("Morph could not copy PDF page \(index + 1).")
                }
                let output = uniqueURL(baseName: "\(input.deletingPathExtension().lastPathComponent)-page-\(String(format: "%03d", index + 1))", extension: "pdf", directory: directory)
                let temporary = temporaryFile(for: output)
                let singlePage = PDFDocument()
                singlePage.insert(copy, at: 0)
                guard singlePage.write(to: temporary), PDFDocument(url: temporary)?.pageCount == 1 else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw MorphError.invalidOutput("PDFKit could not write page \(index + 1).")
                }
                try commit(temporary, to: output)
                outputs.append(output)
            }
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output) }
            throw error
        }
        return outputs
    }

    @discardableResult
    public static func extractPDFPages(_ input: URL, pageRange: String, outputDirectory: URL? = nil) throws -> URL {
        guard let source = PDFDocument(url: input), source.pageCount > 0 else {
            throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
        }
        let pageNumbers = try parsePDFPageRanges(pageRange, pageCount: source.pageCount)
        let directory = outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(baseName: input.deletingPathExtension().lastPathComponent + "-pages", extension: "pdf", directory: directory)
        let temporary = temporaryFile(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let extracted = PDFDocument()
        extracted.documentAttributes = source.documentAttributes
        for pageNumber in pageNumbers {
            guard let page = source.page(at: pageNumber - 1), let copy = page.copy() as? PDFPage else {
                throw MorphError.invalidInput("Morph could not copy PDF page \(pageNumber).")
            }
            extracted.insert(copy, at: extracted.pageCount)
        }
        guard extracted.pageCount == pageNumbers.count,
              extracted.write(to: temporary),
              PDFDocument(url: temporary)?.pageCount == pageNumbers.count else {
            throw MorphError.invalidOutput("PDFKit could not write and verify the extracted pages.")
        }
        try commit(temporary, to: output)
        return output
    }

    public static func parsePDFPageRanges(_ selection: String, pageCount: Int) throws -> [Int] {
        let invalidSelection = MorphError.invalidInput("Use page numbers or ascending ranges, such as 1-3, 5.")
        guard pageCount > 0 else { throw invalidSelection }
        let items = selection.split(separator: ",", omittingEmptySubsequences: false)
        guard !items.isEmpty else { throw invalidSelection }

        var result: [Int] = []
        var seen = Set<Int>()
        for item in items {
            let rangeParts = item.split(separator: "-", omittingEmptySubsequences: false)
            guard rangeParts.count == 1 || rangeParts.count == 2 else { throw invalidSelection }
            let numbers = rangeParts.compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard numbers.count == rangeParts.count else { throw invalidSelection }
            let first = numbers[0]
            let last = numbers.count == 2 ? numbers[1] : first
            guard first >= 1, last <= pageCount else {
                throw MorphError.invalidInput("Page numbers must be between 1 and \(pageCount).")
            }
            guard first <= last else { throw invalidSelection }
            for number in first...last {
                guard seen.insert(number).inserted else {
                    throw MorphError.invalidInput("The page selection contains a duplicate number.")
                }
                result.append(number)
            }
        }
        guard !result.isEmpty else { throw invalidSelection }
        return result
    }

    @discardableResult
    public static func compressPDF(
        _ input: URL,
        preset: PDFCompressionPreset = .balanced,
        outputDirectory: URL? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> URL {
        guard let source = PDFDocument(url: input), source.pageCount > 0 else {
            throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
        }
        guard let ghostscript = ExecutableLocator.resolve(["gs"]) else {
            throw MorphError.missingEngine(.ghostscript)
        }

        let directory = outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(baseName: input.deletingPathExtension().lastPathComponent + "-compressed", extension: "pdf", directory: directory)
        let temporary = temporaryFile(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let result = try ProcessRunner.run(
            executable: ghostscript,
            arguments: [
                "-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET",
                "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.7",
                "-dPDFSETTINGS=\(preset.ghostscriptSetting)",
                "-sOutputFile=\(temporary.path)", input.path,
            ],
            cancellation: cancellation
        )
        guard result.status == 0 else {
            throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Ghostscript could not compress this PDF."
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let compressed = PDFDocument(url: temporary), compressed.pageCount == source.pageCount else {
            throw MorphError.invalidOutput("The compressed PDF did not preserve all source pages.")
        }
        try commit(temporary, to: output)
        return output
    }

    @discardableResult
    public static func extractZIP(_ input: URL, outputDirectory: URL? = nil) throws -> URL {
        guard input.pathExtension.lowercased() == "zip",
              let unzip = ExecutableLocator.resolve(["unzip"]),
              let ditto = ExecutableLocator.resolve(["ditto"]) else {
            throw MorphError.unsupportedInput(input)
        }
        let listing = try ProcessRunner.run(executable: unzip, arguments: ["-Z1", input.path])
        guard listing.status == 0 else { throw MorphError.invalidInput("The ZIP file could not be read.") }
        try validateArchivePaths(listing.stdout)

        let parent = outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = uniqueURL(baseName: input.deletingPathExtension().lastPathComponent, extension: "", directory: parent, isDirectory: true)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("morph-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let extraction = try ProcessRunner.run(executable: ditto, arguments: ["-x", "-k", input.path, staging.path])
        guard extraction.status == 0 else { throw MorphError.invalidInput(extraction.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        try ensureContainedItems(staging)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    public static func parseVideoTrimRange(start: String, end: String) throws -> (startSeconds: Double, durationSeconds: Double) {
        let startText = start.trimmingCharacters(in: .whitespacesAndNewlines)
        let endText = end.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let startSeconds = Double(startText), let endSeconds = Double(endText),
              startSeconds.isFinite, endSeconds.isFinite,
              startSeconds >= 0, endSeconds > startSeconds else {
            throw MorphError.invalidInput("Enter a non-negative start time and a later end time, in seconds.")
        }
        return (startSeconds, endSeconds - startSeconds)
    }

    @discardableResult
    public static func trimVideo(
        _ input: URL,
        startSeconds: Double,
        endSeconds: Double,
        outputDirectory: URL? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw MorphError.invalidInput("The selected video is no longer available.")
        }
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0, endSeconds > startSeconds else {
            throw MorphError.invalidInput("The end time must be later than a non-negative start time.")
        }
        guard let ffmpeg = ExecutableLocator.resolve(["ffmpeg"]),
              let ffprobe = ExecutableLocator.resolve(["ffprobe"]) else {
            throw MorphError.missingEngine(.ffmpeg)
        }

        let sourceDuration = try mediaDuration(input, ffprobe: ffprobe, cancellation: cancellation)
        guard endSeconds <= sourceDuration + 0.05 else {
            throw MorphError.invalidInput("The end time is beyond the video's duration of \(String(format: "%.2f", sourceDuration)) seconds.")
        }

        let directory = outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(baseName: input.deletingPathExtension().lastPathComponent + "-trimmed", extension: "mp4", directory: directory)
        let temporary = temporaryFile(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let range = try parseVideoTrimRange(start: String(startSeconds), end: String(endSeconds))
        let result = try ProcessRunner.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-ss", String(range.startSeconds), "-i", input.path,
            "-t", String(range.durationSeconds),
            "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
            "-c:v", "libx264", "-preset", "medium", "-crf", "22",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-f", "mp4",
            temporary.path,
        ], cancellation: cancellation)
        guard result.status == 0 else {
            throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "FFmpeg could not trim this video."
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try OutputValidator.validate(temporary, format: MorphFormat("mp4", "MP4", .video), engine: .ffmpeg)
        let outputDuration = try mediaDuration(temporary, ffprobe: ffprobe, cancellation: cancellation)
        guard abs(outputDuration - range.durationSeconds) <= max(0.25, range.durationSeconds * 0.05) else {
            throw MorphError.invalidOutput("FFmpeg produced a clip with an unexpected duration.")
        }
        if cancellation?.isCancelled == true { throw MorphError.cancelled }
        try commit(temporary, to: output)
        return output
    }

    private static func validateArchivePaths(_ listing: String) throws {
        for line in listing.split(separator: "\n") {
            let path = String(line).replacingOccurrences(of: "\\", with: "/")
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") {
                throw MorphError.invalidInput("The archive contains a path that escapes its extraction folder.")
            }
        }
    }

    private static func ensureContainedItems(_ root: URL) throws {
        let rootPath = root.standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in enumerator {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
            if !resolved.hasPrefix(rootPath) {
                throw MorphError.invalidInput("The archive contains a link that escapes its extraction folder.")
            }
        }
    }

    private static func mediaDuration(_ input: URL, ffprobe: URL, cancellation: CancellationToken?) throws -> Double {
        let result = try ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", input.path,
        ], cancellation: cancellation)
        guard result.status == 0,
              let duration = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
              duration.isFinite, duration > 0 else {
            throw MorphError.invalidInput("FFprobe could not read the video's duration.")
        }
        return duration
    }

    private static func uniqueURL(baseName: String, extension fileExtension: String, directory: URL, isDirectory: Bool = false) -> URL {
        func candidate(_ name: String) -> URL {
            let base = directory.appendingPathComponent(name, isDirectory: isDirectory)
            return fileExtension.isEmpty ? base : base.appendingPathExtension(fileExtension)
        }
        var result = candidate(baseName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: result.path) {
            result = candidate("\(baseName)-\(suffix)")
            suffix += 1
        }
        return result
    }

    private static func temporaryFile(for output: URL) -> URL {
        output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).morph-\(UUID().uuidString).partial")
    }

    private static func commit(_ temporary: URL, to output: URL) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw MorphError.processFailed("Morph refused to replace an existing file.")
        }
        do { try FileManager.default.moveItem(at: temporary, to: output) }
        catch { throw MorphError.processFailed("Morph could not save the output: \(error.localizedDescription)") }
    }
}
