import CoreGraphics
import CoreText
import CryptoKit
import Darwin
import Foundation
import ImageIO
import MorphCore
import PDFKit

struct CheckFailure: LocalizedError, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}

final class MorphCheckSuite {
    let registry = EngineRegistry.discover()
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("morph-checks-\(UUID().uuidString)", isDirectory: true)
    private var passed = 0
    private var failed = 0
    private var skipped = 0

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func run() {
        test("native images and PDF") { try checkImagesAndPDF($0) }
        test("audio and video with FFmpeg") { try checkAudioVideo($0) }
        test("documents and PDF text") { try checkDocuments($0) }
        test("LibreOffice routes stay within compatible format families") { _ in try checkLibreOfficeRoutes() }
        test("PDF compression with Ghostscript") { try checkPDFCompression($0) }
        test("structured data") { try checkStructuredData($0) }
        test("archive repackaging") { try checkArchives($0) }
        test("image resize, PDF pages, and ZIP extraction") { try checkFileOperations($0) }
        test("mixed batch, collisions, and source preservation") { try checkBatchAndCollisions($0) }
        test("invalid input and partial-output cleanup") { try checkInvalidInput($0) }
        test("missing engine is reported before work starts") { try checkMissingEngine($0) }
        test("engine fallback and temporary cleanup") { try checkEngineFallback($0) }
        test("cancellation") { _ in try checkCancellation() }
        test("large image") { try checkLargeImage($0) }
        print("\nMorph checks: \(passed) passed, \(failed) failed, \(skipped) skipped")
        try? FileManager.default.removeItem(at: root)
        if failed > 0 { Darwin.exit(EXIT_FAILURE) }
    }

    private func test(_ name: String, body: (URL) throws -> Void) {
        let folder = root.appendingPathComponent(slug(name), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try body(folder)
            passed += 1
            print("PASS  \(name)")
        } catch let error as CheckSkip {
            skipped += 1
            print("SKIP  \(name): \(error.description)")
        } catch {
            failed += 1
            print("FAIL  \(name): \(error.localizedDescription)")
        }
    }

    private func checkImagesAndPDF(_ folder: URL) throws {
        let png = folder.appendingPathComponent("portrait.png")
        try makePNG(at: png, width: 48, height: 32)
        let originalHash = try sha256(png)
        let output = folder.appendingPathComponent("output", isDirectory: true)

        let jpeg = try convert(png, to: "jpg", category: .image, output: output)
        guard let jpegSource = CGImageSourceCreateWithURL(jpeg as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(jpegSource, 0, nil) as? [CFString: Any] else {
            throw CheckFailure("JPEG did not decode")
        }
        try expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 48, "JPEG width changed")
        try expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 32, "JPEG height changed")

        let tiff = try convert(jpeg, to: "tiff", category: .image, output: output)
        try expect(CGImageSourceCreateWithURL(tiff as CFURL, nil) != nil, "TIFF did not decode")
        let pdf = try convert(png, to: "pdf", category: .document, output: output)
        try expect(PDFDocument(url: pdf)?.pageCount == 1, "Image PDF should contain one page")
        try expect(try sha256(png) == originalHash, "Image source changed")

        if let route = registry.routes.first(where: { $0.engine == .imageMagick && $0.inputExtension == "png" && $0.output.fileExtension == "webp" }) {
            let isolatedRegistry = EngineRegistry(statuses: registry.statuses, routes: [route])
            let webpRequest = ConversionRequest(inputURL: png, outputFormat: route.output, outputDirectory: output)
            let webp = try ConversionService(registry: isolatedRegistry).convert(webpRequest)
            try OutputValidator.validate(webp.outputURL, format: route.output, engine: route.engine)
            try expect(try sha256(png) == originalHash, "ImageMagick changed the source image")
            print("  PASS  .png → .webp via ImageMagick")
        }

        if let route = registry.routes.first(where: { $0.engine == .imageMagick && $0.inputExtension == "png" && $0.output.fileExtension == "ico" }) {
            let isolatedRegistry = EngineRegistry(statuses: registry.statuses, routes: [route])
            let iconRequest = ConversionRequest(inputURL: png, outputFormat: route.output, outputDirectory: output)
            let icon = try ConversionService(registry: isolatedRegistry).convert(iconRequest)
            try expect(FileManager.default.fileExists(atPath: icon.outputURL.path), "ICO output is missing")
            try expect(try sha256(png) == originalHash, "ICO conversion changed the source image")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path)
                .filter { $0.hasPrefix(".morph-") || $0.contains(".partial") }
            try expect(leftovers.isEmpty, "ICO conversion left staging artifacts: \(leftovers)")
            print("  PASS  .png → .ico via ImageMagick")
        }
    }

    private func checkAudioVideo(_ folder: URL) throws {
        guard let ffmpeg = registry.status(for: .ffmpeg)?.executableURL, registry.isAvailable(.ffmpeg) else {
            throw CheckSkip("FFmpeg is not installed")
        }
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let wav = folder.appendingPathComponent("tone.wav")
        let generatedAudio = try ProcessRunner.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "pcm_s16le", wav.path,
        ])
        try expect(generatedAudio.status == 0, "Could not generate WAV fixture: \(generatedAudio.stderr)")
        let wavHash = try sha256(wav)
        let mp3 = try convert(wav, to: "mp3", category: .audio, output: output)
        let restoredWav = try convert(mp3, to: "wav", category: .audio, output: output)
        try validateWithFFprobe(mp3, ffmpeg: ffmpeg)
        try validateWithFFprobe(restoredWav, ffmpeg: ffmpeg)
        try expect(try sha256(wav) == wavHash, "WAV source changed")

        let mp4 = folder.appendingPathComponent("clip.mp4")
        let generatedVideo = try ProcessRunner.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=red:s=64x64:d=1",
            "-f", "lavfi", "-i", "sine=frequency=660:duration=1",
            "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", mp4.path,
        ])
        try expect(generatedVideo.status == 0, "Could not generate MP4 fixture: \(generatedVideo.stderr)")
        let mp4Hash = try sha256(mp4)
        let webm = try convert(mp4, to: "webm", category: .video, output: output)
        let extractedAudio = try convert(mp4, to: "mp3", category: .audio, output: output)
        try validateWithFFprobe(webm, ffmpeg: ffmpeg)
        try validateWithFFprobe(extractedAudio, ffmpeg: ffmpeg)
        try expect(try sha256(mp4) == mp4Hash, "MP4 source changed")
    }

    private func checkDocuments(_ folder: URL) throws {
        guard registry.isAvailable(.pandoc) else { throw CheckSkip("Pandoc is not installed") }
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let markdown = folder.appendingPathComponent("notes.md")
        try "# Morph sample\n\nThis document survives conversion.\n".write(to: markdown, atomically: true, encoding: .utf8)
        let markdownHash = try sha256(markdown)
        let docx = try convert(markdown, to: "docx", category: .document, output: output)
        let html = try convert(docx, to: "html", category: .document, output: output)
        try expect(try String(contentsOf: html, encoding: .utf8).contains("survives conversion"), "Converted HTML lost document text")
        try expect(try sha256(markdown) == markdownHash, "Markdown source changed")

        guard registry.isAvailable(.poppler) else { throw CheckSkip("Poppler is not installed") }
        let pdf = folder.appendingPathComponent("text-sample.pdf")
        try makeTextPDF(at: pdf, text: "Morph PDF sample text")
        let pdfHash = try sha256(pdf)
        let text = try convert(pdf, to: "txt", category: .document, output: output)
        try expect(try String(contentsOf: text, encoding: .utf8).contains("Morph PDF sample text"), "PDF text was not preserved")
        try expect(try sha256(pdf) == pdfHash, "PDF source changed")

        if registry.isAvailable(.libreOffice) {
            let csv = folder.appendingPathComponent("budget.csv")
            try "item,total\nApples,12\nOranges,8\n".write(to: csv, atomically: true, encoding: .utf8)
            let csvHash = try sha256(csv)
            let workbook = try convert(csv, to: "xlsx", category: .spreadsheet, output: output)
            let restoredCSV = try convert(workbook, to: "csv", category: .spreadsheet, output: output)
            let restoredText = try String(contentsOf: restoredCSV, encoding: .utf8)
            try expect(restoredText.contains("Apples") && restoredText.contains("Oranges"), "Spreadsheet round trip lost cell text")
            try expect(try sha256(csv) == csvHash, "CSV source changed during spreadsheet conversion")
        }
    }

    private func checkLibreOfficeRoutes() throws {
        guard registry.status(for: .libreOffice)?.isInstalled == true else {
            throw CheckSkip("LibreOffice is not installed")
        }
        let officeRoutes = registry.routes.filter { $0.engine == .libreOffice }
        func supports(_ input: String, _ output: String) -> Bool {
            officeRoutes.contains { $0.inputExtension == input && $0.output.fileExtension == output }
        }

        try expect(supports("docx", "pdf"), "LibreOffice should expose DOCX to PDF")
        try expect(supports("pptx", "pdf"), "LibreOffice should expose PPTX to PDF")
        try expect(supports("xlsx", "pdf"), "LibreOffice should expose XLSX to PDF")
        try expect(!supports("docx", "xlsx"), "LibreOffice must not advertise document-to-spreadsheet conversion")
        try expect(!supports("pptx", "xlsx"), "LibreOffice must not advertise presentation-to-spreadsheet conversion")
        try expect(!supports("xlsx", "docx"), "LibreOffice must not advertise spreadsheet-to-document conversion")
    }

    private func checkStructuredData(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let json = folder.appendingPathComponent("records.json")
        try "[{\"name\":\"Ada Lovelace\",\"note\":\"comma, and \\\"quotes\\\"\",\"active\":true}]".write(to: json, atomically: true, encoding: .utf8)
        let jsonHash = try sha256(json)
        let csv = try convert(json, to: "csv", category: .spreadsheet, output: output)
        let csvText = try String(contentsOf: csv, encoding: .utf8)
        try expect(csvText.contains("Ada Lovelace") && csvText.contains("comma, and"), "CSV lost input values")
        let restoredJSON = try convert(csv, to: "json", category: .spreadsheet, output: output)
        let records = try JSONSerialization.jsonObject(with: Data(contentsOf: restoredJSON)) as? [[String: Any]]
        try expect(records?.first?["name"] as? String == "Ada Lovelace", "CSV-to-JSON lost the name field")
        try expect(try sha256(json) == jsonHash, "JSON source changed")

        let xml = try convert(json, to: "xml", category: .spreadsheet, output: output)
        try expect(try String(contentsOf: xml, encoding: .utf8).contains("Ada Lovelace"), "XML lost input values")
        let fromXML = try convert(xml, to: "json", category: .spreadsheet, output: output)
        _ = try JSONSerialization.jsonObject(with: Data(contentsOf: fromXML))

        let csv2 = folder.appendingPathComponent("table.csv")
        try "name,value\nGrace,3\n".write(to: csv2, atomically: true, encoding: .utf8)
        let tsv = try convert(csv2, to: "tsv", category: .spreadsheet, output: output)
        let csvAgain = try convert(tsv, to: "csv", category: .spreadsheet, output: output)
        try expect(try String(contentsOf: csvAgain, encoding: .utf8).contains("Grace,3"), "TSV round trip lost the row")
    }

    private func checkPDFCompression(_ folder: URL) throws {
        guard registry.status(for: .ghostscript)?.isInstalled == true else {
            throw CheckSkip("Ghostscript is not installed")
        }
        let input = folder.appendingPathComponent("report.pdf")
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try makeTextPDF(at: input, text: "Morph PDF compression preserves this text")
        let originalHash = try sha256(input)
        let compressed = try MorphFileOperations.compressPDF(input, preset: .balanced, outputDirectory: output)
        guard let document = PDFDocument(url: compressed) else {
            throw CheckFailure("Compressed PDF could not be reopened")
        }
        try expect(document.pageCount == 1, "PDF compression changed the page count")
        try expect(document.page(at: 0)?.string?.contains("Morph PDF compression preserves this text") == true, "PDF compression lost page text")
        try OutputValidator.validate(compressed, format: MorphFormat("pdf", "PDF", .document), engine: .ghostscript)
        try expect(try sha256(input) == originalHash, "PDF compression changed the original")
        let outputNames = try FileManager.default.contentsOfDirectory(atPath: output.path)
        try expect(outputNames == [compressed.lastPathComponent], "PDF compression left a staging artifact")

        for preset in [PDFCompressionPreset.compact, .printQuality] {
            let presetOutput = folder.appendingPathComponent(preset.rawValue, isDirectory: true)
            let result = try MorphFileOperations.compressPDF(input, preset: preset, outputDirectory: presetOutput)
            try expect(PDFDocument(url: result)?.pageCount == 1, "\(preset.displayName) preset changed the PDF page count")
            try expect(PDFDocument(url: result)?.page(at: 0)?.string?.contains("Morph PDF compression preserves this text") == true, "\(preset.displayName) preset lost page text")
        }

        let cancelledOutput = folder.appendingPathComponent("cancelled", isDirectory: true)
        let cancellation = CancellationToken()
        cancellation.cancel()
        do {
            _ = try MorphFileOperations.compressPDF(input, outputDirectory: cancelledOutput, cancellation: cancellation)
            throw CheckFailure("PDF compression ignored a pre-cancelled token")
        } catch MorphError.cancelled {
            try expect(try FileManager.default.contentsOfDirectory(atPath: cancelledOutput.path).isEmpty, "Cancelled PDF compression left a staged output")
            try expect(try sha256(input) == originalHash, "Cancelled PDF compression changed the original")
        }
    }

    private func checkArchives(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let sourceFolder = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try "archive data retained".write(to: sourceFolder.appendingPathComponent("payload.txt"), atomically: true, encoding: .utf8)
        let zip = folder.appendingPathComponent("bundle.zip")
        guard let zipTool = ExecutableLocator.resolve(["zip"]) else { throw CheckSkip("ZIP command is unavailable") }
        let created = try ProcessRunner.run(executable: zipTool, arguments: ["-qr", zip.path, "."], currentDirectory: sourceFolder)
        try expect(created.status == 0, "Could not create ZIP fixture: \(created.stderr)")
        let zipHash = try sha256(zip)
        let tarGZ = try convert(zip, to: "tar.gz", category: .archive, output: output)
        let roundTripZip = try convert(tarGZ, to: "zip", category: .archive, output: output)
        guard let unzip = ExecutableLocator.resolve(["unzip"]) else { throw CheckSkip("unzip is unavailable") }
        let listing = try ProcessRunner.run(executable: unzip, arguments: ["-Z1", roundTripZip.path])
        try expect(listing.status == 0 && listing.stdout.contains("payload.txt"), "Repacked ZIP is missing its member")
        try expect(try sha256(zip) == zipHash, "Source ZIP changed")
    }

    private func checkFileOperations(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let image = folder.appendingPathComponent("resize-me.png")
        try makePNG(at: image, width: 160, height: 80)
        let imageHash = try sha256(image)
        let resized = try MorphFileOperations.resizeImage(image, scale: 0.5, outputDirectory: output)
        guard let resizedSource = CGImageSourceCreateWithURL(resized as CFURL, nil),
              let resizedProperties = CGImageSourceCopyPropertiesAtIndex(resizedSource, 0, nil) as? [CFString: Any] else {
            throw CheckFailure("Resized image did not decode")
        }
        try expect((resizedProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 80, "Resize width is wrong")
        try expect((resizedProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 40, "Resize height is wrong")
        try expect(try sha256(image) == imageHash, "Resize changed the original image")

        let firstPDF = folder.appendingPathComponent("first.pdf")
        let secondPDF = folder.appendingPathComponent("second.pdf")
        try makeTextPDF(at: firstPDF, text: "First page")
        try makeTextPDF(at: secondPDF, text: "Second page")
        let firstHash = try sha256(firstPDF)
        let secondHash = try sha256(secondPDF)
        let merged = try MorphFileOperations.mergePDFs([firstPDF, secondPDF], outputDirectory: output)
        try expect(PDFDocument(url: merged)?.pageCount == 2, "Merged PDF should contain two pages")
        let split = try MorphFileOperations.splitPDF(merged, outputDirectory: output)
        try expect(split.count == 2 && split.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 }, "Split PDF should produce two one-page documents")
        try expect(try sha256(firstPDF) == firstHash && sha256(secondPDF) == secondHash, "PDF inputs changed")

        let sourceFolder = folder.appendingPathComponent("zip-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try "extracted safely".write(to: sourceFolder.appendingPathComponent("payload.txt"), atomically: true, encoding: .utf8)
        let zip = folder.appendingPathComponent("extract-me.zip")
        guard let zipTool = ExecutableLocator.resolve(["zip"]) else { throw CheckSkip("ZIP command is unavailable") }
        let created = try ProcessRunner.run(executable: zipTool, arguments: ["-qr", zip.path, "."], currentDirectory: sourceFolder)
        try expect(created.status == 0, "Could not create extraction fixture: \(created.stderr)")
        let zipHash = try sha256(zip)
        let extracted = try MorphFileOperations.extractZIP(zip, outputDirectory: output)
        let payload = extracted.appendingPathComponent("payload.txt")
        try expect(try String(contentsOf: payload, encoding: .utf8) == "extracted safely", "ZIP extraction lost file content")
        try expect(try sha256(zip) == zipHash, "ZIP source changed")
    }

    private func checkBatchAndCollisions(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("same.png")
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let second = nested.appendingPathComponent("same.tiff")
        try makePNG(at: first, width: 40, height: 30)
        try makeTIFF(at: second, width: 24, height: 18)
        let firstHash = try sha256(first)
        let secondHash = try sha256(second)
        try Data([0x01, 0x02, 0x03]).write(to: output.appendingPathComponent("same.jpg"))

        let resultA = try convert(first, to: "jpg", category: .image, output: output)
        let resultB = try convert(second, to: "jpg", category: .image, output: output)
        try expect(resultA.lastPathComponent == "same-2.jpg", "First collision was not renamed safely")
        try expect(resultB.lastPathComponent == "same-3.jpg", "Second collision was not renamed safely")
        try expect(try sha256(first) == firstHash && sha256(second) == secondHash, "Batch conversion changed an original")
    }

    private func checkInvalidInput(_ folder: URL) throws {
        let input = folder.appendingPathComponent("bad.png")
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: input)
        let originalHash = try sha256(input)
        do {
            _ = try convert(input, to: "jpg", category: .image, output: output)
            throw CheckFailure("Invalid image unexpectedly converted")
        } catch is CheckFailure {
            throw CheckFailure("Invalid image unexpectedly converted")
        } catch {
            try expect(try sha256(input) == originalHash, "Invalid input was modified")
            let files = try FileManager.default.contentsOfDirectory(atPath: output.path)
            try expect(files.isEmpty, "Failed conversion left a partial output")
        }
    }

    private func checkMissingEngine(_ folder: URL) throws {
        let input = folder.appendingPathComponent("sample.wav")
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try Data([0x01, 0x02]).write(to: input)
        let route = ConversionRoute(inputExtension: "wav", output: MorphFormat("mp3", "MP3", .audio), engine: .ffmpeg, description: "test route")
        let registry = EngineRegistry(statuses: [.ffmpeg: EngineStatus(id: .ffmpeg)], routes: [route])
        do {
            _ = try ConversionService(registry: registry).convert(ConversionRequest(inputURL: input, outputFormat: route.output, outputDirectory: output))
            throw CheckFailure("Missing engine was not reported")
        } catch MorphError.missingEngine(.ffmpeg) {
            try expect(!FileManager.default.fileExists(atPath: output.path), "Missing engine created an output folder")
        }
    }

    private func checkEngineFallback(_ folder: URL) throws {
        let input = folder.appendingPathComponent("fallback.png")
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try makePNG(at: input, width: 32, height: 24)
        let imageMagickRoute = ConversionRoute(inputExtension: "png", output: MorphFormat("jpg", "JPEG", .image), engine: .imageMagick, description: "preferred route fails")
        let nativeRoute = ConversionRoute(inputExtension: "png", output: imageMagickRoute.output, engine: .nativeImage, description: "fallback route")
        let statuses: [EngineID: EngineStatus] = [
            .nativeImage: EngineStatus(id: .nativeImage),
            .imageMagick: EngineStatus(id: .imageMagick, executableURL: URL(fileURLWithPath: "/bin/false")),
        ]
        let registry = EngineRegistry(statuses: statuses, routes: [imageMagickRoute, nativeRoute])
        let service = ConversionService(registry: registry, engines: [AlwaysFailingEngine(id: .imageMagick)])
        let result = try service.convert(ConversionRequest(inputURL: input, outputFormat: nativeRoute.output, outputDirectory: output))
        try expect(result.engine == .nativeImage, "Conversion did not use its fallback engine")
        try expect(CGImageSourceCreateWithURL(result.outputURL as CFURL, nil) != nil, "Fallback output did not decode")
        let files = try FileManager.default.contentsOfDirectory(atPath: output.path)
        try expect(files.count == 1 && files[0] == "fallback.jpg", "Failed engine left a temporary output")
    }

    private func checkCancellation() throws {
        let token = CancellationToken()
        let completion = DispatchSemaphore(value: 0)
        let outcome = LockedOutcome()
        DispatchQueue.global().async {
            do {
                _ = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], cancellation: token)
                outcome.set("unexpected success")
            } catch {
                outcome.set(error.localizedDescription)
            }
            completion.signal()
        }
        Thread.sleep(forTimeInterval: 0.2)
        token.cancel()
        try expect(completion.wait(timeout: .now() + 3) == .success, "Cancelled process did not stop promptly")
        try expect(outcome.value == MorphError.cancelled.localizedDescription, "Cancellation did not report a cancelled operation")
    }

    private func checkLargeImage(_ folder: URL) throws {
        let input = folder.appendingPathComponent("large.png")
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try makePNG(at: input, width: 2048, height: 2048, noisy: true)
        let inputSize = try FileManager.default.attributesOfItem(atPath: input.path)[.size] as? NSNumber
        try expect((inputSize?.intValue ?? 0) >= 12_000_000, "Large fixture is unexpectedly small")
        let hash = try sha256(input)
        _ = try convert(input, to: "jpg", category: .image, output: output)
        try expect(try sha256(input) == hash, "Large image source changed")
    }

    private func convert(_ input: URL, to outputExtension: String, category: FormatCategory, output: URL) throws -> URL {
        let known = Set(registry.routes.map(\.inputExtension))
        guard let inputExtension = input.morphExtension(knownExtensions: known) else { throw CheckFailure("No route recognizes \(input.lastPathComponent)") }
        guard let route = registry.routes(from: inputExtension, to: outputExtension).first else {
            throw CheckFailure("Missing conversion route: .\(inputExtension) → .\(outputExtension)")
        }
        try expect(route.output.category == category, "Unexpected output category for .\(inputExtension) → .\(outputExtension)")
        let before = try sha256(input)
        let request = ConversionRequest(inputURL: input, outputFormat: route.output, outputDirectory: output, imageQuality: 0.9)
        let result = try ConversionService(registry: registry).convert(request)
        let size = try FileManager.default.attributesOfItem(atPath: result.outputURL.path)[.size] as? NSNumber
        try expect(FileManager.default.fileExists(atPath: result.outputURL.path) && (size?.intValue ?? 0) > 0, "Output is missing or empty")
        try OutputValidator.validate(result.outputURL, format: route.output, engine: route.engine)
        try expect(try sha256(input) == before, "Input changed during conversion")
        print("  PASS  .\(inputExtension) → .\(outputExtension) via \(route.engine.displayName)")
        return result.outputURL
    }

    private func makePNG(at url: URL, width: Int, height: Int, noisy: Bool = false) throws {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt32 = 0x12345678
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if noisy {
                state = state &* 1_664_525 &+ 1_013_904_223
                pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
                state = state &* 1_664_525 &+ 1_013_904_223
                pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 24)
                state = state &* 1_664_525 &+ 1_013_904_223
                pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 24)
                pixels[index + 3] = 255
            } else {
                pixels[index] = 220; pixels[index + 1] = 60; pixels[index + 2] = 40; pixels[index + 3] = 255
            }
        }
        let provider = try unwrap(CGDataProvider(data: Data(pixels) as CFData), "Could not create image data provider")
        let image = try makeImage(provider: provider, width: width, height: height)
        try writeImage(image, to: url, type: "public.png")
    }

    private func makeTIFF(at url: URL, width: Int, height: Int) throws {
        var pixels = [UInt8](repeating: 127, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        let provider = try unwrap(CGDataProvider(data: Data(pixels) as CFData), "Could not create TIFF data provider")
        let image = try makeImage(provider: provider, width: width, height: height)
        try writeImage(image, to: url, type: "public.tiff")
    }

    private func makeImage(provider: CGDataProvider, width: Int, height: Int) throws -> CGImage {
        try unwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ), "Could not create test image")
    }

    private func writeImage(_ image: CGImage, to url: URL, type: String) throws {
        let destination = try unwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil), "Could not create image destination")
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "Could not write image fixture")
    }

    private func makeTextPDF(at url: URL, text: String) throws {
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try unwrap(CGDataConsumer(url: url as CFURL), "Could not create PDF data consumer")
        let context = try unwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil), "Could not create PDF context")
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 50, y: 700)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
    }

    private func validateWithFFprobe(_ url: URL, ffmpeg: URL) throws {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let result = try ProcessRunner.run(executable: ffprobe, arguments: ["-v", "error", "-show_entries", "format=format_name", "-of", "default=noprint_wrappers=1:nokey=1", url.path])
        try expect(result.status == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "FFprobe could not validate \(url.lastPathComponent): \(result.stderr)")
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message) }
    }

    private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CheckFailure(message) }
        return value
    }

    private func slug(_ name: String) -> String { name.lowercased().replacingOccurrences(of: " ", with: "-") }
}

struct CheckSkip: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class LockedOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ value: String) { lock.lock(); storage = value; lock.unlock() }
}

private struct AlwaysFailingEngine: ConversionEngine {
    let id: EngineID
    func convert(context: ConversionContext) throws {
        throw MorphError.processFailed("Intentional fallback test failure")
    }
}

do {
    let suite = try MorphCheckSuite()
    suite.run()
} catch {
    FileHandle.standardError.write(Data("Could not start Morph checks: \(error.localizedDescription)\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}
