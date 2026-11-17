import Foundation

public enum FormatCategory: String, CaseIterable, Codable, Sendable {
    case image = "Images"
    case video = "Video"
    case audio = "Audio"
    case document = "Documents"
    case spreadsheet = "Spreadsheets & data"
    case archive = "Archives"
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
        case .structuredData: "Convert JSON, CSV, TSV and XML locally."
        case .archive: "Create and unpack ZIP and TAR archives with macOS tools."
        case .ffmpeg: "Convert common audio and video formats using the installed FFmpeg build."
        case .imageMagick: "Additional image formats and image transformations."
        case .libvips: "Memory-efficient conversion and resizing for large images."
        case .pandoc: "Convert supported documents, markup and presentations."
        case .poppler: "Extract text and render PDF pages."
        case .ghostscript: "PDF and PostScript processing."
        case .sevenZip: "7z, XZ, BZIP2 and additional archive formats."
        case .libreOffice: "Office document, spreadsheet and presentation conversions."
        }
    }
}

public struct EngineStatus: Identifiable, Sendable {
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

public struct ConversionRoute: Hashable, Identifiable, Sendable {
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
