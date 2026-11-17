import AppKit
import Combine
import Foundation
import MorphCore

enum OutputMode: String, CaseIterable, Identifiable, Codable {
    case alongsideOriginal = "Beside each original"
    case morphFolder = "Morph Output folder"
    case custom = "Choose a folder"

    var id: String { rawValue }
}

enum QuickAction: String, CaseIterable, Identifiable, Hashable {
    case inspectMetadata = "Inspect file metadata"
    case resizeImages = "Resize images to 50%"
    case mergePDFs = "Merge selected PDFs"
    case extractPDFPages = "Extract PDF pages…"
    case trimVideo = "Trim video…"
    case splitPDF = "Split PDF into pages"
    case compressPDF = "Compress PDF"
    case extractZIP = "Extract ZIP archive"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .inspectMetadata: "info.circle"
        case .resizeImages: "arrow.down.right.and.arrow.up.left"
        case .mergePDFs: "doc.on.doc"
        case .extractPDFPages: "doc.text.magnifyingglass"
        case .trimVideo: "scissors"
        case .splitPDF: "square.split.2x1"
        case .compressPDF: "arrow.down.doc"
        case .extractZIP: "archivebox"
        }
    }
}

struct MorphSettings: Codable, Sendable {
    var outputMode: OutputMode
    var customOutputPath: String?
    var imageQuality: Double
    var revealOutputAfterConversion: Bool
    var pdfCompressionPreset: PDFCompressionPreset

    init(
        outputMode: OutputMode = .alongsideOriginal,
        customOutputPath: String? = nil,
        imageQuality: Double = 0.85,
        revealOutputAfterConversion: Bool = true,
        pdfCompressionPreset: PDFCompressionPreset = .balanced
    ) {
        self.outputMode = outputMode
        self.customOutputPath = customOutputPath
        self.imageQuality = imageQuality
        self.revealOutputAfterConversion = revealOutputAfterConversion
        self.pdfCompressionPreset = pdfCompressionPreset
    }

    private enum CodingKeys: String, CodingKey {
        case outputMode, customOutputPath, imageQuality, revealOutputAfterConversion, pdfCompressionPreset
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputMode = try values.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .alongsideOriginal
        customOutputPath = try values.decodeIfPresent(String.self, forKey: .customOutputPath)
        imageQuality = try values.decodeIfPresent(Double.self, forKey: .imageQuality) ?? 0.85
        revealOutputAfterConversion = try values.decodeIfPresent(Bool.self, forKey: .revealOutputAfterConversion) ?? true
        pdfCompressionPreset = try values.decodeIfPresent(PDFCompressionPreset.self, forKey: .pdfCompressionPreset) ?? .balanced
    }
}

struct HistoryItem: Codable, Identifiable, Sendable {
    let id: UUID
    let inputName: String
    let outputPath: String
    let engineName: String
    let date: Date
}

struct MetadataReport: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let entries: [FileMetadataEntry]
    let error: String?
}

@MainActor
final class MorphModel: ObservableObject {
    static let shared = MorphModel()

    @Published private(set) var registry: EngineRegistry?
    @Published private(set) var isDiscovering = true
    @Published var selectedFiles: [URL] = []
    @Published var selectedOutputExtension: String?
    @Published var selectedConversionPreset: ConversionPreset?
    @Published private(set) var isConverting = false
    @Published private(set) var isRunningUtility = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentFileName: String?
    @Published private(set) var conversionMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var history: [HistoryItem] = []
    @Published private(set) var metadataReports: [MetadataReport] = []
    @Published var isShowingMetadata = false
    @Published private(set) var updatesAvailable: Set<EngineID> = []
    @Published private(set) var activeEngineAction: EngineID?
    @Published private(set) var isRunningUtilityCancellable = false
    @Published var settings: MorphSettings { didSet { saveSettings() } }
    @Published var selectedSection = AppSection.overview

    private var cancellation: CancellationToken?
    private var utilityCancellation: CancellationToken?
    private let settingsKey = "com.lakshaychawla.Morph.settings"
    private let historyURL: URL

    private init() {
        if let data = UserDefaults.standard.data(forKey: "com.lakshaychawla.Morph.settings"),
           let decoded = try? JSONDecoder().decode(MorphSettings.self, from: data) {
            settings = decoded
        } else {
            settings = MorphSettings()
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Morph", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        historyURL = support.appendingPathComponent("history.json")
        loadHistory()
        refreshEngines()
    }

    var outputFormats: [MorphFormat] {
        guard let registry, !selectedFiles.isEmpty else { return [] }
        let outputByExtension = Dictionary(grouping: registry.availableOutputs(for: selectedFiles[0]).map(\.output), by: \.fileExtension)
        return outputByExtension.compactMap { ext, formats in
            guard selectedFiles.dropFirst().allSatisfy({ file in registry.routes(from: detectedExtension(file, registry: registry), to: ext).isEmpty == false }) else { return nil }
            return formats.first
        }.sorted {
            if $0.category.rawValue == $1.category.rawValue { return $0.displayName < $1.displayName }
            return $0.category.rawValue < $1.category.rawValue
        }
    }

    var availableConversionPresets: [ConversionPreset] {
        let inputExtensions = Set(selectedFiles.map { $0.pathExtension.lowercased() })
        let outputExtensions = Set(outputFormats.map(\.fileExtension))
        return ConversionPreset.allCases.filter {
            $0.isAvailable(inputExtensions: inputExtensions, outputExtensions: outputExtensions)
        }
    }

    var availableRouteCount: Int { registry?.routes.count ?? 0 }
    var activeEngineCount: Int {
        var routeEngines = Set(registry?.routes.map(\.engine) ?? [])
        if registry?.status(for: .ghostscript)?.isInstalled == true { routeEngines.insert(.ghostscript) }
        return routeEngines.union([.nativeImage, .nativePDF, .structuredData, .archive]).count
    }

    var quickActions: [QuickAction] {
        guard !selectedFiles.isEmpty else { return [] }
        let extensions = selectedFiles.map { $0.pathExtension.lowercased() }
        var actions: [QuickAction] = []
        if extensions.allSatisfy({ ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp"].contains($0) }) {
            actions.append(.resizeImages)
        }
        if extensions.allSatisfy({ ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp", "avif", "pdf"].contains($0) }) {
            actions.insert(.inspectMetadata, at: 0)
        }
        if extensions.count >= 2 && extensions.allSatisfy({ $0 == "pdf" }) { actions.append(.mergePDFs) }
        if extensions.count == 1, extensions[0] == "pdf" {
            actions.append(.extractPDFPages)
            actions.append(.splitPDF)
            actions.append(.compressPDF)
        }
        let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "mpeg", "mpg", "wmv", "flv", "3gp", "3g2"]
        if extensions.count == 1, let inputExtension = extensions.first, videoExtensions.contains(inputExtension) {
            if let status = registry?.status(for: .ffmpeg), status.isInstalled {
                if status.supportedInputExtensions.contains(inputExtension), status.supportedOutputExtensions.contains("mp4") {
                    actions.append(.trimVideo)
                }
            } else {
                actions.append(.trimVideo)
            }
        }
        if extensions.count == 1, extensions[0] == "zip" { actions.append(.extractZIP) }
        return actions
    }

    func importFiles(_ urls: [URL]) {
        selectedFiles = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        selectedOutputExtension = nil
        selectedConversionPreset = nil
        selectedSection = .convert
        lastError = nil
    }

    func handleExternalURL(_ url: URL) {
        guard url.scheme == "morph", url.host == "convert",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "manifest" })?.value,
              let uuid = UUID(uuidString: token) else { return }

        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Morph/QuickActions", isDirectory: true)
        let manifestURL = directory.appendingPathComponent("\(uuid.uuidString.lowercased()).plist")
        guard manifestURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let paths = manifest["paths"] as? [String], !paths.isEmpty else {
            selectedSection = .convert
            lastError = "Morph could not read the selected files from Finder. Try adding them again."
            return
        }

        try? FileManager.default.removeItem(at: manifestURL)
        importFiles(paths.map { URL(fileURLWithPath: $0) })
        if selectedFiles.isEmpty { lastError = "The selected files are no longer available." }
    }

    func removeFile(_ url: URL) {
        selectedFiles.removeAll { $0 == url }
        if selectedFiles.isEmpty {
            selectedOutputExtension = nil
            selectedConversionPreset = nil
        } else {
            if let selectedConversionPreset, !availableConversionPresets.contains(selectedConversionPreset) {
                self.selectedConversionPreset = nil
                selectedOutputExtension = nil
            } else if let selectedOutputExtension, !outputFormats.contains(where: { $0.fileExtension == selectedOutputExtension }) {
                self.selectedOutputExtension = nil
                selectedConversionPreset = nil
            }
        }
    }

    func clearSelection() {
        selectedFiles = []
        selectedOutputExtension = nil
        selectedConversionPreset = nil
        selectedSection = .overview
    }

    func apply(_ preset: ConversionPreset) {
        guard availableConversionPresets.contains(preset) else { return }
        selectedConversionPreset = preset
        selectedOutputExtension = preset.outputExtension
    }

    func selectOutputFormat(_ format: MorphFormat) {
        selectedOutputExtension = format.fileExtension
        selectedConversionPreset = nil
    }

    func refreshEngines() {
        refreshEngines(onCompletion: nil)
    }

    private func refreshEngines(onCompletion: (() -> Void)?) {
        isDiscovering = true
        Task.detached(priority: .utility) {
            let freshRegistry = EngineRegistry.discover()
            await MainActor.run {
                self.registry = freshRegistry
                self.isDiscovering = false
                onCompletion?()
            }
        }
    }

    func startConversion(to format: MorphFormat, preset: ConversionPreset? = nil) {
        guard let registry, !isConverting else { return }
        let inputs = selectedFiles
        guard !inputs.isEmpty else { return }
        if let preset,
           (!availableConversionPresets.contains(preset) || preset.outputExtension != format.fileExtension) {
            return
        }
        selectedOutputExtension = format.fileExtension
        selectedConversionPreset = preset
        isConverting = true
        progress = 0
        currentFileName = nil
        conversionMessage = "Preparing conversion…"
        lastError = nil
        let token = CancellationToken()
        cancellation = token
        let currentSettings = settings
        let jobs = inputs.map { ($0, Self.outputDirectory(for: $0, settings: currentSettings)) }

        Task.detached(priority: .userInitiated) {
            let service = ConversionService(registry: registry)
            var results: [ConversionResult] = []
            var failures: [String] = []
            for (index, job) in jobs.enumerated() {
                let input = job.0
                if token.isCancelled { break }
                await MainActor.run {
                    self.currentFileName = input.lastPathComponent
                    self.progress = Double(index) / Double(inputs.count)
                    self.conversionMessage = "Converting \(index + 1) of \(inputs.count)"
                }
                do {
                    let selectedFormat = registry.availableOutputs(for: input).first(where: { $0.output.fileExtension == format.fileExtension })?.output ?? format
                    let imageQuality = preset?.imageQualityOverride ?? currentSettings.imageQuality
                    let request = ConversionRequest(inputURL: input, outputFormat: selectedFormat, outputDirectory: job.1, imageQuality: imageQuality)
                    results.append(try service.convert(request, cancellation: token))
                } catch {
                    if !token.isCancelled {
                        failures.append("\(input.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            let completedResults = results
            let completedFailures = failures
            await MainActor.run {
                self.isConverting = false
                self.progress = 1
                self.currentFileName = nil
                self.cancellation = nil
                if !completedResults.isEmpty {
                    self.history.insert(contentsOf: completedResults.map {
                        HistoryItem(id: UUID(), inputName: $0.inputURL.lastPathComponent, outputPath: $0.outputURL.path, engineName: $0.engine.displayName, date: $0.completedAt)
                    }, at: 0)
                    self.history = Array(self.history.prefix(200))
                    self.saveHistory()
                }
                if token.isCancelled {
                    self.conversionMessage = "Cancelled. Originals were left unchanged."
                } else if completedFailures.isEmpty {
                    self.conversionMessage = "Finished \(completedResults.count) conversion\(completedResults.count == 1 ? "" : "s")."
                } else {
                    self.lastError = completedFailures.joined(separator: "\n\n")
                    self.conversionMessage = "Finished with \(completedFailures.count) error\(completedFailures.count == 1 ? "" : "s")."
                }
                if currentSettings.revealOutputAfterConversion, let output = completedResults.last?.outputURL {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            }
        }
    }

    func cancelConversion() {
        cancellation?.cancel()
    }

    func perform(_ action: QuickAction) {
        guard quickActions.contains(action), !isConverting, !isRunningUtility, activeEngineAction == nil else { return }
        if action == .inspectMetadata {
            inspectMetadata(for: selectedFiles)
            return
        }
        if action == .extractPDFPages {
            requestPDFPageRange()
            return
        }
        if action == .trimVideo {
            requestVideoTrim()
            return
        }
        if action == .compressPDF, isDiscovering {
            conversionMessage = "Checking local conversion engines…"
            return
        }
        if action == .compressPDF, registry?.status(for: .ghostscript)?.isInstalled != true {
            selectedSection = .engines
            installEngine(
                .ghostscript,
                reason: "Ghostscript is required for local PDF compression. It also enables additional PDF and PostScript processing.",
                onSuccess: { [weak self] in
                    self?.selectedSection = .convert
                    self?.perform(action)
                },
                onCancel: { [weak self] in self?.selectedSection = .convert }
            )
            return
        }
        let inputs = selectedFiles
        let currentSettings = settings
        let outputDirectories = inputs.map { Self.outputDirectory(for: $0, settings: currentSettings) }
        isRunningUtility = true
        let utilityToken = CancellationToken()
        utilityCancellation = action == .compressPDF ? utilityToken : nil
        isRunningUtilityCancellable = action == .compressPDF
        conversionMessage = "Preparing \(action.rawValue.lowercased())…"
        lastError = nil

        Task.detached(priority: .userInitiated) {
            do {
                let outputs: [URL]
                switch action {
                case .resizeImages:
                    outputs = try zip(inputs, outputDirectories).map { pair in
                        try MorphFileOperations.resizeImage(pair.0, scale: 0.5, outputDirectory: pair.1, quality: currentSettings.imageQuality)
                    }
                case .mergePDFs:
                    outputs = [try MorphFileOperations.mergePDFs(inputs, outputDirectory: outputDirectories.first)]
                case .splitPDF:
                    outputs = try MorphFileOperations.splitPDF(inputs[0], outputDirectory: outputDirectories[0])
                case .compressPDF:
                    outputs = [try MorphFileOperations.compressPDF(
                        inputs[0],
                        preset: currentSettings.pdfCompressionPreset,
                        outputDirectory: outputDirectories[0],
                        cancellation: utilityToken
                    )]
                case .extractZIP:
                    outputs = [try MorphFileOperations.extractZIP(inputs[0], outputDirectory: outputDirectories[0])]
                case .inspectMetadata:
                    outputs = []
                case .extractPDFPages:
                    outputs = []
                case .trimVideo:
                    outputs = []
                }
                await MainActor.run {
                    self.isRunningUtility = false
                    self.utilityCancellation = nil
                    self.isRunningUtilityCancellable = false
                    self.conversionMessage = "Created \(outputs.count) output item\(outputs.count == 1 ? "" : "s")."
                    self.history.insert(contentsOf: outputs.map {
                        let engine: EngineID = switch action {
                        case .resizeImages: .nativeImage
                        case .extractZIP: .archive
                        case .compressPDF: .ghostscript
                        case .inspectMetadata: .nativeImage
                        case .extractPDFPages: .nativePDF
                        case .trimVideo: .ffmpeg
                        default: .nativePDF
                        }
                        return HistoryItem(id: UUID(), inputName: inputs[0].lastPathComponent, outputPath: $0.path, engineName: engine.displayName, date: Date())
                    }, at: 0)
                    self.history = Array(self.history.prefix(200))
                    self.saveHistory()
                    if currentSettings.revealOutputAfterConversion, let output = outputs.first {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRunningUtility = false
                    self.utilityCancellation = nil
                    self.isRunningUtilityCancellable = false
                    if let morphError = error as? MorphError, case .cancelled = morphError {
                        self.lastError = nil
                        self.conversionMessage = "PDF compression cancelled. The original was left unchanged."
                    } else {
                        self.lastError = error.localizedDescription
                        self.conversionMessage = "The operation could not be completed."
                    }
                }
            }
        }
    }

    func cancelUtility() {
        utilityCancellation?.cancel()
    }

    func batchRenamePlan(inputs: [URL], prefix: String) throws -> [BatchRenameTarget] {
        let currentSettings = settings
        let directories = inputs.map { Self.outputDirectory(for: $0, settings: currentSettings) }
        return try MorphFileOperations.planBatchRenamedCopies(
            inputs: inputs,
            prefix: prefix,
            outputDirectories: directories
        )
    }

    func createRenamedCopies(inputs: [URL], prefix: String) {
        guard !isConverting, !isRunningUtility, activeEngineAction == nil else { return }
        let plan: [BatchRenameTarget]
        do {
            plan = try batchRenamePlan(inputs: inputs, prefix: prefix)
        } catch {
            lastError = error.localizedDescription
            conversionMessage = "Review the selected files and name prefix."
            return
        }

        let currentSettings = settings
        let utilityToken = CancellationToken()
        utilityCancellation = utilityToken
        isRunningUtility = true
        isRunningUtilityCancellable = true
        progress = 0
        currentFileName = nil
        conversionMessage = "Preparing renamed copies…"
        lastError = nil

        Task.detached(priority: .userInitiated) {
            var completed: [(BatchRenameTarget, URL)] = []
            var failures: [String] = []
            for (index, target) in plan.enumerated() {
                if utilityToken.isCancelled { break }
                await MainActor.run {
                    self.progress = Double(index) / Double(plan.count)
                    self.currentFileName = target.inputURL.lastPathComponent
                    self.conversionMessage = "Copying \(index + 1) of \(plan.count)"
                }
                do {
                    let output = try MorphFileOperations.createRenamedCopy(target, cancellation: utilityToken)
                    completed.append((target, output))
                } catch let error as MorphError {
                    if case .cancelled = error { break }
                    failures.append("\(target.inputURL.lastPathComponent): \(error.localizedDescription)")
                } catch {
                    failures.append("\(target.inputURL.lastPathComponent): \(error.localizedDescription)")
                }
            }

            let finished = completed
            let failed = failures
            await MainActor.run {
                self.isRunningUtility = false
                self.utilityCancellation = nil
                self.isRunningUtilityCancellable = false
                self.progress = 1
                self.currentFileName = nil
                if !finished.isEmpty {
                    self.history.insert(contentsOf: finished.map { target, output in
                        HistoryItem(
                            id: UUID(),
                            inputName: target.inputURL.lastPathComponent,
                            outputPath: output.path,
                            engineName: "Morph batch rename",
                            date: Date()
                        )
                    }, at: 0)
                    self.history = Array(self.history.prefix(200))
                    self.saveHistory()
                }

                if utilityToken.isCancelled {
                    self.conversionMessage = "Cancelled after creating \(finished.count) renamed cop\(finished.count == 1 ? "y" : "ies"). Originals were left unchanged."
                } else if failed.isEmpty {
                    self.conversionMessage = "Created \(finished.count) renamed cop\(finished.count == 1 ? "y" : "ies"). Originals were left unchanged."
                } else {
                    self.lastError = failed.joined(separator: "\n\n")
                    self.conversionMessage = "Created \(finished.count) renamed copies; \(failed.count) file\(failed.count == 1 ? "" : "s") failed. Originals were left unchanged."
                }
                if currentSettings.revealOutputAfterConversion, !finished.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(finished.map { $0.1 })
                }
            }
        }
    }

    private func inspectMetadata(for inputs: [URL]) {
        isRunningUtility = true
        conversionMessage = "Reading file metadata…"
        lastError = nil
        Task.detached(priority: .userInitiated) {
            let reports = inputs.map { input -> MetadataReport in
                do {
                    return MetadataReport(fileName: input.lastPathComponent, entries: try MorphFileOperations.inspectMetadata(input), error: nil)
                } catch {
                    return MetadataReport(fileName: input.lastPathComponent, entries: [], error: error.localizedDescription)
                }
            }
            await MainActor.run {
                self.metadataReports = reports
                self.isShowingMetadata = true
                self.isRunningUtility = false
                self.conversionMessage = "Read metadata from \(reports.count) file\(reports.count == 1 ? "" : "s"). Originals were not changed."
            }
        }
    }

    private func requestPDFPageRange() {
        guard selectedFiles.count == 1, let input = selectedFiles.first else { return }
        let alert = NSAlert()
        alert.messageText = "Extract PDF pages"
        alert.informativeText = "Enter page numbers or ascending ranges, for example 1-3, 5. The extracted pages will be saved as a new PDF."
        alert.alertStyle = .informational
        let field = NSTextField(string: "")
        field.placeholderString = "1-3, 5"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Extract")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        extractPDFPages(pageRange: field.stringValue, input: input)
    }

    private func extractPDFPages(pageRange: String, input: URL) {
        guard !isConverting, !isRunningUtility, activeEngineAction == nil else { return }
        let outputDirectory = Self.outputDirectory(for: input, settings: settings)
        let currentSettings = settings
        isRunningUtility = true
        isRunningUtilityCancellable = false
        conversionMessage = "Extracting PDF pages…"
        lastError = nil

        Task.detached(priority: .userInitiated) {
            do {
                let output = try MorphFileOperations.extractPDFPages(input, pageRange: pageRange, outputDirectory: outputDirectory)
                await MainActor.run {
                    self.isRunningUtility = false
                    self.conversionMessage = "Extracted selected PDF pages."
                    self.history.insert(HistoryItem(
                        id: UUID(),
                        inputName: input.lastPathComponent,
                        outputPath: output.path,
                        engineName: EngineID.nativePDF.displayName,
                        date: Date()
                    ), at: 0)
                    self.history = Array(self.history.prefix(200))
                    self.saveHistory()
                    if currentSettings.revealOutputAfterConversion {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRunningUtility = false
                    self.lastError = error.localizedDescription
                    self.conversionMessage = "PDF page extraction could not be completed."
                }
            }
        }
    }

    private func requestVideoTrim() {
        guard selectedFiles.count == 1, let input = selectedFiles.first else { return }
        guard !isDiscovering else {
            conversionMessage = "Checking local video engines…"
            return
        }
        let alert = NSAlert()
        alert.messageText = "Trim video"
        alert.informativeText = "Enter the start and end times in seconds. Morph will create an H.264 MP4 copy. Re-encoding can change quality, and subtitles or some metadata may not carry over. The original stays unchanged."
        alert.alertStyle = .informational
        let startField = NSTextField(string: "0")
        startField.placeholderString = "Start (seconds)"
        let endField = NSTextField(string: "10")
        endField.placeholderString = "End (seconds)"
        startField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        endField.frame = startField.frame
        let fields = NSStackView(views: [startField, endField])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.alignment = .leading
        alert.accessoryView = fields
        alert.addButton(withTitle: "Trim")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        trimVideo(start: startField.stringValue, end: endField.stringValue, input: input)
    }

    private func trimVideo(start: String, end: String, input: URL) {
        let range: (startSeconds: Double, durationSeconds: Double)
        do {
            range = try MorphFileOperations.parseVideoTrimRange(start: start, end: end)
        } catch {
            lastError = error.localizedDescription
            conversionMessage = "Video trimming could not be completed."
            return
        }
        guard let status = registry?.status(for: .ffmpeg), status.isInstalled else {
            installEngine(
                .ffmpeg,
                reason: "FFmpeg is required to trim video to an H.264 MP4 clip. It also enables local audio/video conversion and audio extraction.",
                onSuccess: { [weak self] in
                    self?.selectedSection = .convert
                    self?.runVideoTrim(input: input, range: range)
                },
                onCancel: { [weak self] in self?.selectedSection = .convert }
            )
            return
        }
        guard status.supportedInputExtensions.contains(input.pathExtension.lowercased()),
              status.supportedOutputExtensions.contains("mp4") else {
            lastError = "The installed FFmpeg build cannot trim this input to MP4."
            conversionMessage = "Video trimming is unavailable for this format."
            return
        }
        runVideoTrim(input: input, range: range)
    }

    private func runVideoTrim(input: URL, range: (startSeconds: Double, durationSeconds: Double)) {
        guard !isConverting, !isRunningUtility, activeEngineAction == nil else { return }
        let outputDirectory = Self.outputDirectory(for: input, settings: settings)
        let currentSettings = settings
        let start = range.startSeconds
        let end = start + range.durationSeconds
        isRunningUtility = true
        isRunningUtilityCancellable = true
        conversionMessage = "Trimming video…"
        lastError = nil
        let token = CancellationToken()
        utilityCancellation = token

        Task.detached(priority: .userInitiated) {
            do {
                let output = try MorphFileOperations.trimVideo(
                    input,
                    startSeconds: start,
                    endSeconds: end,
                    outputDirectory: outputDirectory,
                    cancellation: token
                )
                await MainActor.run {
                    self.isRunningUtility = false
                    self.isRunningUtilityCancellable = false
                    self.utilityCancellation = nil
                    self.conversionMessage = "Created a trimmed MP4 copy."
                    self.history.insert(HistoryItem(
                        id: UUID(),
                        inputName: input.lastPathComponent,
                        outputPath: output.path,
                        engineName: EngineID.ffmpeg.displayName,
                        date: Date()
                    ), at: 0)
                    self.history = Array(self.history.prefix(200))
                    self.saveHistory()
                    if currentSettings.revealOutputAfterConversion {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRunningUtility = false
                    self.isRunningUtilityCancellable = false
                    self.utilityCancellation = nil
                    if let morphError = error as? MorphError, case .cancelled = morphError {
                        self.lastError = nil
                        self.conversionMessage = "Video trimming cancelled. The original was left unchanged."
                    } else {
                        self.lastError = error.localizedDescription
                        self.conversionMessage = "Video trimming could not be completed."
                    }
                }
            }
        }
    }

    func installEngine(
        _ id: EngineID,
        reason: String? = nil,
        onSuccess: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        guard let formula = id.homebrewFormula, activeEngineAction == nil, !isConverting, !isRunningUtility else { return }
        activeEngineAction = id
        conversionMessage = "Checking \(id.displayName) download size…"
        Task { [weak self] in
            let estimate = await Self.estimatedBottleSize(formula: formula)
            guard let self else { return }
            let estimateText = estimate.map { "The current \(formula) bottle is approximately \($0) to download; required dependencies are additional." }
                ?? "A bottle size estimate is unavailable. Homebrew will resolve the formula and dependency download sizes after confirmation."
            let reasonText = reason.map { "\($0)\n\n" } ?? ""
            confirmEngineAction(id: id, action: "Install", message: "\(reasonText)Morph will ask Homebrew to install the ‘\(formula)’ formula and any required dependencies. Homebrew verifies package checksums. \(estimateText) No engine is downloaded until you confirm here.", cancelled: {
                self.finishEngineAction(id)
                self.conversionMessage = "Install cancelled. No output was created."
                onCancel?()
            }) {
                self.runHomebrew(engine: id, arguments: ["install", "--formula", formula], successMessage: "\(id.displayName) installed.", onSuccess: onSuccess)
            }
        }
    }

    func uninstallEngine(_ id: EngineID) {
        guard let formula = id.homebrewFormula, activeEngineAction == nil, !isConverting, !isRunningUtility else { return }
        activeEngineAction = id
        confirmEngineAction(id: id, action: "Uninstall", message: "Homebrew will remove the ‘\(formula)’ formula. Other formulas and shared dependencies are left in place.", cancelled: { [weak self] in
            self?.finishEngineAction(id)
        }) { [weak self] in
            self?.runHomebrew(engine: id, arguments: ["uninstall", "--formula", formula], successMessage: "\(id.displayName) uninstalled.")
        }
    }

    func checkForUpdates(_ id: EngineID) {
        guard activeEngineAction == nil else { return }
        guard let formula = id.homebrewFormula else { return }
        guard let brew = ExecutableLocator.resolve(["brew"]) else {
            lastError = "Homebrew is not installed. Install it from https://brew.sh, then try again."
            return
        }
        Task.detached(priority: .utility) {
            do {
                let result = try ProcessRunner.run(executable: brew, arguments: ["outdated", "--formula", formula])
                guard result.status == 0 else {
                    throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let outdated = !(result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                await MainActor.run {
                    if outdated { self.updatesAvailable.insert(id) } else { self.updatesAvailable.remove(id) }
                    self.conversionMessage = outdated ? "An update is available for \(id.displayName)." : "\(id.displayName) is up to date."
                    self.lastError = nil
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription; self.conversionMessage = nil }
            }
        }
    }

    func updateEngine(_ id: EngineID) {
        guard let formula = id.homebrewFormula, activeEngineAction == nil, !isConverting, !isRunningUtility else { return }
        activeEngineAction = id
        confirmEngineAction(id: id, action: "Update", message: "Homebrew will upgrade the ‘\(formula)’ formula and may download dependencies. No update starts until you confirm here.", cancelled: { [weak self] in
            self?.finishEngineAction(id)
        }) { [weak self] in
            self?.runHomebrew(engine: id, arguments: ["upgrade", "--formula", formula], successMessage: "\(id.displayName) updated.")
        }
    }

    func chooseCustomOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Morph output folder"
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.customOutputPath = url.path
            settings.outputMode = .custom
        }
    }

    func showOutput(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func confirmEngineAction(id: EngineID, action: String, message: String, cancelled: @escaping () -> Void, confirmed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(action) \(id.displayName)?"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { confirmed() }
        else { cancelled() }
    }

    private func runHomebrew(engine id: EngineID, arguments: [String], successMessage: String, refreshAfter: Bool = true, onSuccess: (() -> Void)? = nil) {
        guard let brew = ExecutableLocator.resolve(["brew"]) else {
            finishEngineAction(id)
            lastError = "Homebrew is not installed. Install it from https://brew.sh, then try again."
            return
        }
        conversionMessage = "Running Homebrew…"
        Task.detached(priority: .utility) {
            do {
                let result = try ProcessRunner.run(executable: brew, arguments: arguments)
                guard result.status == 0 else {
                    throw MorphError.processFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Homebrew exited with status \(result.status)." : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                await MainActor.run {
                    self.conversionMessage = successMessage
                    if arguments.first == "install" || arguments.first == "upgrade" { self.updatesAvailable.removeAll() }
                    if refreshAfter {
                        self.refreshEngines {
                            self.finishEngineAction(id)
                            onSuccess?()
                        }
                    } else {
                        self.finishEngineAction(id)
                        onSuccess?()
                    }
                }
            } catch {
                await MainActor.run {
                    self.finishEngineAction(id)
                    self.lastError = error.localizedDescription
                    self.conversionMessage = nil
                }
            }
        }
    }

    private func finishEngineAction(_ id: EngineID) {
        if activeEngineAction == id { activeEngineAction = nil }
    }

    private static func estimatedBottleSize(formula: String) async -> String? {
        guard let apiURL = URL(string: "https://formulae.brew.sh/api/formula/\(formula).json"),
              let (data, apiResponse) = try? await URLSession.shared.data(from: apiURL),
              let apiResponse = apiResponse as? HTTPURLResponse, (200..<300).contains(apiResponse.statusCode),
              let formulaJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stable = formulaJSON["bottle"] as? [String: Any],
              let stableInfo = stable["stable"] as? [String: Any],
              let files = stableInfo["files"] as? [String: [String: Any]] else { return nil }

        let isAppleSilicon = (try? ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/uname"), arguments: ["-m"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == "arm64"
        let macOSName: String
        switch ProcessInfo.processInfo.operatingSystemVersion.majorVersion {
        case 26: macOSName = "tahoe"
        case 15: macOSName = "sequoia"
        case 14: macOSName = "sonoma"
        case 13: macOSName = "ventura"
        case 12: macOSName = "monterey"
        default: return nil
        }
        let platformKey = "\(isAppleSilicon ? "arm64" : "x86_64")_\(macOSName)"
        let candidates = files.keys.filter { $0 == platformKey }
        for key in candidates {
            guard let urlString = files[key]?["url"] as? String,
                  let url = URL(string: urlString), url.scheme == "https",
                  ["ghcr.io", "github.com", "homebrew.bintray.com"].contains(url.host?.lowercased() ?? "") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let response = response as? HTTPURLResponse,
                  (200..<400).contains(response.statusCode),
                  let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), length > 0 else { continue }
            return ByteCountFormatter.string(fromByteCount: length, countStyle: .file)
        }
        return nil
    }

    private static func outputDirectory(for input: URL, settings: MorphSettings) -> URL {
        switch settings.outputMode {
        case .alongsideOriginal: input.deletingLastPathComponent()
        case .morphFolder:
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Morph Output", isDirectory: true)
        case .custom:
            if let path = settings.customOutputPath { URL(fileURLWithPath: path, isDirectory: true) }
            else { input.deletingLastPathComponent() }
        }
    }

    private func detectedExtension(_ url: URL, registry: EngineRegistry) -> String {
        url.morphExtension(knownExtensions: Set(registry.routes.map(\.inputExtension))) ?? url.pathExtension.lowercased()
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: settingsKey) }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let loaded = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        history = loaded
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case convert = "Convert"
    case operations = "Operations"
    case history = "History"
    case engines = "Engines"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .convert: "arrow.triangle.2.circlepath"
        case .operations: "slider.horizontal.3"
        case .history: "clock.arrow.circlepath"
        case .engines: "shippingbox"
        case .settings: "gearshape"
        }
    }
}
