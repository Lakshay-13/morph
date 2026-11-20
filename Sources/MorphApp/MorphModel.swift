import AppKit
import Combine
import Foundation
import MorphCore
import os

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
    var stripLocationMetadata: Bool

    init(
        outputMode: OutputMode = .alongsideOriginal,
        customOutputPath: String? = nil,
        imageQuality: Double = 0.85,
        revealOutputAfterConversion: Bool = true,
        pdfCompressionPreset: PDFCompressionPreset = .balanced,
        finderHiddenOutputExtensions: Set<String> = [],
        stripLocationMetadata: Bool = true
    ) {
        self.outputMode = outputMode
        self.customOutputPath = customOutputPath
        self.imageQuality = imageQuality
        self.revealOutputAfterConversion = revealOutputAfterConversion
        self.pdfCompressionPreset = pdfCompressionPreset
        self.finderHiddenOutputExtensions = Set(finderHiddenOutputExtensions.map { $0.lowercased() })
        self.stripLocationMetadata = stripLocationMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case outputMode, customOutputPath, imageQuality, revealOutputAfterConversion, pdfCompressionPreset, finderHiddenOutputExtensions, stripLocationMetadata
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputMode = try values.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .alongsideOriginal
        customOutputPath = try values.decodeIfPresent(String.self, forKey: .customOutputPath)
        imageQuality = try values.decodeIfPresent(Double.self, forKey: .imageQuality) ?? 0.85
        revealOutputAfterConversion = try values.decodeIfPresent(Bool.self, forKey: .revealOutputAfterConversion) ?? true
        pdfCompressionPreset = try values.decodeIfPresent(PDFCompressionPreset.self, forKey: .pdfCompressionPreset) ?? .balanced
        finderHiddenOutputExtensions = Set((try values.decodeIfPresent(Set<String>.self, forKey: .finderHiddenOutputExtensions) ?? []).map { $0.lowercased() })
        stripLocationMetadata = try values.decodeIfPresent(Bool.self, forKey: .stripLocationMetadata) ?? true
    }
}

typealias HistoryItem = ConversionHistoryEntry

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
    @Published private(set) var hasError = false
    @Published private(set) var history: [HistoryItem] = []
    @Published private(set) var metadataReports: [MetadataReport] = []
    @Published var metadataSheet: MetadataSheet?
    @Published private(set) var updatesAvailable: Set<EngineID> = []
    @Published private(set) var activeEngineAction: EngineID?
    @Published private(set) var isCheckingAllEngineUpdates = false
    @Published private(set) var isUpdatingAllEngines = false
    @Published private(set) var homebrewExecutableApproved = false
    @Published private(set) var isRunningUtilityCancellable = false
    @Published var settings: MorphSettings { didSet { saveSettings() } }
    @Published var selectedSection = AppSection.overview

    private var cancellation: CancellationToken?
    private var utilityCancellation: CancellationToken?
    private var persistedHistoryIDs = Set<UUID>()
    private let logger = Logger(subsystem: "com.lakshaychawla.Morph", category: "Application")
    private let settingsKey = "com.lakshaychawla.Morph.settings"
    private let historyURL: URL

    var hasActiveWork: Bool { isConverting || isRunningUtility || activeEngineAction != nil }

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
        replaceSelectedFiles(urls)
        selectedSection = .convert
    }

    func replaceSelectedFiles(_ urls: [URL]) {
        var seenPaths = Set<String>()
        selectedFiles = urls.filter { url in
            FileManager.default.fileExists(atPath: url.path) && seenPaths.insert(url.standardizedFileURL.path).inserted
        }
        selectedOutputExtension = nil
        selectedConversionPreset = nil
        hasError = false
    }

    func appendFiles(_ urls: [URL]) {
        var seenPaths = Set(selectedFiles.map { $0.standardizedFileURL.path })
        let additions = urls.filter { url in
            FileManager.default.fileExists(atPath: url.path) && seenPaths.insert(url.standardizedFileURL.path).inserted
        }
        guard !additions.isEmpty else { return }
        selectedFiles.append(contentsOf: additions)
        selectedOutputExtension = nil
        selectedConversionPreset = nil
        hasError = false
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
            let freshRegistry = EngineRegistry.discover(forceCapabilityRefresh: true)
            let brewApproved = EngineExecutableTrust.homebrewExecutable().map(EngineExecutableTrust.isHomebrewApproved) ?? false
            await MainActor.run {
                self.registry = freshRegistry
                self.homebrewExecutableApproved = brewApproved
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
        hasError = false
        let token = CancellationToken()
        cancellation = token
        let currentSettings = settings
        let jobs = inputs.map { ($0, Self.outputDirectory(for: $0, settings: currentSettings)) }
        let outputNotice = Self.outputDirectoryNotice(for: currentSettings, inputs: inputs)

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
                    let request = ConversionRequest(
                        inputURL: input,
                        outputFormat: selectedFormat,
                        outputDirectory: job.1,
                        imageQuality: imageQuality,
                        stripLocationMetadata: currentSettings.stripLocationMetadata
                    )
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
                    self.conversionMessage = "Cancelled. Originals were left unchanged.\(outputNotice.map { " " + $0 } ?? "")"
                } else if completedFailures.isEmpty {
                    self.conversionMessage = "Finished \(completedResults.count) conversion\(completedResults.count == 1 ? "" : "s").\(outputNotice.map { " " + $0 } ?? "")"
                } else {
                    self.recordError(completedFailures.joined(separator: "\n\n"), context: "File conversion")
                    self.conversionMessage = "Finished with errors. Details were logged.\(outputNotice.map { " " + $0 } ?? "")"
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
        let outputNotice = Self.outputDirectoryNotice(for: currentSettings, inputs: inputs)
        isRunningUtility = true
        let utilityToken = CancellationToken()
        utilityCancellation = [.splitPDF, .extractZIP, .compressPDF, .compressVideo].contains(action) ? utilityToken : nil
        isRunningUtilityCancellable = [.splitPDF, .extractZIP, .compressPDF, .compressVideo].contains(action)
        conversionMessage = "Preparing \(action.rawValue.lowercased())…"
        hasError = false

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
                    outputs = try MorphFileOperations.splitPDF(inputs[0], outputDirectory: outputDirectories[0], cancellation: utilityToken)
                case .compressPDF:
                    outputs = [try MorphFileOperations.compressPDF(
                        inputs[0],
                        preset: currentSettings.pdfCompressionPreset,
                        outputDirectory: outputDirectories[0],
                        cancellation: utilityToken
                    )]
                case .extractZIP:
                    outputs = [try MorphFileOperations.extractZIP(inputs[0], outputDirectory: outputDirectories[0], cancellation: utilityToken)]
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
                    self.conversionMessage = "Created \(outputs.count) output item\(outputs.count == 1 ? "" : "s").\(outputNotice.map { " " + $0 } ?? "")"
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
                        self.hasError = false
                        switch action {
                        case .compressVideo: self.conversionMessage = "Video compression cancelled. Originals were left unchanged."
                        case .compressPDF: self.conversionMessage = "PDF compression cancelled. The original was left unchanged."
                        case .splitPDF: self.conversionMessage = "PDF splitting cancelled. The original was left unchanged."
                        case .extractZIP: self.conversionMessage = "ZIP extraction cancelled. The original was left unchanged."
                        default: self.conversionMessage = "Operation cancelled. The original was left unchanged."
                        }
                        if let outputNotice, let message = self.conversionMessage {
                            self.conversionMessage = message + " " + outputNotice
                        }
                    } else {
                        self.recordError(error.localizedDescription, context: action.rawValue)
                        self.conversionMessage = "The operation could not be completed. Details were logged.\(outputNotice.map { " " + $0 } ?? "")"
                    }
                }
            }
        }
    }

    func cancelUtility() {
        utilityCancellation?.cancel()
    }

    func cancelCancellableWorkForTermination() {
        cancellation?.cancel()
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
            recordError(error.localizedDescription, context: "Batch rename planning")
            conversionMessage = "Review the selected files and name prefix."
            return
        }

        let currentSettings = settings
        let outputNotice = Self.outputDirectoryNotice(for: currentSettings, inputs: inputs)
        let utilityToken = CancellationToken()
        utilityCancellation = utilityToken
        isRunningUtility = true
        isRunningUtilityCancellable = true
        progress = 0
        currentFileName = nil
        conversionMessage = "Preparing renamed copies…"
        hasError = false

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
                    self.conversionMessage = "Cancelled after creating \(finished.count) renamed cop\(finished.count == 1 ? "y" : "ies"). Originals were left unchanged.\(outputNotice.map { " " + $0 } ?? "")"
                } else if failed.isEmpty {
                    self.conversionMessage = "Created \(finished.count) renamed cop\(finished.count == 1 ? "y" : "ies"). Originals were left unchanged.\(outputNotice.map { " " + $0 } ?? "")"
                } else {
                    self.recordError(failed.joined(separator: "\n\n"), context: "Batch rename")
                    self.conversionMessage = "Some renamed copies could not be created. Details were logged. Originals were unchanged.\(outputNotice.map { " " + $0 } ?? "")"
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
        hasError = false
        Task.detached(priority: .userInitiated) {
            var errors: [String] = []
            let reports = inputs.map { input -> MetadataReport in
                do {
                    return MetadataReport(fileName: input.lastPathComponent, entries: try MorphFileOperations.inspectMetadata(input), error: nil)
                } catch {
                    errors.append("\(input.lastPathComponent): \(error.localizedDescription)")
                    return MetadataReport(fileName: input.lastPathComponent, entries: [], error: "Metadata could not be read. Details were logged.")
                }
            }
            let capturedErrors = errors
            let capturedReports = reports
            await MainActor.run {
                if !capturedErrors.isEmpty { self.recordError(capturedErrors.joined(separator: "\n\n"), context: "Metadata inspection") }
                self.metadataReports = capturedReports
                self.metadataSheet = .inspector
                self.isRunningUtility = false
                self.conversionMessage = capturedErrors.isEmpty
                    ? "Read metadata from \(capturedReports.count) file\(capturedReports.count == 1 ? "" : "s"). Originals were not changed."
                    : "Some metadata could not be read. Details were logged."
            }
        }
    }

    func applyMetadataEdits(_ edits: FileMetadataEdits) {
        guard quickActions.contains(.editMetadata), edits.hasChanges, !isRunningUtility else { return }
        metadataSheet = nil
        let inputs = selectedFiles
        let currentSettings = settings
        let outputDirectories = inputs.map { Self.outputDirectory(for: $0, settings: currentSettings) }
        let outputNotice = Self.outputDirectoryNotice(for: currentSettings, inputs: inputs)
        isRunningUtility = true
        isRunningUtilityCancellable = false
        conversionMessage = "Writing metadata copies…"
        hasError = false

        Task.detached(priority: .userInitiated) {
            var completed: [(URL, URL)] = []
            var failures: [String] = []
            for (input, outputDirectory) in zip(inputs, outputDirectories) {
                do {
                    let output = try MorphFileOperations.writeMetadataCopy(
                        input,
                        edits: edits,
                        outputDirectory: outputDirectory,
                        stripLocationMetadata: currentSettings.stripLocationMetadata
                    )
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
                    self.conversionMessage = "Created metadata copies for \(finishedCopies.count) file\(finishedCopies.count == 1 ? "" : "s"). Originals were unchanged.\(outputNotice.map { " " + $0 } ?? "")"
                } else if finishedCopies.isEmpty {
                    self.recordError(failedCopies.joined(separator: "\n\n"), context: "Metadata editing")
                    self.conversionMessage = "Metadata editing failed. Details were logged. Originals were unchanged.\(outputNotice.map { " " + $0 } ?? "")"
                } else {
                    self.recordError(failedCopies.joined(separator: "\n\n"), context: "Metadata editing")
                    self.conversionMessage = "Some metadata copies could not be created. Details were logged. Originals were unchanged.\(outputNotice.map { " " + $0 } ?? "")"
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
        let currentSettings = settings
        let outputDirectory = Self.outputDirectory(for: input, settings: currentSettings)
        let outputNotice = Self.outputDirectoryNotice(for: currentSettings, inputs: [input])
        isRunningUtility = true
        let utilityToken = CancellationToken()
        utilityCancellation = utilityToken
        isRunningUtilityCancellable = true
        conversionMessage = "Extracting PDF pages…"
        hasError = false

        Task.detached(priority: .userInitiated) {
            do {
                let output = try MorphFileOperations.extractPDFPages(input, pageRange: pageRange, outputDirectory: outputDirectory, cancellation: utilityToken)
                await MainActor.run {
                    self.isRunningUtility = false
                    self.utilityCancellation = nil
                    self.isRunningUtilityCancellable = false
                    self.conversionMessage = "Extracted selected PDF pages.\(outputNotice.map { " " + $0 } ?? "")"
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
                    self.utilityCancellation = nil
                    self.isRunningUtilityCancellable = false
                    if let morphError = error as? MorphError, case .cancelled = morphError {
                        self.hasError = false
                        self.conversionMessage = "PDF page extraction cancelled. The original was left unchanged.\(outputNotice.map { " " + $0 } ?? "")"
                    } else {
                        self.recordError(error.localizedDescription, context: "PDF page extraction")
                        self.conversionMessage = "PDF page extraction could not be completed. Details were logged.\(outputNotice.map { " " + $0 } ?? "")"
                    }
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
        guard status.canConvert else {
            recordError(status.securityNotice ?? "Morph could not verify the installed FFmpeg version.", context: "Video compression security check")
            conversionMessage = "Video compression is paused for an engine security update."
            return
        }
        guard status.supportedOutputExtensions.contains("mp4"),
              inputs.allSatisfy({ status.supportedInputExtensions.contains($0.pathExtension.lowercased()) }) else {
            recordError("The installed FFmpeg build cannot compress every selected video to MP4.", context: "Video compression capability check")
            conversionMessage = "Video compression is unavailable for this selection."
            return
        }
        runVideoCompression(inputs: inputs, options: options)
    }

    private func runVideoCompression(inputs: [URL], options: VideoCompressionOptions) {
        guard !isConverting, !isRunningUtility, activeEngineAction == nil else { return }
        let currentSettings = settings
        let outputDirectories = inputs.map { Self.outputDirectory(for: $0, settings: currentSettings) }
        let outputNotice = Self.outputDirectoryNotice(for: currentSettings, inputs: inputs)
        let token = CancellationToken()
        isRunningUtility = true
        isRunningUtilityCancellable = true
        utilityCancellation = token
        conversionMessage = "Preparing video compression…"
        hasError = false

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
                        cancellation: token,
                        stripLocationMetadata: currentSettings.stripLocationMetadata
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
                        ? "Video compression cancelled. Originals were left unchanged.\(outputNotice.map { " " + $0 } ?? "")"
                        : "Cancelled after creating \(finishedResults.count) compressed \(finishedResults.count == 1 ? "copy" : "copies"). Completed outputs remain; originals were left unchanged.\(outputNotice.map { " " + $0 } ?? "")"
                } else if finishedFailures.isEmpty {
                    self.conversionMessage = "Created \(finishedResults.count) compressed MP4 \(finishedResults.count == 1 ? "copy" : "copies"). \(Self.videoSizeSummary(inputBytes: originalTotalBytes, outputBytes: compressedTotalBytes))\(outputNotice.map { " " + $0 } ?? "")"
                } else {
                    self.recordError(finishedFailures.joined(separator: "\n\n"), context: "Video compression")
                    self.conversionMessage = "Some videos could not be compressed. Details were logged. \(Self.videoSizeSummary(inputBytes: originalTotalBytes, outputBytes: compressedTotalBytes))\(outputNotice.map { " " + $0 } ?? "")"
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
            recordError(error.localizedDescription, context: "Video trim input")
            conversionMessage = "Video trimming could not be prepared. Details were logged."
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
        guard status.canConvert else {
            recordError(status.securityNotice ?? "Morph could not verify the installed FFmpeg version.", context: "Video trimming security check")
            conversionMessage = "Video trimming is paused for an engine security update."
            return
        }
        guard status.supportedInputExtensions.contains(input.pathExtension.lowercased()),
              status.supportedOutputExtensions.contains("mp4") else {
            recordError("The installed FFmpeg build cannot trim this input to MP4.", context: "Video trimming capability check")
            conversionMessage = "Video trimming is unavailable for this format."
            return
        }
        runVideoTrim(input: input, range: range)
    }

    private func runVideoTrim(input: URL, range: (startSeconds: Double, durationSeconds: Double)) {
        guard !isConverting, !isRunningUtility, activeEngineAction == nil else { return }
        let currentSettings = settings
        let outputDirectory = Self.outputDirectory(for: input, settings: currentSettings)
        let outputNotice = Self.outputDirectoryNotice(for: currentSettings, inputs: [input])
        let start = range.startSeconds
        let end = start + range.durationSeconds
        isRunningUtility = true
        isRunningUtilityCancellable = true
        conversionMessage = "Trimming video…"
        hasError = false
        let token = CancellationToken()
        utilityCancellation = token

        Task.detached(priority: .userInitiated) {
            do {
                let output = try MorphFileOperations.trimVideo(
                    input,
                    startSeconds: start,
                    endSeconds: end,
                    outputDirectory: outputDirectory,
                    cancellation: token,
                    stripLocationMetadata: currentSettings.stripLocationMetadata
                )
                await MainActor.run {
                    self.isRunningUtility = false
                    self.isRunningUtilityCancellable = false
                    self.utilityCancellation = nil
                    self.conversionMessage = "Created a trimmed MP4 copy.\(outputNotice.map { " " + $0 } ?? "")"
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
                        self.hasError = false
                        self.conversionMessage = "Video trimming cancelled. The original was left unchanged.\(outputNotice.map { " " + $0 } ?? "")"
                    } else {
                        self.recordError(error.localizedDescription, context: "Video trimming")
                        self.conversionMessage = "Video trimming could not be completed. Details were logged.\(outputNotice.map { " " + $0 } ?? "")"
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
        guard let package = id.homebrewPackageName,
              let actionArguments = id.homebrewArguments(action: "install"),
              activeEngineAction == nil, !isConverting, !isRunningUtility else { return }
        guard guardEngineApprovalStorage(context: "Engine installation") else { return }
        activeEngineAction = id
        hasError = false
        conversionMessage = "Waiting for install confirmation…"
        let reasonText = reason.map { "\($0)\n\n" } ?? ""
        let packageKind = id.homebrewPackageFlag == "--cask" ? "cask" : "formula"
        confirmEngineAction(
            id: id,
            action: "Install",
            message: "\(reasonText)Morph will ask Homebrew to install the ‘\(package)’ \(packageKind) and any required dependencies. Homebrew verifies package checksums and resolves the download size when the install starts. Morph does not request bottle metadata or download an engine before you confirm here.",
            cancelled: {
                self.finishEngineAction(id)
                self.conversionMessage = "Install cancelled. No output was created."
                onCancel?()
            }
        ) {
            self.runHomebrew(engine: id, arguments: actionArguments, successMessage: "\(id.displayName) installed.", onSuccess: onSuccess)
        }
    }

    func uninstallEngine(_ id: EngineID) {
        guard let package = id.homebrewPackageName,
              let actionArguments = id.homebrewArguments(action: "uninstall"),
              activeEngineAction == nil, !isConverting, !isRunningUtility else { return }
        guard guardEngineApprovalStorage(context: "Engine uninstall") else { return }
        activeEngineAction = id
        hasError = false
        let packageKind = id.homebrewPackageFlag == "--cask" ? "cask" : "formula"
        confirmEngineAction(id: id, action: "Uninstall", message: "Homebrew will remove the ‘\(package)’ \(packageKind). Other packages and shared dependencies are left in place.", cancelled: { [weak self] in
            self?.finishEngineAction(id)
        }) { [weak self] in
            self?.runHomebrew(engine: id, arguments: actionArguments, successMessage: "\(id.displayName) uninstalled.")
        }
    }

    func checkForUpdates(_ id: EngineID) {
        guard activeEngineAction == nil, !isConverting, !isRunningUtility else { return }
        guard guardEngineApprovalStorage(context: "Engine update check") else { return }
        guard let actionArguments = id.homebrewArguments(action: "outdated") else { return }
        guard let brew = EngineExecutableTrust.homebrewExecutable() else {
            recordError("Homebrew executable was not found.", context: "Engine update check")
            conversionMessage = "Homebrew is unavailable. Details were logged."
            return
        }
        guard EngineExecutableTrust.isHomebrewApproved(brew) else {
            requestExecutableTrustApproval(
                displayName: "Homebrew",
                identifier: "homebrew",
                executables: [brew],
                onApproved: { self.checkForUpdates(id) },
                onCancel: { self.conversionMessage = "Homebrew review cancelled. No package action was run." }
            )
            return
        }
        guard confirmHomebrewMetadataRefresh() else {
            conversionMessage = "Update check cancelled. Homebrew was not contacted."
            return
        }
        activeEngineAction = id
        hasError = false
        conversionMessage = "Checking \(id.displayName) for updates…"
        Task.detached(priority: .utility) {
            do {
                guard EngineExecutableTrust.isHomebrewApproved(brew) else {
                    throw MorphError.processFailed("The Homebrew executable changed after approval. Review it again before use.")
                }
                let refresh = try ProcessRunner.run(
                    executable: brew,
                    arguments: EngineID.homebrewMetadataRefreshArguments,
                    timeout: 10 * 60,
                    environmentOverrides: HomebrewProcessEnvironment.overrides()
                )
                guard refresh.status == 0, !refresh.stdoutWasTruncated, !refresh.stderrWasTruncated else {
                    let output = [refresh.stdout, refresh.stderr]
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .joined(separator: "\n")
                    throw MorphError.processFailed("Homebrew could not refresh package metadata (status \(refresh.status)). \(output)")
                }
                let result = try ProcessRunner.run(
                    executable: brew,
                    arguments: actionArguments,
                    environmentOverrides: HomebrewProcessEnvironment.overrides()
                )
                guard !result.stdoutWasTruncated, !result.stderrWasTruncated else {
                    throw MorphError.processFailed("Homebrew output exceeded Morph's diagnostic limit.")
                }
                let outdated = try id.isHomebrewPackageOutdated(
                    exitStatus: result.status,
                    standardOutput: result.stdout,
                    standardError: result.stderr
                )
                await MainActor.run {
                    if outdated { self.updatesAvailable.insert(id) } else { self.updatesAvailable.remove(id) }
                    self.conversionMessage = outdated ? "An update is available for \(id.displayName)." : "\(id.displayName) is up to date."
                    self.hasError = false
                    self.finishEngineAction(id)
                }
            } catch {
                await MainActor.run {
                    self.recordError(error.localizedDescription, context: "Update check for \(id.displayName)")
                    self.conversionMessage = "Could not check for updates. Details were logged."
                    self.finishEngineAction(id)
                }
            }
        }
    }

    func updateAllEngines(_ managedEngines: [EngineID]) {
        guard activeEngineAction == nil, !isConverting, !isRunningUtility, !isDiscovering else { return }
        guard guardEngineApprovalStorage(context: "Update All") else { return }
        var seen = Set<EngineID>()
        let installedEngines = managedEngines.filter { id in
            seen.insert(id).inserted && id.homebrewPackageName != nil && registry?.status(for: id)?.isInstalled == true
        }
        guard let actionID = installedEngines.first else {
            conversionMessage = "No optional Morph engines are installed."
            hasError = false
            return
        }
        guard let brew = EngineExecutableTrust.homebrewExecutable() else {
            recordError("Homebrew executable was not found.", context: "Update All")
            conversionMessage = "Homebrew is unavailable. Details were logged."
            return
        }
        guard EngineExecutableTrust.isHomebrewApproved(brew) else {
            requestExecutableTrustApproval(
                displayName: "Homebrew",
                identifier: "homebrew",
                executables: [brew],
                onApproved: { self.updateAllEngines(managedEngines) },
                onCancel: { self.conversionMessage = "Homebrew review cancelled. No packages were checked or changed." }
            )
            return
        }

        guard confirmHomebrewMetadataRefresh() else {
            conversionMessage = "Update check cancelled. Homebrew was not contacted."
            return
        }

        activeEngineAction = actionID
        isCheckingAllEngineUpdates = true
        updatesAvailable.removeAll()
        hasError = false
        conversionMessage = "Checking installed engines for updates…"

        Task.detached(priority: .utility) {
            var outdated: [EngineID] = []
            var failures: [String] = []
            do {
                guard EngineExecutableTrust.isHomebrewApproved(brew) else {
                    throw MorphError.processFailed("The Homebrew executable changed after approval. Review it again before use.")
                }
                let refresh = try ProcessRunner.run(
                    executable: brew,
                    arguments: EngineID.homebrewMetadataRefreshArguments,
                    timeout: 10 * 60,
                    environmentOverrides: HomebrewProcessEnvironment.overrides()
                )
                guard refresh.status == 0, !refresh.stdoutWasTruncated, !refresh.stderrWasTruncated else {
                    let output = [refresh.stdout, refresh.stderr]
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .joined(separator: "\n")
                    throw MorphError.processFailed("Homebrew could not refresh package metadata (status \(refresh.status)). \(output)")
                }
            } catch {
                await MainActor.run {
                    self.isCheckingAllEngineUpdates = false
                    self.recordError(error.localizedDescription, context: "Update All metadata refresh")
                    self.conversionMessage = "Could not refresh Homebrew metadata. Details were logged. No engine upgrades were started."
                    self.finishEngineAction(actionID)
                }
                return
            }

            for id in installedEngines {
                guard let arguments = id.homebrewArguments(action: "outdated") else { continue }
                do {
                    guard EngineExecutableTrust.isHomebrewApproved(brew) else {
                        throw MorphError.processFailed("The Homebrew executable changed after approval. Review it again before use.")
                    }
                    let result = try ProcessRunner.run(
                        executable: brew,
                        arguments: arguments,
                        environmentOverrides: HomebrewProcessEnvironment.overrides()
                    )
                    guard !result.stdoutWasTruncated, !result.stderrWasTruncated else {
                        throw MorphError.processFailed("Homebrew output exceeded Morph's diagnostic limit.")
                    }
                    if try id.isHomebrewPackageOutdated(
                        exitStatus: result.status,
                        standardOutput: result.stdout,
                        standardError: result.stderr
                    ) {
                        outdated.append(id)
                    }
                } catch {
                    failures.append("\(id.displayName): \(error.localizedDescription)")
                }
            }

            let checkedOutdated = outdated
            let checkFailures = failures
            await MainActor.run {
                self.isCheckingAllEngineUpdates = false
                self.updatesAvailable = Set(checkedOutdated)
                if checkedOutdated.isEmpty {
                    self.finishEngineAction(actionID)
                    if checkFailures.isEmpty {
                        self.hasError = false
                        self.conversionMessage = "All installed Morph engines are up to date."
                    } else {
                        self.recordError(checkFailures.joined(separator: "\n\n"), context: "Update All checks")
                        self.conversionMessage = "Some engines could not be checked. Details were logged."
                    }
                    return
                }
                self.confirmUpdateAllEngines(
                    checkedOutdated,
                    checkFailures: checkFailures,
                    actionID: actionID,
                    brew: brew
                )
            }
        }
    }

    func updateEngine(_ id: EngineID) {
        guard let package = id.homebrewPackageName,
              let actionArguments = id.homebrewArguments(action: "upgrade"),
              activeEngineAction == nil, !isConverting, !isRunningUtility else { return }
        guard guardEngineApprovalStorage(context: "Engine update") else { return }
        activeEngineAction = id
        hasError = false
        let packageKind = id.homebrewPackageFlag == "--cask" ? "cask" : "formula"
        confirmEngineAction(id: id, action: "Update", message: "Homebrew will upgrade the ‘\(package)’ \(packageKind) and may download dependencies. No update starts until you confirm here.", cancelled: { [weak self] in
            self?.finishEngineAction(id)
            self?.conversionMessage = "Update cancelled. No package was changed."
        }) { [weak self] in
            self?.runHomebrew(engine: id, arguments: actionArguments, successMessage: "\(id.displayName) updated.")
        }
    }

    func approveEngineExecutable(_ id: EngineID) {
        guard activeEngineAction == nil, !isConverting, !isRunningUtility else { return }
        guard guardEngineApprovalStorage(context: "Engine approval") else { return }
        let executables = EngineExecutableTrust.requiredExecutables(for: id)
        guard !executables.isEmpty else {
            recordError("No executable for \(id.displayName) was found to review.", context: "Engine approval")
            conversionMessage = "The engine executable could not be found. Details were logged."
            return
        }
        activeEngineAction = id
        requestExecutableTrustApproval(
            displayName: id.displayName,
            identifier: id.rawValue,
            executables: executables,
            onApproved: {
                self.refreshEngines { self.finishEngineAction(id) }
            },
            onCancel: {
                self.finishEngineAction(id)
                self.conversionMessage = "Executable review cancelled. Morph did not run the engine."
            }
        )
    }

    func revokeEngineExecutableApproval(_ id: EngineID) {
        for executable in EngineExecutableTrust.requiredExecutables(for: id) {
            EngineExecutableTrust.revoke(executable, identifier: id.rawValue)
        }
        refreshEngines()
        conversionMessage = "Approval revoked for \(id.displayName). Morph will not run it until you review it again."
    }

    func approveHomebrewExecutable() {
        guard guardEngineApprovalStorage(context: "Homebrew approval") else { return }
        guard let brew = EngineExecutableTrust.homebrewExecutable() else {
            recordError("Homebrew executable was not found.", context: "Homebrew approval")
            conversionMessage = "Homebrew is unavailable. Details were logged."
            return
        }
        requestExecutableTrustApproval(
            displayName: "Homebrew",
            identifier: "homebrew",
            executables: [brew],
            onApproved: {
                self.homebrewExecutableApproved = true
                self.conversionMessage = "Homebrew is approved for explicit package actions."
            },
            onCancel: { self.conversionMessage = "Homebrew review cancelled. No package action was run." }
        )
    }

    func revokeHomebrewExecutableApproval() {
        guard let brew = EngineExecutableTrust.homebrewExecutable() else { return }
        EngineExecutableTrust.revokeHomebrew(brew)
        homebrewExecutableApproved = false
        conversionMessage = "Homebrew approval revoked. Morph will request review before running it again."
    }

    private func confirmUpdateAllEngines(
        _ engines: [EngineID],
        checkFailures: [String],
        actionID: EngineID,
        brew: URL
    ) {
        let batches = EngineID.homebrewUpgradeBatches(for: engines)
        guard !batches.isEmpty else {
            finishEngineAction(actionID)
            conversionMessage = "No engine updates were found."
            return
        }

        let packageList = engines.compactMap { id -> String? in
            guard let package = id.homebrewPackageName else { return nil }
            let kind = id.homebrewPackageFlag == "--cask" ? "cask" : "formula"
            return "• \(id.displayName) — \(package) (\(kind))"
        }.joined(separator: "\n")
        let partialCheckNotice = checkFailures.isEmpty
            ? ""
            : "\n\nMorph could not check \(checkFailures.count) other engine\(checkFailures.count == 1 ? "" : "s"); those will be skipped. Details will be logged."

        let alert = NSAlert()
        alert.messageText = "Update all available Morph engines?"
        alert.informativeText = "Updates are available for:\n\n\(packageList)\n\nHomebrew may also upgrade dependencies and outdated dependents, close an updated application, and clean up older package versions. Morph will update only the listed packages, and only after you approve here.\(partialCheckNotice)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            runHomebrewUpgradeBatches(batches, engines: engines, actionID: actionID, brew: brew, checkFailures: checkFailures)
        } else {
            finishEngineAction(actionID)
            if !checkFailures.isEmpty {
                recordError(checkFailures.joined(separator: "\n\n"), context: "Update All checks")
            }
            conversionMessage = "Update cancelled. No packages were changed."
        }
    }

    private func confirmHomebrewMetadataRefresh() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Refresh Homebrew package metadata?"
        alert.informativeText = "Morph will contact Homebrew and refresh its package metadata before checking installed engines. This downloads metadata only; a separate confirmation is required before Morph upgrades any engine."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Refresh Metadata")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func runHomebrewUpgradeBatches(
        _ batches: [[String]],
        engines: [EngineID],
        actionID: EngineID,
        brew: URL,
        checkFailures: [String]
    ) {
        isUpdatingAllEngines = true
        Task.detached(priority: .utility) {
            var updated = Set<EngineID>()
            var failed = Set<EngineID>()
            var failures: [String] = []

            for arguments in batches {
                guard let flag = arguments.first(where: { $0 == "--formula" || $0 == "--cask" }) else { continue }
                let packageNames = Set(arguments.drop(while: { $0 != flag }).dropFirst())
                let batchEngines = engines.filter {
                    $0.homebrewPackageFlag == flag && packageNames.contains($0.homebrewPackageName ?? "")
                }
                await MainActor.run {
                    self.conversionMessage = "Updating \(batchEngines.map(\.displayName).joined(separator: ", "))…"
                }

                do {
                    guard EngineExecutableTrust.isHomebrewApproved(brew) else {
                        throw MorphError.processFailed("The Homebrew executable changed after approval. Review it again before use.")
                    }
                    let result = try ProcessRunner.run(
                        executable: brew,
                        arguments: arguments,
                        environmentOverrides: HomebrewProcessEnvironment.overrides()
                    )
                    guard result.status == 0 else {
                        let output = [result.stdout, result.stderr]
                            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                            .joined(separator: "\n")
                        throw MorphError.processFailed("Homebrew exited with status \(result.status). \(output)")
                    }
                    updated.formUnion(batchEngines)
                } catch {
                    failed.formUnion(batchEngines)
                    failures.append("\(batchEngines.map(\.displayName).joined(separator: ", ")): \(error.localizedDescription)")
                }
            }

            let completedUpdates = updated
            let failedUpdates = failed
            let updateFailures = failures
            await MainActor.run {
                self.isUpdatingAllEngines = false
                self.updatesAvailable = failedUpdates
                if !updateFailures.isEmpty {
                    self.recordError(updateFailures.joined(separator: "\n\n"), context: "Update All")
                }
                if !checkFailures.isEmpty {
                    self.recordError(checkFailures.joined(separator: "\n\n"), context: "Update All checks")
                }

                if updateFailures.isEmpty {
                    self.conversionMessage = "Updated \(completedUpdates.count) engine\(completedUpdates.count == 1 ? "" : "s")."
                } else if completedUpdates.isEmpty {
                    self.conversionMessage = "Engine updates could not be completed. Details were logged."
                } else {
                    self.conversionMessage = "Updated \(completedUpdates.count) engine\(completedUpdates.count == 1 ? "" : "s"); some updates failed. Details were logged."
                }
                self.refreshEngines {
                    self.finishEngineAction(actionID)
                }
            }
        }
    }

    func chooseCustomOutputFolder() {
        guard guardEngineApprovalStorage(context: "Custom output folder") else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Morph output folder"
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try EngineExecutableTrust.setProtectedOutputDirectory(url)
                settings.customOutputPath = url.resolvingSymlinksInPath().standardizedFileURL.path
                settings.outputMode = .custom
            } catch {
                recordError(error.localizedDescription, context: "Custom output folder approval")
                conversionMessage = "Morph could not protect that output folder. Choose another folder."
            }
        }
    }

    func showOutput(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func confirmEngineAction(id: EngineID, action: String, message: String, cancelled: @escaping () -> Void, confirmed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(action) \(id.displayName)?"
        alert.informativeText = "\(message)\n\nMorph requests that Homebrew skip analytics and automatic self-updates, and passes configured proxy settings. Homebrew may also load brew.env from system, prefix and user configuration locations; those files can override Morph's settings or supply Cask options. Check your Homebrew configuration before confirming."
        alert.alertStyle = .informational
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { confirmed() }
        else { cancelled() }
    }

    private func requestExecutableTrustApproval(
        displayName: String,
        identifier: String,
        executables: [URL],
        onApproved: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard guardEngineApprovalStorage(context: "Executable approval") else {
            onCancel()
            return
        }
        Task.detached(priority: .utility) {
            do {
                let reviewed = try executables.map {
                    ($0, try EngineExecutableTrust.fingerprint(for: $0), try EngineExecutableTrust.ownerSummary(for: $0))
                }
                await MainActor.run {
                    let paths = reviewed.map { "• \($0.0.path)\n  Owner: \($0.2)\n  SHA-256: \($0.1)" }.joined(separator: "\n")
                    let alert = NSAlert()
                    alert.messageText = "Approve \(displayName) executable?"
                    alert.informativeText = "Morph will allow this locally installed executable to run during conversions. It will be re-checked against this SHA-256 digest before use; an update or replacement needs review again.\n\n\(paths)"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Approve Executable")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else {
                        onCancel()
                        return
                    }
                    Task.detached(priority: .utility) {
                        do {
                            for (executable, fingerprint, _) in reviewed {
                                _ = try EngineExecutableTrust.approve(
                                    executable,
                                    identifier: identifier,
                                    expectedFingerprint: fingerprint
                                )
                            }
                            await MainActor.run { onApproved() }
                        } catch {
                            await MainActor.run {
                                self.recordError(error.localizedDescription, context: "Executable approval for \(displayName)")
                                self.conversionMessage = "Executable approval could not be saved. Details were logged."
                                onCancel()
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.recordError(error.localizedDescription, context: "Executable review for \(displayName)")
                    self.conversionMessage = "Morph could not verify the executable. Details were logged."
                    onCancel()
                }
            }
        }
    }

    private func runHomebrew(engine id: EngineID, arguments: [String], successMessage: String, refreshAfter: Bool = true, onSuccess: (() -> Void)? = nil) {
        guard EngineExecutableTrust.canStorePersistentApprovals else {
            finishEngineAction(id)
            conversionMessage = EngineExecutableTrust.approvalStorageUnavailableReason
            hasError = false
            return
        }
        guard let brew = EngineExecutableTrust.homebrewExecutable() else {
            finishEngineAction(id)
            recordError("Homebrew executable was not found.", context: "Homebrew package action")
            conversionMessage = "Homebrew is unavailable. Details were logged."
            return
        }
        guard EngineExecutableTrust.isHomebrewApproved(brew) else {
            requestExecutableTrustApproval(
                displayName: "Homebrew",
                identifier: "homebrew",
                executables: [brew],
                onApproved: { self.runHomebrew(engine: id, arguments: arguments, successMessage: successMessage, refreshAfter: refreshAfter, onSuccess: onSuccess) },
                onCancel: { self.finishEngineAction(id) }
            )
            return
        }
        conversionMessage = "Running Homebrew…"
        Task.detached(priority: .utility) {
            do {
                guard EngineExecutableTrust.isHomebrewApproved(brew) else {
                    throw MorphError.processFailed("The Homebrew executable changed after approval. Review it again before use.")
                }
                let result = try ProcessRunner.run(
                    executable: brew,
                    arguments: arguments,
                    environmentOverrides: HomebrewProcessEnvironment.overrides()
                )
                guard result.status == 0 else {
                    let output = [result.stdout, result.stderr]
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .joined(separator: "\n")
                    throw MorphError.processFailed("Homebrew exited with status \(result.status). \(output)")
                }
                await MainActor.run {
                    self.conversionMessage = successMessage
                    self.hasError = false
                    if arguments.first == "install" || arguments.first == "upgrade" { self.updatesAvailable.remove(id) }
                    if refreshAfter {
                        self.refreshEngines {
                            self.finishEngineAction(id)
                            if let onSuccess {
                                self.approveInstalledEngineAndRetry(id, onApproved: onSuccess)
                            }
                        }
                    } else {
                        self.finishEngineAction(id)
                        onSuccess?()
                    }
                }
            } catch {
                await MainActor.run {
                    self.finishEngineAction(id)
                    self.recordError(error.localizedDescription, context: "Homebrew action for \(id.displayName)")
                    self.conversionMessage = "Homebrew could not complete this action. Details were logged."
                }
            }
        }
    }

    private func approveInstalledEngineAndRetry(_ id: EngineID, onApproved: @escaping () -> Void) {
        guard let status = registry?.status(for: id), status.isInstalled else {
            conversionMessage = "The engine was installed, but Morph could not verify it. No conversion was run."
            return
        }
        guard status.requiresApproval else {
            guard status.canConvert else {
                recordError(status.securityNotice ?? status.availabilityNotice ?? "Morph could not verify the installed engine.", context: "Post-install conversion retry")
                conversionMessage = "The engine is installed but unavailable. Details were logged; no conversion was run."
                return
            }
            onApproved()
            return
        }

        let executables = EngineExecutableTrust.requiredExecutables(for: id)
        guard !executables.isEmpty else {
            recordError("The installed executable for \(id.displayName) could not be found.", context: "Post-install executable review")
            conversionMessage = "Morph could not review the new engine. No conversion was run."
            return
        }
        activeEngineAction = id
        requestExecutableTrustApproval(
            displayName: id.displayName,
            identifier: id.rawValue,
            executables: executables,
            onApproved: {
                self.refreshEngines {
                    self.finishEngineAction(id)
                    guard let refreshed = self.registry?.status(for: id), refreshed.canConvert else {
                        self.recordError(
                            self.registry?.status(for: id)?.securityNotice
                                ?? self.registry?.status(for: id)?.availabilityNotice
                                ?? "Morph could not verify the installed engine after approval.",
                            context: "Post-install conversion retry"
                        )
                        self.conversionMessage = "The engine could not be enabled safely. No conversion was run."
                        return
                    }
                    onApproved()
                }
            },
            onCancel: {
                self.finishEngineAction(id)
                self.conversionMessage = "Engine approval cancelled. The engine remains installed, and no conversion was run."
            }
        )
    }

    @discardableResult
    private func guardEngineApprovalStorage(context: String) -> Bool {
        guard let reason = EngineExecutableTrust.approvalStorageUnavailableReason else { return true }
        recordError(reason, context: context)
        conversionMessage = reason
        hasError = false
        return false
    }

    private func recordError(_ detail: String, context: String) {
        hasError = true
        logger.error("\(context, privacy: .public): \(detail, privacy: .private)")
    }

    private func finishEngineAction(_ id: EngineID) {
        if activeEngineAction == id { activeEngineAction = nil }
    }

    private static func outputDirectory(for input: URL, settings: MorphSettings) -> URL {
        let fallback = morphOutputDirectory()
        let candidate: URL
        switch settings.outputMode {
        case .alongsideOriginal:
            candidate = input.deletingLastPathComponent()
        case .morphFolder:
            candidate = fallback
        case .custom:
            if let path = settings.customOutputPath {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                candidate = EngineExecutableTrust.protectedOutputDirectoryMatches(directory) ? directory : fallback
            } else {
                candidate = fallback
            }
        }
        try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        guard OutputDirectoryPolicy.canSafelyStage(in: candidate) else {
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        }
        return candidate
    }

    private static func morphOutputDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Morph Output", isDirectory: true)
    }

    private static func outputDirectoryNotice(for settings: MorphSettings, inputs: [URL]) -> String? {
        if settings.outputMode == .custom {
            guard let path = settings.customOutputPath,
                  EngineExecutableTrust.protectedOutputDirectoryMatches(URL(fileURLWithPath: path, isDirectory: true)) else {
                return "The saved custom folder could not be verified; Morph saved to Documents/Morph Output. Choose the folder again in Settings."
            }
        }
        let fallbackPath = morphOutputDirectory().standardizedFileURL.path
        let usesUnsafeDestination = inputs.contains { input in
            let candidate: URL
            switch settings.outputMode {
            case .alongsideOriginal:
                candidate = input.deletingLastPathComponent()
            case .morphFolder:
                candidate = morphOutputDirectory()
            case .custom:
                guard let path = settings.customOutputPath, !path.isEmpty else { return false }
                candidate = URL(fileURLWithPath: path, isDirectory: true)
            }
            return candidate.standardizedFileURL.path != fallbackPath
                && !OutputDirectoryPolicy.canSafelyStage(in: candidate)
        }
        guard usesUnsafeDestination else { return nil }
        return "Morph could not safely use the selected output folder, so it saved to Documents/Morph Output."
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
        if let loaded = try? ConversionHistoryStore.load(from: historyURL) {
            history = loaded
            persistedHistoryIDs = Set(loaded.map(\.id))
        }
    }

    private func saveHistory() {
        let additions = history.filter { !persistedHistoryIDs.contains($0.id) }
        guard !additions.isEmpty else { return }
        if let merged = try? ConversionHistoryStore.merge(additions, into: historyURL) {
            history = merged
            persistedHistoryIDs = Set(merged.map(\.id))
        }
    }

    func refreshHistory() {
        loadHistory()
    }

    func clearHistory() {
        do {
            try ConversionHistoryStore.clear(from: historyURL)
            history = []
            persistedHistoryIDs = []
            conversionMessage = "Conversion history was cleared. Output files were not changed."
            hasError = false
        } catch {
            recordError(error.localizedDescription, context: "Clear conversion history")
            conversionMessage = "History could not be cleared. Details were logged."
        }
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
