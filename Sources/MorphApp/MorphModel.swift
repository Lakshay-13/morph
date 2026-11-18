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
    case editMetadata = "Edit metadata…"
    case resizeImages = "Resize images to 50%"
    case mergePDFs = "Merge selected PDFs"
    case extractPDFPages = "Extract PDF pages…"
    case trimVideo = "Trim video…"
    case compressVideo = "Compress video…"
    case splitPDF = "Split PDF into pages"
    case compressPDF = "Compress PDF"
    case extractZIP = "Extract ZIP archive"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .inspectMetadata: "info.circle"
        case .editMetadata: "pencil"
        case .resizeImages: "arrow.down.right.and.arrow.up.left"
        case .mergePDFs: "doc.on.doc"
        case .extractPDFPages: "doc.text.magnifyingglass"
        case .trimVideo: "scissors"
        case .compressVideo: "arrow.down.right.and.arrow.up.left"
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
    var finderHiddenOutputExtensions: Set<String>

    init(
        outputMode: OutputMode = .alongsideOriginal,
        customOutputPath: String? = nil,
        imageQuality: Double = 0.85,
        revealOutputAfterConversion: Bool = true,
        pdfCompressionPreset: PDFCompressionPreset = .balanced,
        finderHiddenOutputExtensions: Set<String> = []
    ) {
        self.outputMode = outputMode
        self.customOutputPath = customOutputPath
        self.imageQuality = imageQuality
        self.revealOutputAfterConversion = revealOutputAfterConversion
        self.pdfCompressionPreset = pdfCompressionPreset
        self.finderHiddenOutputExtensions = Set(finderHiddenOutputExtensions.map { $0.lowercased() })
    }

    private enum CodingKeys: String, CodingKey {
        case outputMode, customOutputPath, imageQuality, revealOutputAfterConversion, pdfCompressionPreset, finderHiddenOutputExtensions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputMode = try values.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .alongsideOriginal
        customOutputPath = try values.decodeIfPresent(String.self, forKey: .customOutputPath)
        imageQuality = try values.decodeIfPresent(Double.self, forKey: .imageQuality) ?? 0.85
        revealOutputAfterConversion = try values.decodeIfPresent(Bool.self, forKey: .revealOutputAfterConversion) ?? true
        pdfCompressionPreset = try values.decodeIfPresent(PDFCompressionPreset.self, forKey: .pdfCompressionPreset) ?? .balanced
        finderHiddenOutputExtensions = Set((try values.decodeIfPresent(Set<String>.self, forKey: .finderHiddenOutputExtensions) ?? []).map { $0.lowercased() })
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

enum MetadataSheet: String, Identifiable {
    case inspector
    case editor

    var id: String { rawValue }
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
    @Published var metadataSheet: MetadataSheet?
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
    var finderOutputFormats: [MorphFormat] {
        guard let registry else { return [] }
        let formats = Dictionary(
            registry.routes.map { ($0.output.fileExtension, $0.output) },
            uniquingKeysWith: { first, _ in first }
        )
        return formats.values.sorted {
            if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.fileExtension < $1.fileExtension
        }
    }

    func setFinderOutputEnabled(_ fileExtension: String, enabled: Bool) {
        let normalized = fileExtension.lowercased()
        if enabled {
            settings.finderHiddenOutputExtensions.remove(normalized)
        } else {
            settings.finderHiddenOutputExtensions.insert(normalized)
        }
    }

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
        let editableMetadataExtensions: Set<String> = ["pdf", "jpg", "jpeg", "tif", "tiff"]
        if extensions.allSatisfy(editableMetadataExtensions.contains) {
            actions.insert(.editMetadata, at: actions.contains(.inspectMetadata) ? 1 : 0)
        }
        if extensions.count >= 2 && extensions.allSatisfy({ $0 == "pdf" }) { actions.append(.mergePDFs) }
        if extensions.count == 1, extensions[0] == "pdf" {
            actions.append(.extractPDFPages)
            actions.append(.splitPDF)
            actions.append(.compressPDF)
        }
        let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "mpeg", "mpg", "wmv", "flv", "3gp", "3g2"]
        if !extensions.isEmpty, extensions.allSatisfy(videoExtensions.contains) {
            if let status = registry?.status(for: .ffmpeg), status.isInstalled {
                if status.supportedOutputExtensions.contains("mp4"),
                   extensions.allSatisfy(status.supportedInputExtensions.contains) {
                    actions.append(.compressVideo)
                }
            } else {
                actions.append(.compressVideo)
            }
        }
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
                self.publishFinderSyncPreferences()
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
        if action == .editMetadata {
            metadataSheet = .editor
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
        if action == .compressVideo {
            requestVideoCompression()
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
        utilityCancellation = [.compressPDF, .compressVideo].contains(action) ? utilityToken : nil
        isRunningUtilityCancellable = [.compressPDF, .compressVideo].contains(action)
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
                case .editMetadata:
                    outputs = []
                case .extractPDFPages:
                    outputs = []
                case .trimVideo:
                    outputs = []
                case .compressVideo:
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
                        case .editMetadata: .nativeImage
                        case .extractPDFPages: .nativePDF
                        case .trimVideo: .ffmpeg
                        case .compressVideo: .ffmpeg
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
                        self.conversionMessage = action == .compressVideo
                            ? "Video compression cancelled. Originals were left unchanged."
                            : "PDF compression cancelled. The original was left unchanged."
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
                self.metadataSheet = .inspector
                self.isRunningUtility = false
                self.conversionMessage = "Read metadata from \(reports.count) file\(reports.count == 1 ? "" : "s"). Originals were not changed."
            }
        }
    }

    func applyMetadataEdits(_ edits: FileMetadataEdits) {
        guard quickActions.contains(.editMetadata), edits.hasChanges, !isRunningUtility else { return }
        metadataSheet = nil
        let inputs = selectedFiles
        let currentSettings = settings
        let outputDirectories = inputs.map { Self.outputDirectory(for: $0, settings: currentSettings) }
        isRunningUtility = true
        isRunningUtilityCancellable = false
        conversionMessage = "Writing metadata copies…"
        lastError = nil

        Task.detached(priority: .userInitiated) {
            var completed: [(URL, URL)] = []
            var failures: [String] = []
            for (input, outputDirectory) in zip(inputs, outputDirectories) {
                do {
                    let output = try MorphFileOperations.writeMetadataCopy(input, edits: edits, outputDirectory: outputDirectory)
                    completed.append((input, output))
                } catch {
                    failures.append("\(input.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let finishedCopies = completed
            let failedCopies = failures

            await MainActor.run {
                self.isRunningUtility = false
                let historyItems = finishedCopies.map { input, output in
                    HistoryItem(
                        id: UUID(),
                        inputName: input.lastPathComponent,
                        outputPath: output.path,
                        engineName: input.pathExtension.lowercased() == "pdf" ? EngineID.nativePDF.displayName : EngineID.nativeImage.displayName,
                        date: Date()
                    )
                }
                self.history.insert(contentsOf: historyItems, at: 0)
                self.history = Array(self.history.prefix(200))
                self.saveHistory()

                if failedCopies.isEmpty {
                    self.conversionMessage = "Created metadata copies for \(finishedCopies.count) file\(finishedCopies.count == 1 ? "" : "s"). Originals were unchanged."
                } else if finishedCopies.isEmpty {
                    self.conversionMessage = "Metadata editing failed. Originals were unchanged."
                    self.lastError = failedCopies.joined(separator: "\n\n")
                } else {
                    self.conversionMessage = "Created \(finishedCopies.count) metadata cop\(finishedCopies.count == 1 ? "y" : "ies"); \(failedCopies.count) failed. Originals were unchanged."
                    self.lastError = failedCopies.joined(separator: "\n\n")
                }
                if currentSettings.revealOutputAfterConversion, let output = finishedCopies.last?.1 {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
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

    private func requestVideoCompression() {
        let inputs = selectedFiles
        guard !inputs.isEmpty else { return }
        guard !isDiscovering else {
            conversionMessage = "Checking local video engines…"
            return
        }

        let qualityPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 210, height: 26), pullsDown: false)
        qualityPicker.addItems(withTitles: VideoCompressionQuality.allCases.map(\.displayName))
        qualityPicker.selectItem(at: VideoCompressionQuality.allCases.firstIndex(of: .balanced) ?? 0)
        qualityPicker.setAccessibilityLabel("Compression quality")
        qualityPicker.setAccessibilityIdentifier("video-compression.quality")
        let resolutionPicker = NSPopUpButton(frame: qualityPicker.frame, pullsDown: false)
        resolutionPicker.addItems(withTitles: VideoResolutionLimit.allCases.map(\.displayName))
        resolutionPicker.selectItem(at: VideoResolutionLimit.allCases.firstIndex(of: .fullHD) ?? 0)
        resolutionPicker.setAccessibilityLabel("Maximum video resolution")
        resolutionPicker.setAccessibilityIdentifier("video-compression.resolution")

        let qualityRow = NSStackView(views: [NSTextField(labelWithString: "Quality"), qualityPicker])
        qualityRow.alignment = .centerY
        qualityRow.spacing = 10
        let resolutionRow = NSStackView(views: [NSTextField(labelWithString: "Maximum resolution"), resolutionPicker])
        resolutionRow.alignment = .centerY
        resolutionRow.spacing = 10
        let controls = NSStackView(views: [qualityRow, resolutionRow])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8

        let alert = NSAlert()
        alert.messageText = inputs.count == 1 ? "Compress video" : "Compress videos"
        alert.informativeText = "Morph will re-encode the selected video\(inputs.count == 1 ? "" : "s") as H.264/AAC MP4. Quality and size can change, subtitles may be dropped, and some metadata may not carry over. The output size is reported after compression; some already-compressed files may become larger. Originals remain unchanged."
        alert.alertStyle = .informational
        alert.accessoryView = controls
        alert.addButton(withTitle: "Compress")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let qualities = VideoCompressionQuality.allCases
        let resolutions = VideoResolutionLimit.allCases
        guard qualities.indices.contains(qualityPicker.indexOfSelectedItem),
              resolutions.indices.contains(resolutionPicker.indexOfSelectedItem) else { return }
        let quality = qualities[qualityPicker.indexOfSelectedItem]
        let resolution = resolutions[resolutionPicker.indexOfSelectedItem]
        compressVideo(inputs, options: VideoCompressionOptions(quality: quality, resolutionLimit: resolution))
    }

    private func compressVideo(_ inputs: [URL], options: VideoCompressionOptions) {
        guard !inputs.isEmpty else { return }
        guard let status = registry?.status(for: .ffmpeg), status.isInstalled else {
            selectedSection = .engines
            installEngine(
                .ffmpeg,
                reason: "FFmpeg is required to compress video to H.264/AAC MP4. It also enables local audio/video conversion, trimming and audio extraction.",
                onSuccess: { [weak self] in
                    self?.selectedSection = .convert
                    self?.runVideoCompression(inputs: inputs, options: options)
                },
                onCancel: { [weak self] in self?.selectedSection = .convert }
            )
            return
        }
        guard status.supportedOutputExtensions.contains("mp4"),
              inputs.allSatisfy({ status.supportedInputExtensions.contains($0.pathExtension.lowercased()) }) else {
            lastError = "The installed FFmpeg build cannot compress every selected video to MP4."
            conversionMessage = "Video compression is unavailable for this selection."
            return
        }
        runVideoCompression(inputs: inputs, options: options)
    }

    private func runVideoCompression(inputs: [URL], options: VideoCompressionOptions) {
        guard !isConverting, !isRunningUtility, activeEngineAction == nil else { return }
        let currentSettings = settings
        let outputDirectories = inputs.map { Self.outputDirectory(for: $0, settings: currentSettings) }
        let token = CancellationToken()
        isRunningUtility = true
        isRunningUtilityCancellable = true
        utilityCancellation = token
        conversionMessage = "Preparing video compression…"
        lastError = nil

        Task.detached(priority: .userInitiated) {
            var completed: [(input: URL, output: URL)] = []
            var failures: [String] = []
            var inputBytes: Int64 = 0
            var outputBytes: Int64 = 0

            for (index, input) in inputs.enumerated() {
                if token.isCancelled { break }
                await MainActor.run {
                    self.conversionMessage = "Compressing video \(index + 1) of \(inputs.count): \(input.lastPathComponent)"
                }
                do {
                    let output = try MorphFileOperations.compressVideo(
                        input,
                        options: options,
                        outputDirectory: outputDirectories[index],
                        cancellation: token
                    )
                    let sourceSize = (try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? NSNumber)?.int64Value ?? 0
                    let outputSize = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
                    inputBytes += sourceSize
                    outputBytes += outputSize
                    completed.append((input, output))
                } catch {
                    if !token.isCancelled { failures.append("\(input.lastPathComponent): \(error.localizedDescription)") }
                }
            }

            let finishedResults = completed
            let finishedFailures = failures
            let originalTotalBytes = inputBytes
            let compressedTotalBytes = outputBytes
            await MainActor.run {
                self.isRunningUtility = false
                self.isRunningUtilityCancellable = false
                self.utilityCancellation = nil
                if !finishedResults.isEmpty {
                    self.history.insert(contentsOf: finishedResults.map {
                        HistoryItem(id: UUID(), inputName: $0.input.lastPathComponent, outputPath: $0.output.path, engineName: EngineID.ffmpeg.displayName, date: Date())
                    }, at: 0)
                    self.history = Array(self.history.prefix(200))
                    self.saveHistory()
                }
                if token.isCancelled {
                    self.conversionMessage = finishedResults.isEmpty
                        ? "Video compression cancelled. Originals were left unchanged."
                        : "Cancelled after creating \(finishedResults.count) compressed \(finishedResults.count == 1 ? "copy" : "copies"). Completed outputs remain; originals were left unchanged."
                } else if finishedFailures.isEmpty {
                    self.conversionMessage = "Created \(finishedResults.count) compressed MP4 \(finishedResults.count == 1 ? "copy" : "copies"). \(Self.videoSizeSummary(inputBytes: originalTotalBytes, outputBytes: compressedTotalBytes))"
                } else {
                    self.lastError = finishedFailures.joined(separator: "\n\n")
                    self.conversionMessage = "Created \(finishedResults.count) output\(finishedResults.count == 1 ? "" : "s"); \(finishedFailures.count) video\(finishedFailures.count == 1 ? "" : "s") failed. \(Self.videoSizeSummary(inputBytes: originalTotalBytes, outputBytes: compressedTotalBytes))"
                }
                if currentSettings.revealOutputAfterConversion, let output = finishedResults.last?.output {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            }
        }
    }

    private static func videoSizeSummary(inputBytes: Int64, outputBytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let original = formatter.string(fromByteCount: inputBytes)
        let compressed = formatter.string(fromByteCount: outputBytes)
        if outputBytes < inputBytes, inputBytes > 0 {
            let reduction = Int((1 - Double(outputBytes) / Double(inputBytes)) * 100)
            return "\(original) → \(compressed) (\(reduction)% smaller)."
        }
        if outputBytes > inputBytes { return "\(original) → \(compressed); the output is larger." }
        return "\(original) → \(compressed); file size is unchanged."
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
            let estimate = await HomebrewBottleSizeEstimator.estimate(formula: formula)
            guard let self else { return }
            let estimateText = estimate.map {
                "The current \(formula) bottle is approximately \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) to download; required dependencies are additional."
            }
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
        publishFinderSyncPreferences()
    }

    private func publishFinderSyncPreferences() {
        guard let registry else { return }
        let snapshot = FinderSyncPreferencesSnapshot(
            registry: registry,
            hiddenOutputExtensions: settings.finderHiddenOutputExtensions,
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: EngineRegistry.finderSyncPreferencesSnapshotKey)
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
