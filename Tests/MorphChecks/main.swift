import CoreGraphics
import CoreText
import CryptoKit
import Darwin
import Foundation
import ImageIO
@testable import MorphCore
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
        test("route-aware conversion presets") { _ in try checkConversionPresets() }
        test("Finder conversion targets match the entire selection") { _ in try checkQuickConversionCatalog() }
        test("audio and video with FFmpeg") { try checkAudioVideo($0) }
        test("video trimming") { try checkVideoTrimming($0) }
        test("video compression") { try checkVideoCompression($0) }
        test("documents and PDF text") { try checkDocuments($0) }
        test("LibreOffice routes stay within compatible format families") { _ in try checkLibreOfficeRoutes() }
        test("PDF compression with Ghostscript") { try checkPDFCompression($0) }
        test("structured data") { try checkStructuredData($0) }
        test("YAML and TOML transformations") { try checkYAMLAndTOML($0) }
        test("archive repackaging") { try checkArchives($0) }
        test("7-Zip archive conversion") { try checkSevenZip($0) }
        test("7-Zip listing path and link rejection") { _ in try checkSevenZipListingSafety() }
        test("archive traversal and symlink rejection") { try checkArchiveTraversal($0) }
        test("image resize, PDF pages, and ZIP extraction") { try checkFileOperations($0) }
        test("PDF page-range extraction") { try checkPDFPageRangeExtraction($0) }
        test("image and PDF metadata inspection") { try checkMetadataInspection($0) }
        test("mixed batch, collisions, and source preservation") { try checkBatchAndCollisions($0) }
        test("batch rename copies preserve sources and avoid collisions") { try checkBatchRename($0) }
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

    private func checkConversionPresets() throws {
        try expect(ConversionPreset.imagesToJPEG.isAvailable(inputExtensions: ["PNG"], outputExtensions: ["jpg"]), "JPEG preset should accept a supported image and available output")
        try expect(ConversionPreset.imagesToWebP80.isAvailable(inputExtensions: ["png"], outputExtensions: ["webp"]), "WebP preset should be available when its route exists")
        try expect(ConversionPreset.imagesToWebP80.imageQualityOverride == 0.8, "WebP preset should use 80 percent quality")
        try expect(!ConversionPreset.imagesToWebP80.isAvailable(inputExtensions: ["png"], outputExtensions: ["jpg"]), "WebP preset should be hidden when WebP output is unavailable")
        try expect(!ConversionPreset.imagesToJPEG.isAvailable(inputExtensions: ["png", "docx"], outputExtensions: ["jpg"]), "Image preset should not accept a mixed non-image selection")
        try expect(ConversionPreset.videoToMP4H264.isAvailable(inputExtensions: ["mov"], outputExtensions: ["mp4"]), "H.264 preset should accept a supported video route")
        try expect(ConversionPreset.extractAudioToMP3.isAvailable(inputExtensions: ["mov", "wav"], outputExtensions: ["mp3"]), "Audio extraction preset should accept mixed audio and video inputs")
        try expect(!ConversionPreset.extractAudioToMP3.isAvailable(inputExtensions: ["docx"], outputExtensions: ["mp3"]), "Audio extraction preset should reject documents")
        try expect(!ConversionPreset.extractAudioToMP3.isAvailable(inputExtensions: ["gif"], outputExtensions: ["mp3"]), "Audio extraction preset should reject GIFs, which cannot contain audio")
        try expect(ConversionPreset.documentsToPDF.isAvailable(inputExtensions: ["docx"], outputExtensions: ["pdf"]), "Document preset should accept an available PDF route")
    }

    private func checkQuickConversionCatalog() throws {
        let discoveredTargets = QuickConversionCatalog.availableOutputs(
            for: [URL(fileURLWithPath: "/tmp/source.png")],
            registry: registry
        )
        try expect(discoveredTargets.contains { $0.fileExtension == "jpg" }, "The installed capability registry should offer PNG → JPEG")

        let imageMagick = EngineStatus(id: .imageMagick, executableURL: URL(fileURLWithPath: "/usr/bin/magick"))
        let libreOffice = EngineStatus(id: .libreOffice, executableURL: URL(fileURLWithPath: "/usr/bin/soffice"))
        let builtInStatuses: [EngineID: EngineStatus] = [
            .nativeImage: EngineStatus(id: .nativeImage),
            .nativePDF: EngineStatus(id: .nativePDF),
        ]
        let routes = [
            ConversionRoute(inputExtension: "png", output: MorphFormat("jpg", "JPEG", .image), engine: .nativeImage, description: "Built-in image conversion"),
            ConversionRoute(inputExtension: "png", output: MorphFormat("webp", "WebP", .image), engine: .imageMagick, description: "Optional image conversion"),
            ConversionRoute(inputExtension: "png", output: MorphFormat("pdf", "PDF", .document), engine: .nativePDF, description: "Built-in PDF export"),
            ConversionRoute(inputExtension: "tiff", output: MorphFormat("jpg", "JPEG", .image), engine: .nativeImage, description: "Built-in image conversion"),
            ConversionRoute(inputExtension: "docx", output: MorphFormat("pdf", "PDF", .document), engine: .libreOffice, description: "Optional document conversion"),
        ]
        var allStatuses = builtInStatuses
        allStatuses[.imageMagick] = imageMagick
        allStatuses[.libreOffice] = libreOffice
        let registry = EngineRegistry(statuses: allStatuses, routes: routes)
        let png = URL(fileURLWithPath: "/tmp/source.png")
        let tiff = URL(fileURLWithPath: "/tmp/source.tiff")
        let docx = URL(fileURLWithPath: "/tmp/source.docx")

        let pngTargets = QuickConversionCatalog.availableOutputs(for: [png], registry: registry)
        try expect(pngTargets.map(\.fileExtension) == ["jpg", "webp", "pdf"], "A PNG selection should show only its available image/PDF targets; got \(pngTargets.map(\.fileExtension))")
        try expect(!pngTargets.contains { $0.fileExtension == "mp3" }, "A PNG selection must not show unrelated audio outputs")

        let imageTargets = QuickConversionCatalog.availableOutputs(for: [png, tiff], registry: registry)
        try expect(imageTargets.map(\.fileExtension) == ["jpg"], "Finder should show only targets supported by every selected image; got \(imageTargets.map(\.fileExtension))")

        let mixedTargets = QuickConversionCatalog.availableOutputs(for: [png, docx], registry: registry)
        try expect(mixedTargets.map(\.fileExtension) == ["pdf"], "Finder should retain a shared target supported across mixed inputs")

        let noOptionalEngineRegistry = EngineRegistry(statuses: builtInStatuses, routes: routes)
        let installedOnlyTargets = QuickConversionCatalog.availableOutputs(for: [png], registry: noOptionalEngineRegistry)
        try expect(installedOnlyTargets.map(\.fileExtension) == ["jpg", "pdf"], "Finder must hide routes whose optional conversion engine is unavailable; got \(installedOnlyTargets.map(\.fileExtension))")
        try expect(QuickConversionCatalog.availableOutputs(for: [], registry: registry).isEmpty, "Finder should not offer formats for an empty selection")
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

    private func checkVideoTrimming(_ folder: URL) throws {
        guard let ffmpeg = registry.status(for: .ffmpeg)?.executableURL, registry.isAvailable(.ffmpeg),
              let ffprobe = ExecutableLocator.resolve(["ffprobe"]) else {
            throw CheckSkip("FFmpeg/FFprobe is not installed")
        }
        let input = folder.appendingPathComponent("trim-source.mp4")
        let generated = try ProcessRunner.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=96x64:rate=24:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", input.path,
        ])
        try expect(generated.status == 0, "Could not generate trim fixture: \(generated.stderr)")
        let sourceHash = try sha256(input)
        let range = try MorphFileOperations.parseVideoTrimRange(start: " 0.25 ", end: " 0.9 ")
        try expect(abs(range.startSeconds - 0.25) < 0.0001 && abs(range.durationSeconds - 0.65) < 0.0001, "Video trim range parsing changed the requested interval")
        for invalid in [("-1", "1"), ("1", "1"), ("2", "1"), ("nan", "2")] {
            do {
                _ = try MorphFileOperations.parseVideoTrimRange(start: invalid.0, end: invalid.1)
                throw CheckFailure("Invalid video trim interval \(invalid) was accepted")
            } catch let failure as CheckFailure {
                throw failure
            } catch {
                // Invalid intervals must be rejected before any conversion starts.
            }
        }

        let outputDirectory = folder.appendingPathComponent("output", isDirectory: true)
        let trimmed = try MorphFileOperations.trimVideo(input, startSeconds: 0.25, endSeconds: 0.9, outputDirectory: outputDirectory)
        try OutputValidator.validate(trimmed, format: MorphFormat("mp4", "MP4", .video), engine: .ffmpeg)
        let durationResult = try ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", trimmed.path,
        ])
        guard durationResult.status == 0,
              let duration = Double(durationResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CheckFailure("FFprobe could not read the trimmed clip duration: \(durationResult.stderr)")
        }
        try expect(abs(duration - 0.65) <= 0.25, "Trimmed video has an unexpected duration: \(duration)")
        try expect(try Data(contentsOf: trimmed).count > 0, "Trimmed MP4 is empty")
        let beforeOutOfBounds = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        do {
            _ = try MorphFileOperations.trimVideo(input, startSeconds: 1.5, endSeconds: 2.5, outputDirectory: outputDirectory)
            throw CheckFailure("A trim ending beyond the source duration was accepted")
        } catch let failure as CheckFailure {
            throw failure
        } catch {
            // End times beyond the probed source duration must be rejected before encoding.
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path) == beforeOutOfBounds, "An out-of-bounds trim left a partial output")
        let secondTrim = try MorphFileOperations.trimVideo(input, startSeconds: 0.25, endSeconds: 0.9, outputDirectory: outputDirectory)
        try expect(secondTrim.lastPathComponent == "trim-source-trimmed-2.mp4", "Repeated video trim did not choose a collision-safe output name")
        try expect(try sha256(input) == sourceHash, "Video trimming changed the original source")
    }

    private func checkVideoCompression(_ folder: URL) throws {
        guard let ffmpeg = registry.status(for: .ffmpeg)?.executableURL, registry.isAvailable(.ffmpeg),
              let ffprobe = ExecutableLocator.resolve(["ffprobe"]) else {
            throw CheckSkip("FFmpeg/FFprobe is not installed")
        }
        let input = folder.appendingPathComponent("compression-source.mp4")
        let generated = try ProcessRunner.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-shortest", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "5", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "320k", input.path,
        ])
        try expect(generated.status == 0, "Could not generate compression fixture: \(generated.stderr)")
        let sourceHash = try sha256(input)
        let sourceSize = try Data(contentsOf: input).count
        let outputDirectory = folder.appendingPathComponent("output", isDirectory: true)
        let compressed = try MorphFileOperations.compressVideo(
            input,
            options: VideoCompressionOptions(quality: .balanced, resolutionLimit: .hd),
            outputDirectory: outputDirectory
        )
        try OutputValidator.validate(compressed, format: MorphFormat("mp4", "MP4", .video), engine: .ffmpeg)

        let probe = try ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-show_entries", "stream=codec_type,codec_name,width,height",
            "-of", "json", compressed.path,
        ])
        guard probe.status == 0,
              let json = try JSONSerialization.jsonObject(with: Data(probe.stdout.utf8)) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let stream = streams.first(where: { $0["codec_type"] as? String == "video" }),
              let codec = stream["codec_name"] as? String,
              let width = stream["width"] as? Int, let height = stream["height"] as? Int else {
            throw CheckFailure("FFprobe could not validate compressed video properties: \(probe.stderr)")
        }
        let audioCodec = streams.first(where: { $0["codec_type"] as? String == "audio" })?["codec_name"] as? String
        try expect(codec == "h264", "Video compression did not encode H.264")
        try expect(audioCodec == "aac", "Video compression did not encode the audio stream as AAC")
        try expect(width <= 1280 && height <= 720 && width > 0 && height > 0, "Compressed video exceeded the selected 720p limit")
        try expect(try Data(contentsOf: compressed).count < sourceSize, "The high-bitrate fixture was not reduced in size")
        let sourceDuration = try probeDuration(input, ffprobe: ffprobe)
        let outputDuration = try probeDuration(compressed, ffprobe: ffprobe)
        try expect(abs(sourceDuration - outputDuration) <= 0.25, "Video compression changed the source duration")
        try expect(try sha256(input) == sourceHash, "Video compression changed the original source")

        let second = try MorphFileOperations.compressVideo(
            input,
            options: VideoCompressionOptions(quality: .higherQuality, resolutionLimit: .original),
            outputDirectory: outputDirectory
        )
        try expect(second.lastPathComponent == "compression-source-compressed-2.mp4", "Repeated video compression did not choose a collision-safe output name")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        try expect(!remaining.contains(where: { $0.hasSuffix(".partial") }), "Video compression left a partial output")

        let invalid = folder.appendingPathComponent("invalid.mp4")
        try "not a video".write(to: invalid, atomically: true, encoding: .utf8)
        let beforeInvalid = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        do {
            _ = try MorphFileOperations.compressVideo(invalid, outputDirectory: outputDirectory)
            throw CheckFailure("Invalid video input was accepted for compression")
        } catch let failure as CheckFailure {
            throw failure
        } catch {
            // Invalid media must fail before a final output is committed.
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path) == beforeInvalid, "Invalid video compression left an output behind")
        try expect(try sha256(input) == sourceHash, "A failed video compression changed the original source")
    }

    private func probeDuration(_ video: URL, ffprobe: URL) throws -> Double {
        let result = try ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", video.path,
        ])
        guard result.status == 0,
              let duration = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CheckFailure("FFprobe could not read video duration: \(result.stderr)")
        }
        return duration
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

    private func checkYAMLAndTOML(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let json = folder.appendingPathComponent("config.json")
        let jsonText = """
        {"name":"Ada Lovelace","active":true,"count":42,"note":"on","labels":["Math","Computing"],"settings":{"enabled":false}}
        """
        try jsonText.write(to: json, atomically: true, encoding: .utf8)
        let jsonHash = try sha256(json)

        let yaml = try convert(json, to: "yaml", category: .spreadsheet, output: output)
        let yamlText = try String(contentsOf: yaml, encoding: .utf8)
        try expect(!yamlText.isEmpty, "JSON-to-YAML produced empty output")
        let restoredJSON = try convert(yaml, to: "json", category: .spreadsheet, output: output)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: restoredJSON)) as? [String: Any]
        try expect(restored?["name"] as? String == "Ada Lovelace", "YAML-to-JSON lost the name")
        try expect(restored?["active"] as? Bool == true, "YAML-to-JSON changed a boolean")
        try expect(restored?["note"] as? String == "on", "YAML 1.2 parsing changed the string 'on' into a boolean")

        let toml = try convert(json, to: "toml", category: .spreadsheet, output: output)
        let tomlText = try String(contentsOf: toml, encoding: .utf8)
        try expect(tomlText.contains("Ada Lovelace") && tomlText.contains("active"), "JSON-to-TOML lost expected values")
        let restoredFromTOML = try convert(toml, to: "json", category: .spreadsheet, output: output)
        let tomlJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: restoredFromTOML)) as? [String: Any]
        try expect(tomlJSON?["name"] as? String == "Ada Lovelace", "TOML-to-JSON lost the name")
        try expect(tomlJSON?["active"] as? Bool == true, "TOML-to-JSON changed a boolean")
        try expect(tomlJSON?["note"] as? String == "on", "TOML-to-JSON changed a string")

        let fixtureYAML = folder.appendingPathComponent("yaml-core.yaml")
        try "active: true\nlegacyWord: on\nbareDate: 2024-01-02\ncount: 42\n".write(to: fixtureYAML, atomically: true, encoding: .utf8)
        let yamlHash = try sha256(fixtureYAML)
        let yamlJSONURL = try convert(fixtureYAML, to: "json", category: .spreadsheet, output: output)
        let yamlJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: yamlJSONURL)) as? [String: Any]
        try expect(yamlJSON?["active"] as? Bool == true, "YAML boolean was not parsed")
        try expect(yamlJSON?["legacyWord"] as? String == "on", "YAML 1.2 string semantics changed 'on'")
        try expect(yamlJSON?["bareDate"] as? String == "2024-01-02", "A bare YAML date should remain a string")
        try expect(yamlJSON?["count"] as? Int == 42, "YAML integer was not parsed")

        let yamlToml = try convert(fixtureYAML, to: "toml", category: .spreadsheet, output: output)
        let tomlYAML = try convert(yamlToml, to: "yml", category: .spreadsheet, output: output)
        let yamlRoundTripJSON = try convert(tomlYAML, to: "json", category: .spreadsheet, output: output)
        let roundTrip = try JSONSerialization.jsonObject(with: Data(contentsOf: yamlRoundTripJSON)) as? [String: Any]
        try expect(roundTrip?["legacyWord"] as? String == "on", "YAML → TOML → YAML changed the string 'on'")
        try expect(try sha256(json) == jsonHash, "Structured-data conversions changed the JSON source")
        try expect(try sha256(fixtureYAML) == yamlHash, "Structured-data conversions changed the YAML source")

        let multipleDocuments = folder.appendingPathComponent("multi.yaml")
        try "first: 1\n---\nsecond: 2\n".write(to: multipleDocuments, atomically: true, encoding: .utf8)
        let rejectedOutput = folder.appendingPathComponent("rejected.json")
        do {
            try StructuredDataEngine.convert(input: multipleDocuments, output: rejectedOutput)
            throw CheckFailure("Multi-document YAML should be rejected")
        } catch MorphError.invalidInput {
            try expect(!FileManager.default.fileExists(atPath: rejectedOutput.path), "Rejected YAML left a partial output")
        }
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

    private func checkSevenZip(_ folder: URL) throws {
        guard let sevenZipTool = ExecutableLocator.resolve(["7zz", "7z"]) else {
            throw CheckSkip("7-Zip is not installed")
        }
        guard let zipTool = ExecutableLocator.resolve(["zip"]),
              let unzip = ExecutableLocator.resolve(["unzip"]) else {
            throw CheckSkip("ZIP tools are unavailable")
        }

        let sourceFolder = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try "7-Zip keeps this archive payload intact".write(
            to: sourceFolder.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )
        let sourceZip = folder.appendingPathComponent("bundle.zip")
        let created = try ProcessRunner.run(executable: zipTool, arguments: ["-qr", sourceZip.path, "."], currentDirectory: sourceFolder)
        try expect(created.status == 0, "Could not create ZIP fixture: \(created.stderr)")
        let sourceHash = try sha256(sourceZip)
        let output = folder.appendingPathComponent("output", isDirectory: true)

        let sevenZip = try convert(sourceZip, to: "7z", category: .archive, output: output)
        let checked = try ProcessRunner.run(executable: sevenZipTool, arguments: ["t", sevenZip.path])
        try expect(checked.status == 0, "Generated 7z failed integrity validation: \(checked.stderr)")
        let roundTripZip = try convert(sevenZip, to: "zip", category: .archive, output: output)
        let payload = try ProcessRunner.run(executable: unzip, arguments: ["-p", roundTripZip.path])
        try expect(payload.status == 0 && payload.stdout.contains("7-Zip keeps this archive payload intact"), "7-Zip round trip lost the archive payload")
        try expect(try sha256(sourceZip) == sourceHash, "ZIP source changed during 7-Zip conversion")
    }

    private func checkSevenZipListingSafety() throws {
        let safeListing = """
        Listing archive: sample.7z

        ----------
        Path = folder
        Size = 0
        Attributes = D

        ----------
        Path = folder/payload.txt
        Size = 4
        Attributes = A
        """
        try SevenZipArchiveEngine.validateListingText(safeListing)

        let unsafeListings = [
            """
            ----------
            Path = ../outside.txt
            Size = 4
            Attributes = A
            """,
            """
            ----------
            Path = C:\\outside.txt
            Size = 4
            Attributes = A
            """,
            """
            ----------
            Path = link
            Size = 0
            Attributes = A
            Symbolic Link = ../../outside.txt
            """,
            """
            ----------
            Path = safe.txt
            ../outside.txt
            Size = 4
            Attributes = A
            """,
        ]
        for listing in unsafeListings {
            do {
                try SevenZipArchiveEngine.validateListingText(listing)
                throw CheckFailure("7-Zip listing parser accepted an unsafe member")
            } catch let error as MorphError {
                guard case .invalidInput = error else { throw error }
            }
        }
    }

    private func checkArchiveTraversal(_ folder: URL) throws {
        guard let zipTool = ExecutableLocator.resolve(["zip"]),
              let unzip = ExecutableLocator.resolve(["unzip"]) else {
            throw CheckSkip("ZIP tools are unavailable")
        }
        let archiveSource = folder.appendingPathComponent("archive-source", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveSource, withIntermediateDirectories: true)
        let outside = folder.appendingPathComponent("outside.txt")
        try "outside file remains untouched".write(to: outside, atomically: true, encoding: .utf8)
        let outsideHash = try sha256(outside)

        let traversalArchive = folder.appendingPathComponent("path-traversal.zip")
        let traversalFixture = try ProcessRunner.run(
            executable: zipTool,
            arguments: ["-q", traversalArchive.path, "../outside.txt"],
            currentDirectory: archiveSource
        )
        try expect(traversalFixture.status == 0, "Could not create traversal ZIP fixture: \(traversalFixture.stderr)")
        let traversalListing = try ProcessRunner.run(executable: unzip, arguments: ["-Z1", traversalArchive.path])
        try expect(traversalListing.status == 0 && traversalListing.stdout.contains("../outside.txt"), "Traversal ZIP fixture does not contain its unsafe path")
        let traversalOutput = folder.appendingPathComponent("traversal-output", isDirectory: true)
        try expectZIPExtractionRejected(traversalArchive, outputDirectory: traversalOutput, message: "ZIP extraction accepted a parent-traversal path")
        try expect(!FileManager.default.fileExists(atPath: traversalOutput.path), "Rejected traversal archive created an output directory")
        try expect(try sha256(outside) == outsideHash, "Rejected traversal archive changed a file outside its output")

        let link = archiveSource.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linkArchive = folder.appendingPathComponent("symlink-escape.zip")
        let linkFixture = try ProcessRunner.run(
            executable: zipTool,
            arguments: ["-qy", linkArchive.path, "escape-link"],
            currentDirectory: archiveSource
        )
        try expect(linkFixture.status == 0, "Could not create symlink ZIP fixture: \(linkFixture.stderr)")
        let linkListing = try ProcessRunner.run(executable: unzip, arguments: ["-Z1", linkArchive.path])
        try expect(linkListing.status == 0 && linkListing.stdout.contains("escape-link"), "Symlink ZIP fixture is missing its link")
        let linkOutput = folder.appendingPathComponent("symlink-output", isDirectory: true)
        try expectZIPExtractionRejected(linkArchive, outputDirectory: linkOutput, message: "ZIP extraction accepted a link that escapes its output folder")
        try expect(try FileManager.default.contentsOfDirectory(atPath: linkOutput.path).isEmpty, "Rejected symlink archive left extracted content")
        try expect(try sha256(outside) == outsideHash, "Rejected symlink archive changed its target")
    }

    private func expectZIPExtractionRejected(_ archive: URL, outputDirectory: URL, message: String) throws {
        do {
            _ = try MorphFileOperations.extractZIP(archive, outputDirectory: outputDirectory)
            throw CheckFailure(message)
        } catch let failure as CheckFailure {
            throw failure
        } catch let error as MorphError {
            guard case .invalidInput = error else {
                throw CheckFailure("ZIP extraction failed for an unexpected reason: \(error.localizedDescription)")
            }
        } catch {
            throw CheckFailure("ZIP extraction failed for an unexpected reason: \(error.localizedDescription)")
        }
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

    private func checkBatchRename(_ folder: URL) throws {
        let firstFolder = folder.appendingPathComponent("first", isDirectory: true)
        let secondFolder = folder.appendingPathComponent("second", isDirectory: true)
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let first = firstFolder.appendingPathComponent("photo.png")
        let second = secondFolder.appendingPathComponent("photo.png")
        let archive = firstFolder.appendingPathComponent("bundle.tar.gz")
        try Data("first photo".utf8).write(to: first)
        try Data("second photo".utf8).write(to: second)
        try Data("archive bytes".utf8).write(to: archive)
        let sources = [first, second, archive]
        let sourceHashes = try sources.map(sha256)

        let existing = output.appendingPathComponent("Trip-001-photo.png")
        try Data("keep existing output".utf8).write(to: existing)
        let targets = try MorphFileOperations.planBatchRenamedCopies(
            inputs: sources,
            prefix: "Trip",
            outputDirectories: Array(repeating: output, count: sources.count)
        )
        try expect(targets.map { $0.outputURL.lastPathComponent } == [
            "Trip-001-2-photo.png",
            "Trip-002-photo.png",
            "Trip-003-bundle.tar.gz",
        ], "Batch rename preview did not preserve full filenames or resolve an existing collision")

        let copies = try targets.map { try MorphFileOperations.createRenamedCopy($0) }
        try expect(copies.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "A renamed copy is missing")
        try expect(try zip(copies, sources).allSatisfy { try sha256($0.0) == sha256($0.1) }, "A renamed copy did not preserve source bytes")
        try expect(try sources.map(sha256) == sourceHashes, "Batch rename changed an original")
        try expect(try String(contentsOf: existing, encoding: .utf8) == "keep existing output", "Batch rename replaced an existing destination")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path)
            .filter { $0.hasPrefix(".morph-rename-") || $0.hasSuffix(".partial") }
        try expect(leftovers.isEmpty, "Batch rename left staging files behind")

        do {
            _ = try MorphFileOperations.planBatchRenamedCopies(
                inputs: sources,
                prefix: "../escape",
                outputDirectories: Array(repeating: output, count: sources.count)
            )
            throw CheckFailure("An unsafe batch rename prefix was accepted")
        } catch is CheckFailure {
            throw CheckFailure("An unsafe batch rename prefix was accepted")
        } catch {
            try expect(try sources.map(sha256) == sourceHashes, "Invalid rename input changed a source")
        }

        let lateCollisionTarget = try MorphFileOperations.planBatchRenamedCopies(
            inputs: [first],
            prefix: "Late",
            outputDirectories: [output]
        )[0]
        try Data("arrived after preview".utf8).write(to: lateCollisionTarget.outputURL)
        do {
            _ = try MorphFileOperations.createRenamedCopy(lateCollisionTarget)
            throw CheckFailure("Batch rename replaced an output created after preview")
        } catch is CheckFailure {
            throw CheckFailure("Batch rename replaced an output created after preview")
        } catch {
            try expect(try String(contentsOf: lateCollisionTarget.outputURL, encoding: .utf8) == "arrived after preview", "A late collision was overwritten")
        }

        do {
            _ = try MorphFileOperations.createRenamedCopy(BatchRenameTarget(inputURL: first, outputURL: first))
            throw CheckFailure("Batch rename accepted the source path as its output")
        } catch is CheckFailure {
            throw CheckFailure("Batch rename accepted the source path as its output")
        } catch {
            try expect(try sha256(first) == sourceHashes[0], "Refusing an output-over-source target changed the source")
        }

        let cancelledTarget = try MorphFileOperations.planBatchRenamedCopies(
            inputs: [first],
            prefix: "Cancelled",
            outputDirectories: [output]
        )[0]
        let cancelled = CancellationToken()
        cancelled.cancel()
        do {
            _ = try MorphFileOperations.createRenamedCopy(cancelledTarget, cancellation: cancelled)
            throw CheckFailure("A cancelled batch rename created an output")
        } catch MorphError.cancelled {
            try expect(!FileManager.default.fileExists(atPath: cancelledTarget.outputURL.path), "Cancelled rename left an output")
        } catch is CheckFailure {
            throw CheckFailure("A cancelled batch rename created an output")
        } catch {
            throw CheckFailure("Cancellation returned an unexpected error: \(error.localizedDescription)")
        }

        let symbolicLink = folder.appendingPathComponent("linked-photo.png")
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: first)
        do {
            _ = try MorphFileOperations.planBatchRenamedCopies(
                inputs: [symbolicLink],
                prefix: "Trip",
                outputDirectories: [output]
            )
            throw CheckFailure("A symbolic-link input was accepted for batch rename")
        } catch is CheckFailure {
            throw CheckFailure("A symbolic-link input was accepted for batch rename")
        } catch { }

        try expect(try sources.map(sha256) == sourceHashes, "A failed or cancelled rename changed an original")
        let remainingStaging = try FileManager.default.contentsOfDirectory(atPath: output.path)
            .filter { $0.hasPrefix(".morph-rename-") || $0.hasSuffix(".partial") }
        try expect(remainingStaging.isEmpty, "A failed or cancelled rename left staging files")
    }

    private func checkMetadataInspection(_ folder: URL) throws {
        let image = folder.appendingPathComponent("metadata-image.png")
        try makePNG(at: image, width: 52, height: 34)
        let imageHash = try sha256(image)
        let imageEntries = try MorphFileOperations.inspectMetadata(image)
        let imageFields = Dictionary(uniqueKeysWithValues: imageEntries.map { ($0.label, $0.value) })
        try expect(imageFields["Name"] == image.lastPathComponent, "Image metadata omitted its filename")
        try expect(imageFields["Dimensions"] == "52 × 34 pixels", "Image metadata reported incorrect dimensions")
        try expect(imageFields["File size"] != nil, "Image metadata omitted file size")
        try expect(try sha256(image) == imageHash, "Metadata inspection changed the image")

        let pdf = folder.appendingPathComponent("metadata-document.pdf")
        try makeTextPDF(at: pdf, text: "Metadata stays local")
        guard let document = PDFDocument(url: pdf) else { throw CheckFailure("Could not reopen PDF fixture") }
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Morph metadata fixture",
            PDFDocumentAttribute.authorAttribute: "Morph Checks",
        ]
        try expect(document.write(to: pdf), "Could not write PDF metadata fixture")
        let pdfHash = try sha256(pdf)
        let pdfEntries = try MorphFileOperations.inspectMetadata(pdf)
        let pdfFields = Dictionary(uniqueKeysWithValues: pdfEntries.map { ($0.label, $0.value) })
        try expect(pdfFields["Pages"] == "1", "PDF metadata reported an incorrect page count")
        try expect(pdfFields["Title"] == "Morph metadata fixture", "PDF title metadata was not reported")
        try expect(pdfFields["Author"] == "Morph Checks", "PDF author metadata was not reported")
        try expect(try sha256(pdf) == pdfHash, "Metadata inspection changed the PDF")

        let invalidImage = folder.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalidImage)
        let invalidHash = try sha256(invalidImage)
        do {
            _ = try MorphFileOperations.inspectMetadata(invalidImage)
            throw CheckFailure("Invalid image metadata was accepted")
        } catch is CheckFailure {
            throw CheckFailure("Invalid image metadata was accepted")
        } catch {
            try expect(try sha256(invalidImage) == invalidHash, "Failed inspection changed invalid input")
        }
    }

    private func checkPDFPageRangeExtraction(_ folder: URL) throws {
        try expect(try MorphFileOperations.parsePDFPageRanges(" 1 - 2, 4 ", pageCount: 5) == [1, 2, 4], "Page-range parser did not preserve the requested order")
        for invalidSelection in ["", "0", "3", "2-1", "1, 1", "1,,2", "a"] {
            do {
                _ = try MorphFileOperations.parsePDFPageRanges(invalidSelection, pageCount: 2)
                throw CheckFailure("Invalid PDF page selection was accepted: \(invalidSelection)")
            } catch is CheckFailure {
                throw CheckFailure("Invalid PDF page selection was accepted: \(invalidSelection)")
            } catch { }
        }

        let first = folder.appendingPathComponent("first.pdf")
        let second = folder.appendingPathComponent("second.pdf")
        try makeTextPDF(at: first, text: "First selected page")
        try makeTextPDF(at: second, text: "Second selected page")
        let source = try MorphFileOperations.mergePDFs([first, second], outputDirectory: folder)
        let sourceHash = try sha256(source)
        let extracted = try MorphFileOperations.extractPDFPages(source, pageRange: "2, 1", outputDirectory: folder)
        guard let result = PDFDocument(url: extracted), result.pageCount == 2 else {
            throw CheckFailure("Extracted PDF did not contain both requested pages")
        }
        try expect(result.page(at: 0)?.string?.contains("Second selected page") == true, "Extracted page order did not match the selection")
        try expect(result.page(at: 1)?.string?.contains("First selected page") == true, "Second extracted page did not match the selection")
        try expect(try sha256(source) == sourceHash, "Page extraction changed the source PDF")
        let collision = try MorphFileOperations.extractPDFPages(source, pageRange: "1", outputDirectory: folder)
        try expect(collision != extracted && PDFDocument(url: collision)?.pageCount == 1, "Page extraction did not create a collision-safe output")
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
