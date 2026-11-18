import Foundation

public enum FormatCategory: String, CaseIterable, Codable, Sendable {
    case image = "Images"
    case video = "Video"
    case audio = "Audio"
    case document = "Documents"
    case spreadsheet = "Spreadsheets & data"
    case archive = "Archives"
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

    var ffmpegFilter: String {
        switch self {
        case .fullHD:
            "scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
        case .hd:
            "scale=w='min(1280,iw)':h='min(720,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
        case .original:
            "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        }
    }

    var maximumWidth: Int? {
        switch self {
        case .fullHD: 1920
        case .hd: 1280
        case .original: nil
        }
    }

    var maximumHeight: Int? {
        switch self {
        case .fullHD: 1080
        case .hd: 720
        case .original: nil
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
    case poppler
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
        case .poppler: "Poppler"
        case .ghostscript: "Ghostscript"
        case .sevenZip: "7-Zip"
        case .libreOffice: "LibreOffice"
        }
    }

    public var homebrewFormula: String? {
        switch self {
        case .ffmpeg: "ffmpeg"
        case .imageMagick: "imagemagick"
        case .libvips: "vips"
        case .pandoc: "pandoc"
        case .poppler: "poppler"
        case .ghostscript: "ghostscript"
        case .sevenZip: "sevenzip"
        case .libreOffice: "libreoffice"
        default: nil
        }
    }

    public var executableNames: [String] {
        switch self {
        case .ffmpeg: ["ffmpeg"]
        case .imageMagick: ["magick"]
        case .libvips: ["vips"]
        case .pandoc: ["pandoc"]
        case .poppler: ["pdftotext"]
        case .ghostscript: ["gs"]
        case .sevenZip: ["7zz", "7z"]
        case .libreOffice: ["soffice"]
        case .nativeImage, .nativePDF, .structuredData, .archive: []
        }
    }

    public var summary: String {
        switch self {
        case .nativeImage: "Convert formats supported by macOS ImageIO."
        case .nativePDF: "Create PDFs from images and perform PDF page operations."
        case .structuredData: "Convert JSON, YAML, TOML, CSV, TSV and XML locally."
        case .archive: "Create and unpack ZIP and TAR archives with macOS tools."
        case .ffmpeg: "Convert common audio and video formats using the installed FFmpeg build."
        case .imageMagick: "Additional image formats and image transformations."
        case .libvips: "Memory-efficient conversion and resizing for large images."
        case .pandoc: "Convert supported documents, markup and presentations."
        case .poppler: "Extract text and render PDF pages."
        case .ghostscript: "Compress PDFs locally with selectable Ghostscript presets."
        case .sevenZip: "Create and unpack 7z archives and convert them to and from ZIP."
        case .libreOffice: "Office document, spreadsheet and presentation conversions."
        }
    }
}

public struct EngineStatus: Codable, Identifiable, Sendable {
    public let id: EngineID
    public let executableURL: URL?
    public let version: String?
    public let supportedInputExtensions: Set<String>
    public let supportedOutputExtensions: Set<String>

    public var isInstalled: Bool { executableURL != nil || Self.isBuiltIn(id) }
    public var isBuiltIn: Bool { Self.isBuiltIn(id) }

    public init(
        id: EngineID,
        executableURL: URL? = nil,
        version: String? = nil,
        supportedInputExtensions: Set<String> = [],
        supportedOutputExtensions: Set<String> = []
    ) {
        self.id = id
        self.executableURL = executableURL
        self.version = version
        self.supportedInputExtensions = supportedInputExtensions
        self.supportedOutputExtensions = supportedOutputExtensions
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

    public init(inputURL: URL, outputFormat: MorphFormat, outputDirectory: URL, imageQuality: Double = 0.85) {
        self.inputURL = inputURL
        self.outputFormat = outputFormat
        self.outputDirectory = outputDirectory
        self.imageQuality = min(max(imageQuality, 0.1), 1.0)
    }
}

public struct ConversionResult: Sendable {
    public let inputURL: URL
    public let outputURL: URL
    public let engine: EngineID
    public let completedAt: Date
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
