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

public struct FileMetadataEdits: Hashable, Sendable {
    public var title: String?
    public var author: String?
    public var subject: String?
    public var keywords: [String]?

    public init(title: String? = nil, author: String? = nil, subject: String? = nil, keywords: [String]? = nil) {
        self.title = title
        self.author = author
        self.subject = subject
        self.keywords = keywords
    }

    public var hasChanges: Bool {
        title != nil || author != nil || subject != nil || keywords != nil
    }
}

public struct BatchRenameTarget: Identifiable, Hashable, Sendable {
    public let inputURL: URL
    public let outputURL: URL

    public var id: String { "\(inputURL.path)\u{0}\(outputURL.path)" }

    public init(inputURL: URL, outputURL: URL) {
        self.inputURL = inputURL
        self.outputURL = outputURL
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
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        append(iptc[kCGImagePropertyIPTCObjectName] ?? tiff[kCGImagePropertyTIFFImageDescription], label: "Title", to: &entries)
        append(iptc[kCGImagePropertyIPTCByline] ?? tiff[kCGImagePropertyTIFFArtist], label: "Author", to: &entries)
        append(iptc[kCGImagePropertyIPTCCaptionAbstract], label: "Subject", to: &entries)
        append(iptc[kCGImagePropertyIPTCKeywords], label: "Keywords", to: &entries)
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let latitude = gps[kCGImagePropertyGPSLatitude] as? NSNumber,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? NSNumber {
            let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            entries.append(FileMetadataEntry(label: "Location", value: "\(latitude)° \(latitudeRef), \(longitude)° \(longitudeRef)"))
        }
        return entries
    }

    @discardableResult
    public static func writeMetadataCopy(
        _ input: URL,
        edits: FileMetadataEdits,
        outputDirectory: URL? = nil
    ) throws -> URL {
        guard edits.hasChanges else {
            throw MorphError.invalidInput("Enter at least one metadata value to change.")
        }
        try validateMetadataEdits(edits)
        try validateRenamableFile(input)

        let fileExtension = input.pathExtension.lowercased()
        let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "tif", "tiff"]
        guard fileExtension == "pdf" || supportedImageExtensions.contains(fileExtension) else {
            throw MorphError.unsupportedInput(input)
        }
        if fileExtension != "pdf", edits.author != nil {
            throw MorphError.invalidInput("Image author editing is not supported by the native metadata writer. Select PDFs to edit author metadata.")
        }

        let directory = outputDirectory ?? input.deletingLastPathComponent()
        guard directory.isFileURL else {
            throw MorphError.invalidOutput("The metadata copy destination must be a folder on this Mac.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(
            baseName: input.deletingPathExtension().lastPathComponent + "-metadata",
            extension: fileExtension,
            directory: directory
        )
        let temporary = temporaryFile(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }

        if fileExtension == "pdf" {
            try writePDFMetadataCopy(input, edits: edits, temporary: temporary)
        } else {
            try writeImageMetadataCopy(input, edits: edits, temporary: temporary, expectedExtension: fileExtension)
        }

        try commit(temporary, to: output)
        return output
    }

    private static func validateMetadataEdits(_ edits: FileMetadataEdits) throws {
        let textValues = [edits.title, edits.author, edits.subject].compactMap { $0 }
        let validKeywords = edits.keywords.map { keywords in
            keywords.count <= 100
                && keywords.allSatisfy { $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { $0.value == 0 }) }
        } ?? true
        guard textValues.allSatisfy({ $0.utf8.count <= 4_096 && !$0.unicodeScalars.contains(where: { $0.value == 0 }) }),
              validKeywords else {
            throw MorphError.invalidInput("Metadata text is too long or contains an unsupported value.")
        }
        let keywordBytes = (edits.keywords ?? []).reduce(0) { $0 + $1.utf8.count }
        guard keywordBytes <= 8_192 else {
            throw MorphError.invalidInput("The combined keywords are too long.")
        }
    }

    private static func writePDFMetadataCopy(_ input: URL, edits: FileMetadataEdits, temporary: URL) throws {
        guard let source = PDFDocument(url: input), source.pageCount > 0 else {
            throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
        }
        let pageCount = source.pageCount
        var attributes = source.documentAttributes ?? [:]
        if let title = edits.title { attributes[PDFDocumentAttribute.titleAttribute] = title }
        if let author = edits.author { attributes[PDFDocumentAttribute.authorAttribute] = author }
        if let subject = edits.subject { attributes[PDFDocumentAttribute.subjectAttribute] = subject }
        if let keywords = edits.keywords { attributes[PDFDocumentAttribute.keywordsAttribute] = keywords }
        source.documentAttributes = attributes

        guard source.write(to: temporary),
              let edited = PDFDocument(url: temporary), edited.pageCount == pageCount else {
            throw MorphError.invalidOutput("macOS could not write a valid PDF metadata copy.")
        }
        let writtenAttributes = edited.documentAttributes ?? [:]
        guard pdfMetadataMatches(edits, attributes: writtenAttributes) else {
            throw MorphError.invalidOutput("The PDF copy did not retain the requested metadata values.")
        }
    }

    private static func pdfMetadataMatches(_ edits: FileMetadataEdits, attributes: [AnyHashable: Any]) -> Bool {
        if let title = edits.title, attributes[PDFDocumentAttribute.titleAttribute] as? String != title { return false }
        if let author = edits.author, attributes[PDFDocumentAttribute.authorAttribute] as? String != author { return false }
        if let subject = edits.subject, attributes[PDFDocumentAttribute.subjectAttribute] as? String != subject { return false }
        if let keywords = edits.keywords {
            let stored = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String]
                ?? (attributes[PDFDocumentAttribute.keywordsAttribute] as? String).map { [$0] }
            if stored != keywords { return false }
        }
        return true
    }

    private static func writeImageMetadataCopy(
        _ input: URL,
        edits: FileMetadataEdits,
        temporary: URL,
        expectedExtension: String
    ) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let sourceType = CGImageSourceGetType(source),
              let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw MorphError.invalidInput("macOS could not read this image's metadata.")
        }
        let expectedType = ["jpg", "jpeg"].contains(expectedExtension) ? UTType.jpeg.identifier : UTType.tiff.identifier
        guard (sourceType as String) == expectedType else {
            throw MorphError.invalidInput("The file contents do not match its JPEG or TIFF filename extension.")
        }
        let imageCount = CGImageSourceGetCount(source)
        guard imageCount > 0 else {
            throw MorphError.invalidInput("The selected image contains no readable frames.")
        }

        var iptc = sourceProperties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        if let title = edits.title { iptc[kCGImagePropertyIPTCObjectName] = title }
        if let subject = edits.subject { iptc[kCGImagePropertyIPTCCaptionAbstract] = subject }
        if let keywords = edits.keywords { iptc[kCGImagePropertyIPTCKeywords] = keywords }
        var properties: [CFString: Any] = [:]
        if edits.title != nil || edits.subject != nil || edits.keywords != nil {
            properties[kCGImagePropertyIPTCDictionary] = iptc
        }

        let destinationOptions = [kCGImageDestinationMergeMetadata: true] as CFDictionary
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            sourceType,
            imageCount,
            destinationOptions
        ) else {
            throw MorphError.invalidOutput("macOS could not create an image metadata copy.")
        }
        for index in 0..<imageCount {
            CGImageDestinationAddImageFromSource(destination, source, index, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination),
              let edited = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              CGImageSourceGetType(edited) == sourceType,
              CGImageSourceGetCount(edited) == imageCount else {
            throw MorphError.invalidOutput("macOS could not write a valid JPEG or TIFF metadata copy.")
        }
        for index in 0..<imageCount {
            guard let original = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let written = CGImageSourceCopyPropertiesAtIndex(edited, index, nil) as? [CFString: Any] else {
                throw MorphError.invalidOutput("macOS could not validate the written image metadata.")
            }
            guard (original[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == (written[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  (original[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == (written[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
                throw MorphError.invalidOutput("The image metadata copy changed its dimensions.")
            }
            let missingMetadata = imageMetadataMismatches(edits, properties: written)
            guard missingMetadata.isEmpty else {
                throw MorphError.invalidOutput("macOS did not retain these image metadata fields: \(missingMetadata.joined(separator: ", ")).")
            }
        }
    }

    private static func imageMetadataMismatches(_ edits: FileMetadataEdits, properties: [CFString: Any]) -> [String] {
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        var missing: [String] = []
        if let title = edits.title {
            if iptc[kCGImagePropertyIPTCObjectName] as? String != title { missing.append("title (IPTC)") }
        }
        if let subject = edits.subject, iptc[kCGImagePropertyIPTCCaptionAbstract] as? String != subject { missing.append("subject (IPTC)") }
        if let keywords = edits.keywords, imageStrings(iptc[kCGImagePropertyIPTCKeywords]) != keywords { missing.append("keywords (IPTC)") }
        return missing
    }

    private static func imageStrings(_ value: Any?) -> [String]? {
        if let values = value as? [String] { return values }
        if let value = value as? String { return [value] }
        if let values = value as? [NSString] { return values.map(String.init) }
        return nil
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

    public static func planBatchRenamedCopies(
        inputs: [URL],
        prefix: String,
        outputDirectories: [URL]
    ) throws -> [BatchRenameTarget] {
        guard !inputs.isEmpty, inputs.count == outputDirectories.count else {
            throw MorphError.invalidInput("Choose at least one file and a matching output folder for each file.")
        }
        let cleanPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasUnsafeCharacter = cleanPrefix.unicodeScalars.contains {
            $0 == "/" || $0 == ":" || CharacterSet.controlCharacters.contains($0)
        }
        guard !cleanPrefix.isEmpty, cleanPrefix.count <= 48,
              !cleanPrefix.hasPrefix("."), !cleanPrefix.hasSuffix("."),
              !cleanPrefix.hasSuffix(" "), !hasUnsafeCharacter else {
            throw MorphError.invalidInput("Use a prefix of 1–48 characters without slashes, colons, control characters, or a leading or trailing dot.")
        }

        var plannedPaths = Set<String>()
        var targets: [BatchRenameTarget] = []
        for (index, pair) in zip(inputs, outputDirectories).enumerated() {
            let (input, outputDirectory) = pair
            try validateRenamableFile(input)
            guard outputDirectory.isFileURL else {
                throw MorphError.invalidInput("The output folder must be on this Mac.")
            }

            let sequence = String(format: "%03d", index + 1)
            let normalizedDirectory = outputDirectory.standardizedFileURL
            var collision = 1
            var outputURL: URL
            while true {
                let collisionMarker = collision == 1 ? "" : "-\(collision)"
                let name = "\(cleanPrefix)-\(sequence)\(collisionMarker)-\(input.lastPathComponent)"
                guard name.utf8.count <= 240 else {
                    throw MorphError.invalidInput("‘\(input.lastPathComponent)’ is too long to add the rename prefix safely.")
                }
                outputURL = normalizedDirectory.appendingPathComponent(name, isDirectory: false)
                let key = collisionKey(outputURL)
                if !FileManager.default.fileExists(atPath: outputURL.path), plannedPaths.insert(key).inserted {
                    break
                }
                collision += 1
            }
            targets.append(BatchRenameTarget(inputURL: input, outputURL: outputURL))
        }
        return targets
    }

    @discardableResult
    public static func createRenamedCopy(
        _ target: BatchRenameTarget,
        cancellation: CancellationToken? = nil
    ) throws -> URL {
        guard cancellation?.isCancelled != true else { throw MorphError.cancelled }
        try validateRenamableFile(target.inputURL)
        guard target.outputURL.isFileURL,
              target.outputURL.lastPathComponent != ".",
              target.outputURL.lastPathComponent != "..",
              target.outputURL.deletingLastPathComponent().standardizedFileURL.path == target.outputURL.deletingLastPathComponent().path else {
            throw MorphError.invalidOutput("Morph could not use the planned output path.")
        }
        guard collisionKey(target.inputURL) != collisionKey(target.outputURL) else {
            throw MorphError.invalidOutput("Morph will not copy a file over its original.")
        }

        let manager = FileManager.default
        let directory = target.outputURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !manager.fileExists(atPath: target.outputURL.path) else {
            throw MorphError.processFailed("‘\(target.outputURL.lastPathComponent)’ already exists. Review the preview and try again.")
        }

        let staging = directory.appendingPathComponent(".morph-rename-\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: staging) }
        do {
            try manager.copyItem(at: target.inputURL, to: staging)
        } catch {
            throw MorphError.processFailed("Morph could not copy ‘\(target.inputURL.lastPathComponent)’: \(error.localizedDescription)")
        }
        guard cancellation?.isCancelled != true else { throw MorphError.cancelled }
        let sourceSize = (try manager.attributesOfItem(atPath: target.inputURL.path)[.size] as? NSNumber)?.int64Value
        let stagedSize = (try manager.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value
        guard sourceSize == stagedSize else {
            throw MorphError.invalidOutput("The renamed copy did not match the source file size.")
        }
        try commit(staging, to: target.outputURL)
        return target.outputURL
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

    @discardableResult
    public static func compressVideo(
        _ input: URL,
        options: VideoCompressionOptions = VideoCompressionOptions(),
        outputDirectory: URL? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw MorphError.invalidInput("The selected video is no longer available.")
        }
        guard let ffmpeg = ExecutableLocator.resolve(["ffmpeg"]),
              let ffprobe = ExecutableLocator.resolve(["ffprobe"]) else {
            throw MorphError.missingEngine(.ffmpeg)
        }

        let sourceDuration = try mediaDuration(input, ffprobe: ffprobe, cancellation: cancellation)
        let sourceDimensions = try mediaDimensions(input, ffprobe: ffprobe, cancellation: cancellation)
        let directory = outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(baseName: input.deletingPathExtension().lastPathComponent + "-compressed", extension: "mp4", directory: directory)
        let temporary = temporaryFile(for: output)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let result = try ProcessRunner.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
            "-i", input.path,
            "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-map_chapters", "0",
            "-vf", options.resolutionLimit.ffmpegFilter,
            "-c:v", "libx264", "-preset", "medium", "-crf", String(options.quality.ffmpegCRF),
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", options.quality.audioBitrate,
            "-movflags", "+faststart", "-f", "mp4", temporary.path,
        ], cancellation: cancellation)
        guard result.status == 0 else {
            throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "FFmpeg could not compress this video."
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try OutputValidator.validate(temporary, format: MorphFormat("mp4", "MP4", .video), engine: .ffmpeg)
        let outputDuration = try mediaDuration(temporary, ffprobe: ffprobe, cancellation: cancellation)
        guard abs(outputDuration - sourceDuration) <= max(0.5, sourceDuration * 0.02) else {
            throw MorphError.invalidOutput("FFmpeg produced a compressed video with an unexpected duration.")
        }
        let outputDimensions = try mediaDimensions(temporary, ffprobe: ffprobe, cancellation: cancellation)
        let maximumWidth = min(sourceDimensions.width, options.resolutionLimit.maximumWidth ?? sourceDimensions.width)
        let maximumHeight = min(sourceDimensions.height, options.resolutionLimit.maximumHeight ?? sourceDimensions.height)
        guard outputDimensions.width <= maximumWidth,
              outputDimensions.height <= maximumHeight,
              outputDimensions.width > 0,
              outputDimensions.height > 0 else {
            throw MorphError.invalidOutput("FFmpeg produced video dimensions outside the selected resolution limit.")
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

    private static func validateRenamableFile(_ input: URL) throws {
        guard input.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: input.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MorphError.invalidInput("‘\(input.lastPathComponent)’ is not an available regular file.")
        }
    }

    private static func collisionKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
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

    private static func mediaDimensions(_ input: URL, ffprobe: URL, cancellation: CancellationToken?) throws -> (width: Int, height: Int) {
        let result = try ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
            "-of", "csv=s=x:p=0", input.path,
        ], cancellation: cancellation)
        let dimensions = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x")
        guard result.status == 0, dimensions.count == 2,
              let width = Int(dimensions[0]), let height = Int(dimensions[1]), width > 0, height > 0 else {
            throw MorphError.invalidInput("FFprobe could not read a video stream and its dimensions.")
        }
        return (width, height)
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
