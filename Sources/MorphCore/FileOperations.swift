import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum MorphFileOperations {
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
