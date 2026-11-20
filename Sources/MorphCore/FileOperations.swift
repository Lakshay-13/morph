import CArchive
import Darwin
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
            let snapshot = try PrivateInputSnapshot(
                input: input,
                fileExtension: fileExtension,
                maximumBytes: NativePDFEngine.maximumPDFInputBytes,
                cancellation: CancellationToken()
            )
            try NativePDFEngine.validateInput(snapshot.fileURL)
            guard let document = PDFDocument(url: snapshot.fileURL), document.pageCount > 0 else {
                throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
            }
            try NativePDFEngine.validatePageCount(document.pageCount)
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

        let snapshot = try PrivateInputSnapshot(
            input: input,
            fileExtension: fileExtension,
            maximumBytes: NativeImageEngine.maximumInputBytes,
            cancellation: CancellationToken()
        )
        try NativeImageEngine.validateInput(snapshot.fileURL)
        guard let source = CGImageSourceCreateWithURL(snapshot.fileURL as CFURL, nil),
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
        outputDirectory: URL? = nil,
        stripLocationMetadata: Bool = true
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
        let transaction = try PrivateOutputTransaction(outputURL: output)
        let temporary = transaction.temporaryOutputURL

        if fileExtension == "pdf" {
            try writePDFMetadataCopy(input, edits: edits, temporary: temporary)
        } else {
            try writeImageMetadataCopy(
                input,
                edits: edits,
                temporary: temporary,
                expectedExtension: fileExtension,
                stripLocationMetadata: stripLocationMetadata
            )
        }

        return try transaction.publishUnique()
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
        let snapshot = try PrivateInputSnapshot(
            input: input,
            fileExtension: "pdf",
            maximumBytes: NativePDFEngine.maximumPDFInputBytes,
            cancellation: CancellationToken()
        )
        try NativePDFEngine.validateInput(snapshot.fileURL)
        guard let source = PDFDocument(url: snapshot.fileURL), source.pageCount > 0 else {
            throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
        }
        try NativePDFEngine.validatePageCount(source.pageCount)
        let pageCount = source.pageCount
        var attributes = source.documentAttributes ?? [:]
        if let title = edits.title { attributes[PDFDocumentAttribute.titleAttribute] = title }
        if let author = edits.author { attributes[PDFDocumentAttribute.authorAttribute] = author }
        if let subject = edits.subject { attributes[PDFDocumentAttribute.subjectAttribute] = subject }
        if let keywords = edits.keywords { attributes[PDFDocumentAttribute.keywordsAttribute] = keywords }
        source.documentAttributes = attributes

        guard source.write(to: temporary),
              NativePDFEngine.hasPDFHeader(temporary),
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
        expectedExtension: String,
        stripLocationMetadata: Bool
    ) throws {
        let snapshot = try PrivateInputSnapshot(
            input: input,
            fileExtension: expectedExtension,
            maximumBytes: NativeImageEngine.maximumInputBytes,
            cancellation: CancellationToken()
        )
        try NativeImageEngine.validateInput(snapshot.fileURL)
        let expectedType = ["jpg", "jpeg"].contains(expectedExtension) ? UTType.jpeg.identifier : UTType.tiff.identifier
        guard let source = CGImageSourceCreateWithURL(snapshot.fileURL as CFURL, nil),
              let sourceType = CGImageSourceGetType(source),
              (sourceType as String) == expectedType else {
            throw MorphError.invalidInput("The file contents do not match its JPEG or TIFF filename extension.")
        }
        guard CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else {
            throw MorphError.invalidInput("macOS could not read this image's metadata.")
        }
        let imageCount = CGImageSourceGetCount(source)
        guard imageCount > 0 else {
            throw MorphError.invalidInput("The selected image contains no readable frames.")
        }

        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            sourceType,
            imageCount,
            nil
        ) else {
            throw MorphError.invalidOutput("macOS could not create an image metadata copy.")
        }
        for index in 0..<imageCount {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw MorphError.invalidInput("macOS could not decode image frame \(index + 1) while editing metadata.")
            }
            let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            var properties = NativeImageEngine.properties(
                preservingLocationMetadata: !stripLocationMetadata,
                from: sourceProperties
            )
            var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            if let title = edits.title { iptc[kCGImagePropertyIPTCObjectName] = title }
            if let subject = edits.subject { iptc[kCGImagePropertyIPTCCaptionAbstract] = subject }
            if let keywords = edits.keywords { iptc[kCGImagePropertyIPTCKeywords] = keywords }
            properties[kCGImagePropertyIPTCDictionary] = iptc
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
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
        let snapshot = try PrivateInputSnapshot(
            input: input,
            fileExtension: input.pathExtension.lowercased(),
            maximumBytes: NativeImageEngine.maximumInputBytes,
            cancellation: CancellationToken()
        )
        try NativeImageEngine.validateInput(snapshot.fileURL)
        guard let source = CGImageSourceCreateWithURL(snapshot.fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw MorphError.invalidInput("macOS could not read the image dimensions.")
        }
        try NativeImageEngine.validateSourceFrames(source)

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
        let transaction = try PrivateOutputTransaction(outputURL: output)
        let temporary = transaction.temporaryOutputURL
        guard let type = UTType(filenameExtension: "jpg"),
              let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else {
            throw MorphError.invalidOutput("macOS could not create a JPEG output.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.1), 1.0)] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MorphError.invalidOutput("macOS could not finish resizing the image.") }
        return try transaction.publishUnique()
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
        try createRenamedCopy(target, cancellation: cancellation, beforePublication: nil)
    }

    static func createRenamedCopy(
        _ target: BatchRenameTarget,
        cancellation: CancellationToken?,
        beforePublication: (() throws -> Void)?
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

        let stagedName = "renamed-copy.partial"
        let transaction = try PrivateOutputTransaction(outputURL: target.outputURL, temporaryFileName: stagedName)
        let staging = transaction.temporaryOutputURL
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
        try beforePublication?()
        try transaction.publish(cancellation: cancellation)
        return target.outputURL
    }

    @discardableResult
    public static func mergePDFs(_ inputs: [URL], outputDirectory: URL? = nil) throws -> URL {
        guard inputs.count >= 2 else { throw MorphError.invalidInput("Choose at least two PDF files to merge.") }
        guard inputs.count <= NativePDFEngine.maximumPageCount else {
            throw MorphError.invalidInput("PDF merges are limited to 1,000 input files.")
        }
        let snapshots = try snapshotPDFMergeInputs(inputs)
        let documents = try zip(inputs, snapshots).map { pair -> PDFDocument in
            let (url, snapshot) = pair
            guard url.pathExtension.lowercased() == "pdf",
                  let document = PDFDocument(url: snapshot.fileURL), document.pageCount > 0 else {
                throw MorphError.invalidInput("‘\(url.lastPathComponent)’ is not a readable PDF.")
            }
            try NativePDFEngine.validatePageCount(document.pageCount)
            return document
        }
        guard documents.reduce(0, { $0 + $1.pageCount }) <= NativePDFEngine.maximumPageCount else {
            throw MorphError.invalidInput("PDF merges are limited to 1,000 pages total.")
        }
        let directory = outputDirectory ?? inputs[0].deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(baseName: "Merged PDF", extension: "pdf", directory: directory)
        let transaction = try PrivateOutputTransaction(outputURL: output)
        let temporary = transaction.temporaryOutputURL
        let merged = PDFDocument()
        for document in documents {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let copy = page.copy() as? PDFPage else {
                    throw MorphError.invalidInput("Morph could not copy a page from one of the PDFs.")
                }
                merged.insert(copy, at: merged.pageCount)
            }
        }
        guard merged.pageCount > 0,
              merged.write(to: temporary),
              NativePDFEngine.hasPDFHeader(temporary) else {
            throw MorphError.invalidOutput("PDFKit could not write and verify the merged PDF.")
        }
        try ConversionOutputLimits.validate(temporary, maximumBytes: NativePDFEngine.maximumGeneratedBytes)
        guard PDFDocument(url: temporary)?.pageCount == merged.pageCount else {
            throw MorphError.invalidOutput("PDFKit could not verify every page in the merged PDF.")
        }
        return try transaction.publishUnique()
    }

    public static func splitPDF(
        _ input: URL,
        outputDirectory: URL? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> [URL] {
        try splitPDF(
            input,
            outputDirectory: outputDirectory,
            cancellation: cancellation,
            beforePageProcessing: nil
        )
    }

    static func splitPDF(
        _ input: URL,
        outputDirectory: URL?,
        cancellation: CancellationToken?,
        beforePageProcessing: ((Int) throws -> Void)?
    ) throws -> [URL] {
        let activeCancellation = cancellation ?? CancellationToken()
        if activeCancellation.isCancelled { throw MorphError.cancelled }
        let snapshot = try snapshotPDFInput(input, cancellation: activeCancellation)
        guard let document = PDFDocument(url: snapshot.fileURL), document.pageCount > 0 else {
            throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
        }
        try NativePDFEngine.validatePageCount(document.pageCount)
        let directory = outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destinationStage = try PrivateOutputStage(parentDirectory: directory)
        var outputs: [PublishedFileIdentity] = []
        var totalOutputBytes: UInt64 = 0
        do {
            for index in 0..<document.pageCount {
                if activeCancellation.isCancelled { throw MorphError.cancelled }
                try beforePageProcessing?(index)
                guard let page = document.page(at: index), let copy = page.copy() as? PDFPage else {
                    throw MorphError.invalidInput("Morph could not copy PDF page \(index + 1).")
                }
                let output = uniqueURL(baseName: "\(input.deletingPathExtension().lastPathComponent)-page-\(String(format: "%03d", index + 1))", extension: "pdf", directory: directory)
                guard destinationStage.outputDirectoryStillMatches(for: output) else {
                    throw MorphError.invalidOutput("The selected PDF output folder moved during splitting. Choose it again and retry.")
                }
                let fileName = "page-\(String(format: "%03d", index + 1)).partial.pdf"
                let pageStage = try PrivateOutputStage(
                    parentDirectory: FileManager.default.temporaryDirectory,
                    primaryFileName: fileName
                )
                let temporary = try pageStage.temporaryOutputURL()
                let singlePage = PDFDocument()
                singlePage.insert(copy, at: 0)
                guard singlePage.write(to: temporary),
                      NativePDFEngine.hasPDFHeader(temporary),
                      PDFDocument(url: temporary)?.pageCount == 1 else {
                    throw MorphError.invalidOutput("PDFKit could not write page \(index + 1).")
                }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path),
                      let size = attributes[.size] as? NSNumber,
                      size.int64Value > 0 else {
                    throw MorphError.invalidOutput("PDFKit produced an empty split page.")
                }
                let pageBytes = UInt64(size.int64Value)
                guard pageBytes <= NativePDFEngine.maximumPDFInputBytes,
                      totalOutputBytes <= NativePDFEngine.maximumGeneratedBytes - pageBytes else {
                    throw MorphError.invalidOutput("Split PDF pages may not exceed 1 GB total or 512 MB per page.")
                }
                totalOutputBytes += pageBytes
                guard !activeCancellation.isCancelled else { throw MorphError.cancelled }
                guard pageStage.stagedFileStillMatchesPath(named: fileName, url: temporary),
                      destinationStage.outputDirectoryStillMatches(for: output) else {
                    throw MorphError.invalidOutput("The selected PDF output folder moved during splitting. Choose it again and retry.")
                }
                try destinationStage.copyValidatedFile(
                    named: fileName,
                    from: pageStage,
                    to: fileName,
                    for: output,
                    cancellation: activeCancellation
                )
                _ = try destinationStage.publishUnique(fileName: fileName, to: output)
                guard let identity = destinationStage.lastPublishedIdentity else {
                    throw MorphError.invalidOutput("Morph could not verify a split PDF page after saving it.")
                }
                outputs.append(identity)
            }
        } catch {
            guard rollbackSplitOutputs(outputs, using: destinationStage) else {
                throw MorphError.invalidOutput("PDF splitting failed, and Morph could not safely remove every partial page because an output path changed. No unrelated item was deleted; inspect the output folder before retrying.")
            }
            throw error
        }
        guard outputs.last.map({ destinationStage.outputDirectoryStillMatches(for: $0.outputURL) }) == true else {
            guard rollbackSplitOutputs(outputs, using: destinationStage) else {
                throw MorphError.invalidOutput("The selected PDF output folder moved after splitting, and Morph could not safely remove every partial page. Inspect the original folder before retrying.")
            }
            throw MorphError.invalidOutput("The selected PDF output folder moved during splitting. Choose it again and retry.")
        }
        return outputs.map(\.outputURL)
    }

    @discardableResult
    public static func extractPDFPages(
        _ input: URL,
        pageRange: String,
        outputDirectory: URL? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> URL {
        if cancellation?.isCancelled == true { throw MorphError.cancelled }
        let snapshot = try snapshotPDFInput(input, cancellation: cancellation)
        guard let source = PDFDocument(url: snapshot.fileURL), source.pageCount > 0 else {
            throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
        }
        try NativePDFEngine.validatePageCount(source.pageCount)
        let pageNumbers = try parsePDFPageRanges(pageRange, pageCount: source.pageCount)
        let directory = outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(baseName: input.deletingPathExtension().lastPathComponent + "-pages", extension: "pdf", directory: directory)
        let transaction = try PrivateOutputTransaction(outputURL: output)
        let temporary = transaction.temporaryOutputURL

        let extracted = PDFDocument()
        extracted.documentAttributes = source.documentAttributes
        for pageNumber in pageNumbers {
            if cancellation?.isCancelled == true { throw MorphError.cancelled }
            guard let page = source.page(at: pageNumber - 1), let copy = page.copy() as? PDFPage else {
                throw MorphError.invalidInput("Morph could not copy PDF page \(pageNumber).")
            }
            extracted.insert(copy, at: extracted.pageCount)
        }
        if cancellation?.isCancelled == true { throw MorphError.cancelled }
        guard extracted.pageCount == pageNumbers.count,
              extracted.write(to: temporary),
              NativePDFEngine.hasPDFHeader(temporary),
              PDFDocument(url: temporary)?.pageCount == pageNumbers.count else {
            throw MorphError.invalidOutput("PDFKit could not write and verify the extracted pages.")
        }
        if cancellation?.isCancelled == true { throw MorphError.cancelled }
        return try transaction.publishUnique(cancellation: cancellation)
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
        let inputSnapshot = try snapshotPDFInput(input, cancellation: cancellation)
        try NativePDFEngine.validateHeaderForGhostscript(inputSnapshot.fileURL)
        guard let ghostscript = ExecutableLocator.resolve(["gs"]) else {
            throw MorphError.missingEngine(.ghostscript)
        }
        try EngineSecurityPolicy.validateExecutable(ghostscript, for: .ghostscript, cancellation: cancellation)
        guard let source = PDFDocument(url: inputSnapshot.fileURL), source.pageCount > 0 else {
            throw MorphError.invalidInput("The selected PDF is unreadable or has no pages.")
        }
        try NativePDFEngine.validatePageCount(source.pageCount)

        let directory = outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(baseName: input.deletingPathExtension().lastPathComponent + "-compressed", extension: "pdf", directory: directory)
        let transaction = try PrivateOutputTransaction(outputURL: output)
        let temporary = transaction.temporaryOutputURL

        let result = try ProcessRunner.run(
            executable: ghostscript,
            arguments: [
                "-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET",
                "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.7",
                "-dPDFSETTINGS=\(preset.ghostscriptSetting)",
                "-sOutputFile=\(temporary.path)", inputSnapshot.fileURL.path,
            ],
            cancellation: cancellation,
            timeout: 5 * 60,
            outputFileLimit: ProcessOutputFileLimit(url: temporary, maximumBytes: NativePDFEngine.maximumGeneratedBytes),
            sandboxReadableDirectories: [inputSnapshot.fileURL.deletingLastPathComponent()],
            sandboxWritableDirectories: [temporary.deletingLastPathComponent()],
            restrictedSandbox: true
        )
        guard result.status == 0 else {
            throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Ghostscript could not compress this PDF."
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try ConversionOutputLimits.validate(temporary, maximumBytes: NativePDFEngine.maximumGeneratedBytes)
        guard NativePDFEngine.hasPDFHeader(temporary),
              let compressed = PDFDocument(url: temporary), compressed.pageCount == source.pageCount else {
            throw MorphError.invalidOutput("The compressed PDF did not preserve all source pages.")
        }
        return try transaction.publishUnique(cancellation: cancellation)
    }

    @discardableResult
    public static func extractZIP(
        _ input: URL,
        outputDirectory: URL? = nil,
        cancellation: CancellationToken = CancellationToken()
    ) throws -> URL {
        guard input.pathExtension.lowercased() == "zip" else {
            throw MorphError.unsupportedInput(input)
        }
        if cancellation.isCancelled { throw MorphError.cancelled }

        let parent = outputDirectory ?? input.deletingLastPathComponent()
        let containingDirectory = parent.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: containingDirectory, withIntermediateDirectories: true)
        let containingDescriptor = containingDirectory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard containingDescriptor >= 0 else {
            throw MorphError.invalidOutput("Morph could not safely open the chosen extraction folder.")
        }
        defer { close(containingDescriptor) }

        let parentName = parent.lastPathComponent
        var existingInfo = stat()
        let existingStatus = parentName.withCString {
            fstatat(containingDescriptor, $0, &existingInfo, AT_SYMLINK_NOFOLLOW)
        }
        let parentDescriptor: Int32
        var createdParent = false
        if existingStatus == 0 {
            parentDescriptor = parentName.withCString {
                openat(containingDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            }
        } else if errno == ENOENT {
            try validateArchiveExtractionParent(containingDescriptor)
            let createStatus = parentName.withCString { mkdirat(containingDescriptor, $0, mode_t(0o755)) }
            guard createStatus == 0 else {
                throw MorphError.invalidOutput("Morph could not safely create the chosen extraction folder.")
            }
            createdParent = true
            parentDescriptor = parentName.withCString {
                openat(containingDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
        } else {
            throw MorphError.invalidOutput("Morph could not safely inspect the chosen extraction folder.")
        }
        guard parentDescriptor >= 0 else {
            if createdParent { _ = parentName.withCString { unlinkat(containingDescriptor, $0, AT_REMOVEDIR) } }
            throw MorphError.invalidOutput("Morph could not safely open the chosen extraction folder.")
        }
        defer { close(parentDescriptor) }
        do {
            try validateArchiveExtractionParent(parentDescriptor)
        } catch {
            if createdParent { _ = parentName.withCString { unlinkat(containingDescriptor, $0, AT_REMOVEDIR) } }
            throw error
        }
        StaleMorphStageCleanup.remove(in: parent)

        let stagingName = ".morph-extract-\(UUID().uuidString)"
        let stagingCreated = stagingName.withCString { mkdirat(parentDescriptor, $0, mode_t(0o700)) }
        guard stagingCreated == 0 else {
            if createdParent { _ = parentName.withCString { unlinkat(containingDescriptor, $0, AT_REMOVEDIR) } }
            throw MorphError.invalidOutput("Morph could not create a private archive staging folder.")
        }
        let stagingDescriptor = stagingName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard stagingDescriptor >= 0 else {
            _ = stagingName.withCString { unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
            if createdParent { _ = parentName.withCString { unlinkat(containingDescriptor, $0, AT_REMOVEDIR) } }
            throw MorphError.invalidOutput("Morph could not safely open its archive staging folder.")
        }
        guard morph_prepare_private_directory(stagingDescriptor) == 0 else {
            let reason = String(cString: strerror(errno))
            close(stagingDescriptor)
            _ = stagingName.withCString { unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
            if createdParent { _ = parentName.withCString { unlinkat(containingDescriptor, $0, AT_REMOVEDIR) } }
            throw MorphError.invalidOutput("Morph could not remove inherited access from its archive staging folder: \(reason).")
        }
        do {
            try StaleMorphStageCleanup.createOwnershipMarker(
                in: parentDescriptor,
                directoryDescriptor: stagingDescriptor,
                directoryName: stagingName
            )
        } catch {
            try? ArchiveExtractor.removeContents(of: stagingDescriptor)
            close(stagingDescriptor)
            _ = stagingName.withCString { unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
            _ = StaleMorphStageCleanup.removeOwnershipMarker(in: parentDescriptor, directoryName: stagingName)
            if createdParent { _ = parentName.withCString { unlinkat(containingDescriptor, $0, AT_REMOVEDIR) } }
            throw error
        }
        var published = false
        defer {
            if !published {
                try? ArchiveExtractor.removeContents(of: stagingDescriptor)
                var openedInfo = stat()
                var currentInfo = stat()
                if fstat(stagingDescriptor, &openedInfo) == 0,
                   stagingName.withCString({ fstatat(parentDescriptor, $0, &currentInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
                   openedInfo.st_dev == currentInfo.st_dev,
                   openedInfo.st_ino == currentInfo.st_ino {
                    if stagingName.withCString({ unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 {
                        _ = StaleMorphStageCleanup.removeOwnershipMarker(in: parentDescriptor, directoryName: stagingName)
                    }
                }
                if createdParent { _ = parentName.withCString { unlinkat(containingDescriptor, $0, AT_REMOVEDIR) } }
            }
            close(stagingDescriptor)
        }

        try ArchiveExtractor.extract(input: input, toDirectoryDescriptor: stagingDescriptor, cancellation: cancellation)
        if cancellation.isCancelled { throw MorphError.cancelled }

        var openedInfo = stat()
        var currentInfo = stat()
        guard fstat(stagingDescriptor, &openedInfo) == 0,
              stagingName.withCString({ fstatat(parentDescriptor, $0, &currentInfo, AT_SYMLINK_NOFOLLOW) }) == 0,
              openedInfo.st_dev == currentInfo.st_dev,
              openedInfo.st_ino == currentInfo.st_ino else {
            throw MorphError.invalidOutput("Morph's archive staging folder changed before it could be published.")
        }

        return try publishArchiveDirectory(
            baseName: input.deletingPathExtension().lastPathComponent,
            parent: parent,
            parentDescriptor: parentDescriptor,
            stagingName: stagingName,
            stagingDescriptor: stagingDescriptor,
            didPublish: {
                published = true
                _ = StaleMorphStageCleanup.removeOwnershipMarker(in: parentDescriptor, directoryName: stagingName)
            }
        )
    }

    static func publishArchiveDirectory(
        baseName: String,
        parent: URL,
        parentDescriptor: Int32,
        stagingName: String,
        stagingDescriptor: Int32,
        didPublish: () -> Void = {},
        afterRename: (() throws -> Void)? = nil
    ) throws -> URL {
        guard PinnedDirectoryPath.matches(parent, descriptor: parentDescriptor),
              PinnedDirectoryPath.entry(named: stagingName, in: parentDescriptor, matches: stagingDescriptor) else {
            throw MorphError.invalidOutput("Morph's extraction folder moved before the extracted files could be published.")
        }

        let trimmedBaseName = baseName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let visibleBaseName = trimmedBaseName.isEmpty ? "Extracted Files" : trimmedBaseName
        var suffix = 1
        let destinationName: String
        while true {
            let candidate = suffix == 1 ? visibleBaseName : "\(visibleBaseName)-\(suffix)"
            let result = stagingName.withCString { sourceName in
                candidate.withCString { destinationName in
                    renameatx_np(parentDescriptor, sourceName, parentDescriptor, destinationName, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 {
                destinationName = candidate
                didPublish()
                break
            }
            guard errno == EEXIST else {
                throw MorphError.invalidOutput("Morph could not safely publish the extracted archive: \(String(cString: strerror(errno))).")
            }
            suffix += 1
            guard suffix <= 10_000 else { throw MorphError.invalidOutput("Morph could not find a safe name for the extracted folder.") }
        }

        try afterRename?()
        guard PinnedDirectoryPath.matches(parent, descriptor: parentDescriptor),
              PinnedDirectoryPath.entry(named: destinationName, in: parentDescriptor, matches: stagingDescriptor) else {
            throw MorphError.invalidOutput("The selected extraction folder moved while Morph was extracting. Morph could not verify a current result location, so it did not report the extraction as successful.")
        }
        return parent.appendingPathComponent(destinationName, isDirectory: true)
    }

    static func rollbackSplitOutputs(_ outputs: [PublishedFileIdentity]) -> Bool {
        var removedAll = true
        for output in outputs where !PublishedFileCleanup.removeIfUnchanged(output) {
            removedAll = false
        }
        return removedAll
    }

    private static func rollbackSplitOutputs(_ outputs: [PublishedFileIdentity], using staging: PrivateOutputStage) -> Bool {
        var removedAll = true
        for output in outputs where !staging.removePublishedFileIfUnchanged(output) {
            removedAll = false
        }
        return removedAll
    }

    private static func validateArchiveExtractionParent(_ descriptor: Int32) throws {
        try OutputDirectorySecurity.validate(descriptor)
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
        cancellation: CancellationToken? = nil,
        stripLocationMetadata: Bool = true
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
        try EngineSecurityPolicy.validateExecutable(ffmpeg, for: .ffmpeg, cancellation: cancellation)
        try EngineSecurityPolicy.validateExecutable(ffprobe, for: .ffmpeg, cancellation: cancellation)

        let inputSnapshot = try PrivateInputSnapshot(
            input: input,
            fileExtension: input.pathExtension.lowercased(),
            cancellation: cancellation ?? CancellationToken()
        )

        let sourceDuration = try mediaDuration(inputSnapshot.fileURL, ffprobe: ffprobe, cancellation: cancellation)
        guard endSeconds <= sourceDuration + 0.05 else {
            throw MorphError.invalidInput("The end time is beyond the video's duration of \(String(format: "%.2f", sourceDuration)) seconds.")
        }

        let directory = outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(baseName: input.deletingPathExtension().lastPathComponent + "-trimmed", extension: "mp4", directory: directory)
        let transaction = try PrivateOutputTransaction(outputURL: output)
        let temporary = transaction.temporaryOutputURL

        let range = try parseVideoTrimRange(start: String(startSeconds), end: String(endSeconds))
        let formatWhitelist = try ffmpegFormatWhitelist(for: inputSnapshot.fileURL)
        var ffmpegArguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file",
            "-format_whitelist", formatWhitelist,
            "-ss", String(range.startSeconds), "-i", inputSnapshot.fileURL.path,
            "-t", String(range.durationSeconds),
            "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
        ]
        if stripLocationMetadata {
            ffmpegArguments += MediaMetadataPolicy.ffmpegLocationRemovalArguments
        }
        ffmpegArguments += [
            "-c:v", "libx264", "-preset", "medium", "-crf", "22",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-f", "mp4",
            "-fs", String(NativeMediaLimits.maximumOutputBytes),
            temporary.path,
        ]
        let result = try ProcessRunner.run(executable: ffmpeg, arguments: ffmpegArguments, cancellation: cancellation, timeout: 30 * 60,
           outputFileLimit: ProcessOutputFileLimit(url: temporary, maximumBytes: NativeMediaLimits.maximumOutputBytes),
           sandboxReadableDirectories: [inputSnapshot.fileURL.deletingLastPathComponent()],
           sandboxWritableDirectories: [temporary.deletingLastPathComponent()],
           restrictedSandbox: true)
        guard result.status == 0 else {
            throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "FFmpeg could not trim this video."
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try NativeMediaLimits.validate(temporary)
        try OutputValidator.validate(temporary, format: MorphFormat("mp4", "MP4", .video), engine: .ffmpeg, cancellation: cancellation)
        let outputDuration = try mediaDuration(temporary, ffprobe: ffprobe, cancellation: cancellation)
        guard abs(outputDuration - range.durationSeconds) <= max(0.25, range.durationSeconds * 0.05) else {
            throw MorphError.invalidOutput("FFmpeg produced a clip with an unexpected duration.")
        }
        if cancellation?.isCancelled == true { throw MorphError.cancelled }
        return try transaction.publishUnique(cancellation: cancellation)
    }

    @discardableResult
    public static func compressVideo(
        _ input: URL,
        options: VideoCompressionOptions = VideoCompressionOptions(),
        outputDirectory: URL? = nil,
        cancellation: CancellationToken? = nil,
        stripLocationMetadata: Bool = true
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw MorphError.invalidInput("The selected video is no longer available.")
        }
        guard let ffmpeg = ExecutableLocator.resolve(["ffmpeg"]),
              let ffprobe = ExecutableLocator.resolve(["ffprobe"]) else {
            throw MorphError.missingEngine(.ffmpeg)
        }
        try EngineSecurityPolicy.validateExecutable(ffmpeg, for: .ffmpeg, cancellation: cancellation)
        try EngineSecurityPolicy.validateExecutable(ffprobe, for: .ffmpeg, cancellation: cancellation)

        let inputSnapshot = try PrivateInputSnapshot(
            input: input,
            fileExtension: input.pathExtension.lowercased(),
            cancellation: cancellation ?? CancellationToken()
        )

        let sourceDuration = try mediaDuration(inputSnapshot.fileURL, ffprobe: ffprobe, cancellation: cancellation)
        let sourceDimensions = try mediaDimensions(inputSnapshot.fileURL, ffprobe: ffprobe, cancellation: cancellation)
        let directory = outputDirectory ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = uniqueURL(baseName: input.deletingPathExtension().lastPathComponent + "-compressed", extension: "mp4", directory: directory)
        let transaction = try PrivateOutputTransaction(outputURL: output)
        let temporary = transaction.temporaryOutputURL

        let formatWhitelist = try ffmpegFormatWhitelist(for: inputSnapshot.fileURL)
        var ffmpegArguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file",
            "-format_whitelist", formatWhitelist,
            "-i", inputSnapshot.fileURL.path,
            "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-map_chapters", "0",
        ]
        if stripLocationMetadata {
            ffmpegArguments += MediaMetadataPolicy.ffmpegLocationRemovalArguments
        }
        ffmpegArguments += [
            "-vf", options.resolutionLimit.ffmpegFilter(
                sourceWidth: sourceDimensions.width,
                sourceHeight: sourceDimensions.height
            ),
            "-c:v", "libx264", "-preset", "medium", "-crf", String(options.quality.ffmpegCRF),
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", options.quality.audioBitrate,
            "-fs", String(NativeMediaLimits.maximumOutputBytes),
            "-movflags", "+faststart", "-f", "mp4", temporary.path,
        ]
        let result = try ProcessRunner.run(executable: ffmpeg, arguments: ffmpegArguments, cancellation: cancellation, timeout: 30 * 60,
           outputFileLimit: ProcessOutputFileLimit(url: temporary, maximumBytes: NativeMediaLimits.maximumOutputBytes),
           sandboxReadableDirectories: [inputSnapshot.fileURL.deletingLastPathComponent()],
           sandboxWritableDirectories: [temporary.deletingLastPathComponent()],
           restrictedSandbox: true)
        guard result.status == 0 else {
            throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "FFmpeg could not compress this video."
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try NativeMediaLimits.validate(temporary)
        try OutputValidator.validate(temporary, format: MorphFormat("mp4", "MP4", .video), engine: .ffmpeg, cancellation: cancellation)
        let outputDuration = try mediaDuration(temporary, ffprobe: ffprobe, cancellation: cancellation)
        guard abs(outputDuration - sourceDuration) <= max(0.5, sourceDuration * 0.02) else {
            throw MorphError.invalidOutput("FFmpeg produced a compressed video with an unexpected duration.")
        }
        let outputDimensions = try mediaDimensions(temporary, ffprobe: ffprobe, cancellation: cancellation)
        let maximumDimensions = options.resolutionLimit.maximumDimensions(
            sourceWidth: sourceDimensions.width,
            sourceHeight: sourceDimensions.height
        )
        guard outputDimensions.width <= maximumDimensions.width,
              outputDimensions.height <= maximumDimensions.height,
              outputDimensions.width > 0,
              outputDimensions.height > 0 else {
            throw MorphError.invalidOutput("FFmpeg produced video dimensions outside the selected resolution limit.")
        }
        if cancellation?.isCancelled == true { throw MorphError.cancelled }
        return try transaction.publishUnique(cancellation: cancellation)
    }

    private static func validateRenamableFile(_ input: URL) throws {
        guard input.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: input.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MorphError.invalidInput("‘\(input.lastPathComponent)’ is not an available regular file.")
        }
    }

    private static func snapshotPDFInput(_ input: URL, cancellation: CancellationToken? = nil) throws -> PrivateInputSnapshot {
        guard input.pathExtension.lowercased() == "pdf" else {
            throw MorphError.invalidInput("The selected file is not a PDF.")
        }
        let snapshot = try PrivateInputSnapshot(
            input: input,
            fileExtension: "pdf",
            maximumBytes: NativePDFEngine.maximumPDFInputBytes,
            cancellation: cancellation ?? CancellationToken()
        )
        try NativePDFEngine.validateInput(snapshot.fileURL)
        return snapshot
    }

    private static func snapshotPDFMergeInputs(_ inputs: [URL]) throws -> [PrivateInputSnapshot] {
        var snapshots: [PrivateInputSnapshot] = []
        var totalBytes: UInt64 = 0
        for input in inputs {
            guard input.pathExtension.lowercased() == "pdf" else {
                throw MorphError.invalidInput("‘\(input.lastPathComponent)’ is not a PDF file.")
            }
            let sourceSize = try regularInputFileSize(input, maximumBytes: NativePDFEngine.maximumPDFInputBytes)
            let expectedTotal = try NativePDFEngine.addingMergedInputBytes(totalBytes, nextFileBytes: sourceSize)
            let remainingBudget = NativePDFEngine.maximumCombinedInputBytes - totalBytes
            let snapshot = try PrivateInputSnapshot(
                input: input,
                fileExtension: "pdf",
                maximumBytes: min(NativePDFEngine.maximumPDFInputBytes, remainingBudget),
                cancellation: CancellationToken()
            )
            let snapshotSize = try regularInputFileSize(snapshot.fileURL, maximumBytes: remainingBudget)
            guard snapshotSize == sourceSize else {
                throw MorphError.invalidInput("PDF inputs changed while Morph was preparing the merge. Select the files again and retry.")
            }
            totalBytes = expectedTotal
            try NativePDFEngine.validateInput(snapshot.fileURL)
            snapshots.append(snapshot)
        }
        return snapshots
    }

    private static func regularInputFileSize(_ input: URL, maximumBytes: UInt64) throws -> UInt64 {
        guard input.isFileURL else {
            throw MorphError.invalidInput("PDF inputs must be local regular files.")
        }
        let descriptor = input.path.withCString {
            open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw MorphError.invalidInput("The selected PDF is not a readable regular file.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0,
              UInt64(info.st_size) <= maximumBytes else {
            throw MorphError.invalidInput("PDF merge inputs must be regular files within Morph's size limits.")
        }
        return UInt64(info.st_size)
    }

    private static func collisionKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func mediaDuration(_ input: URL, ffprobe: URL, cancellation: CancellationToken?) throws -> Double {
        let formatWhitelist = try ffmpegFormatWhitelist(for: input)
        let result = try ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-protocol_whitelist", "file", "-format_whitelist", formatWhitelist,
            "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", input.path,
        ], cancellation: cancellation, sandboxReadableDirectories: [input.deletingLastPathComponent()], restrictedSandbox: true)
        guard result.status == 0,
              let duration = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
              duration.isFinite, duration > 0 else {
            throw MorphError.invalidInput("FFprobe could not read the video's duration.")
        }
        return duration
    }

    private static func mediaDimensions(_ input: URL, ffprobe: URL, cancellation: CancellationToken?) throws -> (width: Int, height: Int) {
        let formatWhitelist = try ffmpegFormatWhitelist(for: input)
        let result = try ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-protocol_whitelist", "file", "-format_whitelist", formatWhitelist,
            "-select_streams", "v:0", "-show_entries", "stream=width,height:stream_side_data=rotation",
            "-of", "json", input.path,
        ], cancellation: cancellation, sandboxReadableDirectories: [input.deletingLastPathComponent()], restrictedSandbox: true)
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = document["streams"] as? [[String: Any]],
              let stream = streams.first,
              let width = stream["width"] as? Int,
              let height = stream["height"] as? Int,
              width > 0, height > 0 else {
            throw MorphError.invalidInput("FFprobe could not read a video stream and its dimensions.")
        }
        let rotation = (stream["side_data_list"] as? [[String: Any]])?
            .compactMap { ($0["rotation"] as? NSNumber)?.doubleValue }
            .first
        if let rotation, rotation.isFinite,
           abs(Int(rotation.rounded())) % 180 == 90 {
            return (height, width)
        }
        return (width, height)
    }

    private static func ffmpegFormatWhitelist(for input: URL) throws -> String {
        guard let whitelist = FFmpegInputFormat.whitelist(for: input.pathExtension) else {
            throw MorphError.invalidInput("Morph cannot safely identify this media container.")
        }
        return whitelist
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

}
