import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct EngineRegistry: Sendable {
    public let statuses: [EngineID: EngineStatus]
    public let routes: [ConversionRoute]

    public init(statuses: [EngineID: EngineStatus], routes: [ConversionRoute]) {
        self.statuses = statuses
        self.routes = routes
    }

    public func status(for id: EngineID) -> EngineStatus? { statuses[id] }
    public func isAvailable(_ id: EngineID) -> Bool { statuses[id]?.isInstalled == true }

    public static func discover() -> EngineRegistry {
        let imageFormats = ImageCapabilities.discover()
        var statuses: [EngineID: EngineStatus] = [
            .nativeImage: EngineStatus(
                id: .nativeImage,
                supportedInputExtensions: imageFormats.inputs,
                supportedOutputExtensions: imageFormats.outputs
            ),
            .nativePDF: EngineStatus(id: .nativePDF),
            .structuredData: EngineStatus(
                id: .structuredData,
                supportedInputExtensions: ["json", "csv", "tsv", "xml", "yaml", "yml", "toml"],
                supportedOutputExtensions: ["json", "csv", "tsv", "xml", "yaml", "yml", "toml"]
            ),
            .archive: EngineStatus(
                id: .archive,
                supportedInputExtensions: ["zip", "tar.gz", "tgz"],
                supportedOutputExtensions: ["zip", "tar.gz"]
            ),
        ]

        for id in [EngineID.ffmpeg, .imageMagick, .libvips, .pandoc, .poppler, .ghostscript, .sevenZip, .libreOffice] {
            guard let executable = ExecutableLocator.resolve(id.executableNames) else {
                statuses[id] = EngineStatus(id: id)
                continue
            }
            let version = probeVersion(executable, engine: id)
            let capabilities = probeCapabilities(executable, engine: id)
            statuses[id] = EngineStatus(
                id: id,
                executableURL: executable,
                version: version,
                supportedInputExtensions: capabilities.inputs,
                supportedOutputExtensions: capabilities.outputs
            )
        }

        let routes = ConversionCatalog.buildRoutes(statuses: statuses)
        return EngineRegistry(statuses: statuses, routes: routes)
    }

    private static func probeVersion(_ executable: URL, engine: EngineID) -> String? {
        let arguments: [String]
        switch engine {
        case .poppler: arguments = ["-v"]
        case .sevenZip: arguments = ["--help"]
        default: arguments = ["--version"]
        }
        guard let result = try? ProcessRunner.run(executable: executable, arguments: arguments) else { return nil }
        let text = (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n").first.map(String.init)
    }

    private static func probeCapabilities(_ executable: URL, engine: EngineID) -> (inputs: Set<String>, outputs: Set<String>) {
        switch engine {
        case .ffmpeg:
            let demuxers = outputOf(executable, ["-demuxers"])
            let muxers = outputOf(executable, ["-muxers"])
            let encoders = outputOf(executable, ["-encoders"])
            return (
                MediaCapabilities.extensions(from: demuxers, output: false),
                MediaCapabilities.extensions(from: muxers, output: true, encoders: encoders)
            )
        case .imageMagick:
            let formats = outputOf(executable, ["-list", "format"])
            return ImageMagickCapabilities.extensions(from: formats)
        case .libvips:
            // libvips support is intentionally reported in the engine list only until its
            // installed foreign-load/save operations can be probed by a dedicated adapter.
            return ([], [])
        case .pandoc:
            let inputs = outputOf(executable, ["--list-input-formats"])
            let outputs = outputOf(executable, ["--list-output-formats"])
            var capabilities = PandocCapabilities.extensions(inputs: inputs, outputs: outputs)
            if ExecutableLocator.resolve(["xelatex", "pdflatex", "lualatex", "tectonic", "wkhtmltopdf", "weasyprint"]) == nil {
                capabilities.outputs.remove("pdf")
            }
            return capabilities
        case .poppler:
            return (["pdf"], ["txt"])
        case .ghostscript:
            return ([], [])
        case .sevenZip:
            return (["7z", "zip"], ["7z", "zip"])
        case .libreOffice:
            return OfficeCapabilities.probe(executable)
        case .nativeImage, .nativePDF, .structuredData, .archive:
            return ([], [])
        }
    }

    private static func outputOf(_ executable: URL, _ arguments: [String]) -> String {
        guard let result = try? ProcessRunner.run(executable: executable, arguments: arguments), result.status == 0 else { return "" }
        return result.stdout
    }
}

public enum ExecutableLocator {
    public static func resolve(_ names: [String]) -> URL? {
        let standardDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/local/bin"]
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let directories = Array(NSOrderedSet(array: pathDirectories + standardDirectories)) as? [String] ?? standardDirectories

        for name in names {
            for directory in directories {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}

private enum ImageCapabilities {
    static func discover() -> (inputs: Set<String>, outputs: Set<String>) {
        let inputIDs = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        let outputIDs = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return (extensions(for: inputIDs), extensions(for: outputIDs))
    }

    private static func extensions(for identifiers: [String]) -> Set<String> {
        let aliases: [String: [String]] = [
            "public.jpeg": ["jpg", "jpeg"],
            "public.tiff": ["tif", "tiff"],
            "public.heic": ["heic", "heif"],
            "public.png": ["png"],
            "com.compuserve.gif": ["gif"],
            "com.microsoft.bmp": ["bmp"],
            "org.webmproject.webp": ["webp"],
        ]
        var result = Set<String>()
        for identifier in identifiers {
            if let known = aliases[identifier] {
                result.formUnion(known)
                continue
            }
            if let type = UTType(identifier), type.conforms(to: .image),
               let tags = type.tags[.filenameExtension] {
                result.formUnion(tags.map { $0.lowercased() })
            }
        }
        return result
    }
}

private enum MediaCapabilities {
    static func extensions(from listing: String, output: Bool, encoders: String = "") -> Set<String> {
        var aliases = Set<String>()
        for line in listing.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2 else { continue }
            let flags = String(columns[0])
            guard flags.contains(output ? "E" : "D") else { continue }
            aliases.formUnion(columns[1].split(separator: ",").map { String($0).lowercased() })
        }

        var extensions = Set<String>()
        let containerMap: [String: [String]] = [
            "mp4": ["mp4", "m4v"], "mov": ["mov", "qt"], "matroska": ["mkv", "mk3d", "mka"],
            "webm": ["webm"], "avi": ["avi"], "gif": ["gif"], "mpeg": ["mpeg", "mpg"],
            "asf": ["asf", "wmv"], "flv": ["flv"], "mp3": ["mp3"], "wav": ["wav"],
            "flac": ["flac"], "adts": ["aac"], "ipod": ["m4a"], "ogg": ["ogg", "opus"],
            "aiff": ["aiff", "aif"], "wv": ["wv"], "3gp": ["3gp"], "3g2": ["3g2"],
        ]
        for alias in aliases { extensions.formUnion(containerMap[alias] ?? []) }

        if output {
            let encoderNames = Set(encoders.split(separator: "\n").compactMap { line -> String? in
                let columns = line.split(whereSeparator: \.isWhitespace)
                guard columns.count >= 2, columns[0].contains("A") || columns[0].contains("V") else { return nil }
                return String(columns[1])
            })
            let requirements: [String: [String]] = [
                "mp4": ["libx264", "aac"], "m4v": ["libx264", "aac"], "mov": ["libx264", "aac"],
                "mkv": ["libx264", "aac"], "webm": ["libvpx-vp9", "libopus"], "avi": ["mpeg4", "libmp3lame"],
                "gif": ["gif"], "mpeg": ["mpeg2video", "mp2"], "mpg": ["mpeg2video", "mp2"],
                "wmv": ["wmv2", "wmav2"], "flv": ["flv", "aac"], "mp3": ["libmp3lame"],
                "wav": ["pcm_s16le"], "flac": ["flac"], "aac": ["aac"], "m4a": ["aac"],
                "ogg": ["libvorbis"], "opus": ["libopus"], "aiff": ["pcm_s16be"], "aif": ["pcm_s16be"],
            ]
            for ext in extensions {
                guard let required = requirements[ext] else { continue }
                if !required.allSatisfy({ encoderNames.contains($0) }) { extensions.remove(ext) }
            }
        }
        return extensions
    }
}

private enum ImageMagickCapabilities {
    static func extensions(from listing: String) -> (inputs: Set<String>, outputs: Set<String>) {
        var inputs = Set<String>()
        var outputs = Set<String>()
        let aliases: [String: [String]] = [
            "JPEG": ["jpg", "jpeg"], "JPG": ["jpg", "jpeg"], "PNG": ["png"], "WEBP": ["webp"],
            "HEIC": ["heic", "heif"], "TIFF": ["tif", "tiff"], "BMP": ["bmp"], "GIF": ["gif"],
            "AVIF": ["avif"], "ICO": ["ico"], "SVG": ["svg"], "JP2": ["jp2"],
        ]
        for line in listing.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 3 else { continue }
            let name = String(columns[0]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            let mode = String(columns[2]).lowercased()
            guard let formats = aliases[name.uppercased()] else { continue }
            if mode.contains("r") { inputs.formUnion(formats) }
            if mode.contains("w") { outputs.formUnion(formats) }
        }
        return (inputs, outputs)
    }
}

private enum PandocCapabilities {
    private static let extensionMap: [String: String] = [
        "md": "markdown", "markdown": "markdown", "txt": "plain", "html": "html", "htm": "html",
        "docx": "docx", "odt": "odt", "rtf": "rtf", "epub": "epub", "pptx": "pptx",
        "org": "org", "rst": "rst", "tex": "latex", "json": "json", "csv": "csv", "tsv": "tsv",
    ]

    static func extensions(inputs: String, outputs: String) -> (inputs: Set<String>, outputs: Set<String>) {
        let inputNames = Set(inputs.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let outputNames = Set(outputs.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let inputExtensions = Set(extensionMap.compactMap { inputNames.contains($0.value) ? $0.key : nil })
        let outputExtensions = Set(extensionMap.compactMap { outputNames.contains($0.value) ? $0.key : nil })
        return (inputExtensions, outputExtensions)
    }
}

private enum OfficeCapabilities {
    private static let textDocuments: Set<String> = ["doc", "docx", "odt", "rtf", "txt", "html"]
    private static let presentations: Set<String> = ["ppt", "pptx", "odp"]
    private static let spreadsheets: Set<String> = ["xls", "xlsx", "ods", "csv"]

    static func outputs(for input: String) -> Set<String>? {
        if textDocuments.contains(input) { return textDocuments.union(["pdf"]) }
        if presentations.contains(input) { return presentations.union(["pdf"]) }
        if spreadsheets.contains(input) { return spreadsheets.union(["pdf"]) }
        return nil
    }

    static func probe(_ executable: URL) -> (inputs: Set<String>, outputs: Set<String>) {
        guard let result = try? ProcessRunner.run(executable: executable, arguments: ["--headless", "--version"]), result.status == 0 else { return ([], []) }
        let inputs = textDocuments.union(presentations).union(spreadsheets)
        let outputs = inputs.union(["pdf"])
        return (inputs, outputs)
    }
}

private enum ConversionCatalog {
    static let formats: [MorphFormat] = [
        MorphFormat("png", "PNG", .image), MorphFormat("jpg", "JPEG", .image), MorphFormat("jpeg", "JPEG", .image),
        MorphFormat("webp", "WebP", .image), MorphFormat("heic", "HEIC", .image), MorphFormat("heif", "HEIF", .image),
        MorphFormat("tiff", "TIFF", .image), MorphFormat("tif", "TIFF", .image), MorphFormat("bmp", "BMP", .image),
        MorphFormat("gif", "GIF", .image), MorphFormat("svg", "SVG", .image), MorphFormat("ico", "ICO", .image), MorphFormat("avif", "AVIF", .image),
        MorphFormat("mp4", "MP4", .video), MorphFormat("mov", "MOV", .video), MorphFormat("mkv", "MKV", .video),
        MorphFormat("webm", "WebM", .video), MorphFormat("avi", "AVI", .video), MorphFormat("gif", "GIF", .video),
        MorphFormat("mpeg", "MPEG", .video), MorphFormat("wmv", "WMV", .video), MorphFormat("flv", "FLV", .video),
        MorphFormat("mp3", "MP3", .audio), MorphFormat("wav", "WAV", .audio), MorphFormat("flac", "FLAC", .audio),
        MorphFormat("aac", "AAC", .audio), MorphFormat("m4a", "M4A", .audio), MorphFormat("ogg", "OGG", .audio),
        MorphFormat("opus", "Opus", .audio), MorphFormat("aiff", "AIFF", .audio), MorphFormat("wma", "WMA", .audio),
        MorphFormat("pdf", "PDF", .document), MorphFormat("docx", "Word document", .document), MorphFormat("doc", "Word 97–2003", .document),
        MorphFormat("odt", "OpenDocument text", .document), MorphFormat("rtf", "Rich Text", .document), MorphFormat("txt", "Plain text", .document),
        MorphFormat("html", "HTML", .document), MorphFormat("epub", "EPUB", .document), MorphFormat("md", "Markdown", .document),
        MorphFormat("pptx", "PowerPoint", .document), MorphFormat("ppt", "PowerPoint 97–2003", .document), MorphFormat("odp", "OpenDocument presentation", .document),
        MorphFormat("xlsx", "Excel workbook", .spreadsheet), MorphFormat("xls", "Excel 97–2003", .spreadsheet),
        MorphFormat("csv", "CSV", .spreadsheet), MorphFormat("tsv", "TSV", .spreadsheet), MorphFormat("ods", "OpenDocument spreadsheet", .spreadsheet),
        MorphFormat("json", "JSON", .spreadsheet), MorphFormat("xml", "XML", .spreadsheet), MorphFormat("yaml", "YAML", .spreadsheet), MorphFormat("yml", "YAML", .spreadsheet), MorphFormat("toml", "TOML", .spreadsheet),
        MorphFormat("zip", "ZIP archive", .archive), MorphFormat("7z", "7-Zip archive", .archive), MorphFormat("tar.gz", "GZIP TAR archive", .archive),
        MorphFormat("gz", "GZIP", .archive), MorphFormat("bz2", "BZIP2", .archive), MorphFormat("xz", "XZ", .archive), MorphFormat("rar", "RAR archive", .archive),
    ]

    static func buildRoutes(statuses: [EngineID: EngineStatus]) -> [ConversionRoute] {
        var result: [ConversionRoute] = []
        func add(_ source: String, _ output: String, _ engine: EngineID, _ note: String, category: FormatCategory? = nil) {
            guard let format = formats.first(where: { $0.fileExtension == output && (category == nil || $0.category == category!) }) else { return }
            guard statuses[engine]?.isInstalled == true else { return }
            result.append(ConversionRoute(inputExtension: source, output: format, engine: engine, description: note))
        }

        let imageInputs = statuses[.nativeImage]?.supportedInputExtensions ?? []
        let imageOutputs = statuses[.nativeImage]?.supportedOutputExtensions ?? []
        for source in imageInputs {
            for output in imageOutputs where source != output {
                add(source, output, .nativeImage, "Convert using Apple ImageIO", category: .image)
            }
            add(source, "pdf", .nativePDF, "Create a PDF using Apple PDFKit")
        }

        let magickInputs = statuses[.imageMagick]?.supportedInputExtensions ?? []
        let magickOutputs = statuses[.imageMagick]?.supportedOutputExtensions ?? []
        for source in magickInputs {
            for output in magickOutputs where source != output {
                add(source, output, .imageMagick, "Convert using ImageMagick", category: .image)
            }
        }

        let mediaFormats = formats.filter { $0.category == .audio || $0.category == .video }
        let ffmpegInputs = statuses[.ffmpeg]?.supportedInputExtensions ?? []
        let ffmpegOutputs = statuses[.ffmpeg]?.supportedOutputExtensions ?? []
        let audioInputs: Set<String> = ["mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "aiff", "aif", "wma"]
        let videoInputs: Set<String> = ["mp4", "mov", "mkv", "webm", "avi", "gif", "mpeg", "mpg", "wmv", "flv", "3gp", "3g2"]
        for source in ffmpegInputs {
            let sourceIsAudio = audioInputs.contains(source)
            let sourceIsVideo = videoInputs.contains(source)
            guard sourceIsAudio || sourceIsVideo else { continue }
            for format in mediaFormats where format.fileExtension != source && ffmpegOutputs.contains(format.fileExtension) {
                let outputIsAudio = format.category == .audio
                if outputIsAudio && !sourceIsAudio && !sourceIsVideo { continue }
                if !outputIsAudio && !sourceIsVideo { continue }
                guard let status = statuses[.ffmpeg], status.isInstalled else { continue }
                let outputFormat = format.fileExtension == "gif" ? MorphFormat("gif", "GIF animation", .video) : format
                result.append(ConversionRoute(inputExtension: source, output: outputFormat, engine: .ffmpeg, description: "Convert using the installed FFmpeg build"))
            }
        }

        let pandoc = statuses[.pandoc]
        if let pandoc, pandoc.isInstalled {
            let documentFormats = formats.filter { $0.category == .document }
            for source in pandoc.supportedInputExtensions {
                for format in documentFormats where source != format.fileExtension && pandoc.supportedOutputExtensions.contains(format.fileExtension) {
                    result.append(ConversionRoute(inputExtension: source, output: format, engine: .pandoc, description: "Convert using Pandoc"))
                }
            }
        }

        if statuses[.poppler]?.isInstalled == true {
            add("pdf", "txt", .poppler, "Extract PDF text using Poppler")
        }

        if let office = statuses[.libreOffice], office.isInstalled {
            for source in office.supportedInputExtensions {
                guard let compatibleOutputs = OfficeCapabilities.outputs(for: source) else { continue }
                for output in compatibleOutputs where source != output && office.supportedOutputExtensions.contains(output) {
                    add(source, output, .libreOffice, "Convert using LibreOffice")
                }
            }
        }

        let structuredFormats = ["json", "yaml", "yml", "toml", "csv", "tsv"]
        for source in structuredFormats {
            for output in structuredFormats where source != output {
                add(source, output, .structuredData, "Convert structured data locally")
            }
        }
        for format in ["json", "yaml", "yml", "toml"] {
            add(format, "xml", .structuredData, "Convert structured data locally")
            add("xml", format, .structuredData, "Convert structured data locally")
        }

        if statuses[.archive]?.isInstalled == true {
            add("zip", "tar.gz", .archive, "Repackage with built-in macOS archive tools")
            add("tar.gz", "zip", .archive, "Repackage with built-in macOS archive tools")
            add("tgz", "zip", .archive, "Repackage with built-in macOS archive tools")
        }

        let sevenZip = statuses[.sevenZip]
        if let sevenZip, sevenZip.isInstalled {
            for input in sevenZip.supportedInputExtensions {
                for output in sevenZip.supportedOutputExtensions where input != output {
                    add(input, output, .sevenZip, "Convert with 7-Zip", category: .archive)
                }
            }
        }

        return Array(Set(result)).sorted {
            let firstPriority = enginePriority($0.engine)
            let secondPriority = enginePriority($1.engine)
            if firstPriority != secondPriority { return firstPriority < secondPriority }
            if $0.output.category.rawValue != $1.output.category.rawValue { return $0.output.category.rawValue < $1.output.category.rawValue }
            if $0.output.displayName != $1.output.displayName { return $0.output.displayName < $1.output.displayName }
            return $0.inputExtension < $1.inputExtension
        }
    }

    private static func enginePriority(_ id: EngineID) -> Int {
        switch id {
        case .nativeImage, .nativePDF, .structuredData, .archive: 0
        case .ffmpeg, .pandoc, .poppler: 1
        case .imageMagick, .libvips, .ghostscript, .sevenZip, .libreOffice: 2
        }
    }
}

public extension EngineRegistry {
    func availableOutputs(for inputURL: URL) -> [ConversionRoute] {
        let known = Set(routes.map(\.inputExtension))
        guard let input = inputURL.morphExtension(knownExtensions: known) else { return [] }
        return routes.filter { $0.inputExtension == input }
    }

    func routes(from inputExtension: String, to outputExtension: String) -> [ConversionRoute] {
        let normalizedInput = inputExtension.lowercased()
        let normalizedOutput = outputExtension.lowercased()
        return routes.filter { $0.inputExtension == normalizedInput && $0.output.fileExtension == normalizedOutput }
    }
}
