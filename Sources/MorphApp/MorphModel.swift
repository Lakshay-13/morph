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
    case resizeImages = "Resize images to 50%"
    case mergePDFs = "Merge selected PDFs"
    case splitPDF = "Split PDF into pages"
    case extractZIP = "Extract ZIP archive"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .resizeImages: "arrow.down.right.and.arrow.up.left"
        case .mergePDFs: "doc.on.doc"
        case .splitPDF: "square.split.2x1"
        case .extractZIP: "archivebox"
        }
    }
}

struct MorphSettings: Codable, Sendable {
    var outputMode: OutputMode = .alongsideOriginal
    var customOutputPath: String?
    var imageQuality: Double = 0.85
    var revealOutputAfterConversion = true
}

struct HistoryItem: Codable, Identifiable, Sendable {
    let id: UUID
    let inputName: String
    let outputPath: String
    let engineName: String
    let date: Date
}

@MainActor
final class MorphModel: ObservableObject {
    static let shared = MorphModel()

    @Published private(set) var registry: EngineRegistry?
    @Published private(set) var isDiscovering = true
    @Published var selectedFiles: [URL] = []
    @Published var selectedOutputExtension: String?
    @Published private(set) var isConverting = false
    @Published private(set) var isRunningUtility = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentFileName: String?
    @Published private(set) var conversionMessage: String?
    @Published private(set) var lastError: String?
    @Published private(set) var history: [HistoryItem] = []
    @Published private(set) var updatesAvailable: Set<EngineID> = []
    @Published var settings: MorphSettings { didSet { saveSettings() } }
    @Published var selectedSection = AppSection.overview

    private var cancellation: CancellationToken?
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

    var availableRouteCount: Int { registry?.routes.count ?? 0 }
    var activeEngineCount: Int {
        let routeEngines = Set(registry?.routes.map(\.engine) ?? [])
        return routeEngines.union([.nativeImage, .nativePDF, .structuredData, .archive]).count
    }

    var quickActions: [QuickAction] {
        guard !selectedFiles.isEmpty else { return [] }
        let extensions = selectedFiles.map { $0.pathExtension.lowercased() }
        var actions: [QuickAction] = []
        if extensions.allSatisfy({ ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp"].contains($0) }) {
            actions.append(.resizeImages)
        }
        if extensions.count >= 2 && extensions.allSatisfy({ $0 == "pdf" }) { actions.append(.mergePDFs) }
        if extensions.count == 1, extensions[0] == "pdf" { actions.append(.splitPDF) }
        if extensions.count == 1, extensions[0] == "zip" { actions.append(.extractZIP) }
        return actions
    }

    func importFiles(_ urls: [URL]) {
        selectedFiles = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        selectedOutputExtension = nil
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
        if selectedFiles.isEmpty { selectedOutputExtension = nil }
    }

    func clearSelection() {
        selectedFiles = []
        selectedOutputExtension = nil
        selectedSection = .overview
    }

    func refreshEngines() {
        isDiscovering = true
        Task.detached(priority: .utility) {
            let freshRegistry = EngineRegistry.discover()
            await MainActor.run {
                self.registry = freshRegistry
                self.isDiscovering = false
            }
        }
    }

    func startConversion(to format: MorphFormat) {
        guard let registry, !isConverting else { return }
        let inputs = selectedFiles
        guard !inputs.isEmpty else { return }
        selectedOutputExtension = format.fileExtension
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
                    let request = ConversionRequest(inputURL: input, outputFormat: selectedFormat, outputDirectory: job.1, imageQuality: currentSettings.imageQuality)
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
        guard quickActions.contains(action), !isConverting, !isRunningUtility else { return }
        let inputs = selectedFiles
        let currentSettings = settings
        let outputDirectories = inputs.map { Self.outputDirectory(for: $0, settings: currentSettings) }
        isRunningUtility = true
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
                case .extractZIP:
                    outputs = [try MorphFileOperations.extractZIP(inputs[0], outputDirectory: outputDirectories[0])]
                }
                await MainActor.run {
                    self.isRunningUtility = false
                    self.conversionMessage = "Created \(outputs.count) output item\(outputs.count == 1 ? "" : "s")."
                    self.history.insert(contentsOf: outputs.map {
                        HistoryItem(id: UUID(), inputName: inputs[0].lastPathComponent, outputPath: $0.path, engineName: action == .resizeImages ? EngineID.nativeImage.displayName : (action == .extractZIP ? EngineID.archive.displayName : EngineID.nativePDF.displayName), date: Date())
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
                    self.lastError = error.localizedDescription
                    self.conversionMessage = "The operation could not be completed."
                }
            }
        }
    }

    func installEngine(_ id: EngineID) {
        guard let formula = id.homebrewFormula else { return }
        Task {
            let estimate = await Self.estimatedBottleSize(formula: formula)
            let estimateText = estimate.map { "The current \(formula) bottle is approximately \($0) to download; required dependencies are additional." }
                ?? "A bottle size estimate is unavailable. Homebrew will resolve the formula and dependency download sizes after confirmation."
            confirmEngineAction(id: id, action: "Install", message: "Morph will ask Homebrew to install the ‘\(formula)’ formula and any required dependencies. Homebrew verifies package checksums. \(estimateText) No engine is downloaded until you confirm here.") { [weak self] in
                self?.runHomebrew(arguments: ["install", "--formula", formula], successMessage: "\(id.displayName) installed.")
            }
        }
    }

    func uninstallEngine(_ id: EngineID) {
        guard let formula = id.homebrewFormula else { return }
        confirmEngineAction(id: id, action: "Uninstall", message: "Homebrew will remove the ‘\(formula)’ formula. Other formulas and shared dependencies are left in place.") { [weak self] in
            self?.runHomebrew(arguments: ["uninstall", "--formula", formula], successMessage: "\(id.displayName) uninstalled.")
        }
    }

    func checkForUpdates(_ id: EngineID) {
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
        guard let formula = id.homebrewFormula else { return }
        confirmEngineAction(id: id, action: "Update", message: "Homebrew will upgrade the ‘\(formula)’ formula and may download dependencies. No update starts until you confirm here.") { [weak self] in
            self?.runHomebrew(arguments: ["upgrade", "--formula", formula], successMessage: "\(id.displayName) updated.")
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

    private func confirmEngineAction(id: EngineID, action: String, message: String, confirmed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(action) \(id.displayName)?"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { confirmed() }
    }

    private func runHomebrew(arguments: [String], successMessage: String, refreshAfter: Bool = true) {
        guard let brew = ExecutableLocator.resolve(["brew"]) else {
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
                    if refreshAfter { self.refreshEngines() }
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription; self.conversionMessage = nil }
            }
        }
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
    case history = "History"
    case engines = "Engines"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .convert: "arrow.triangle.2.circlepath"
        case .history: "clock.arrow.circlepath"
        case .engines: "shippingbox"
        case .settings: "gearshape"
        }
    }
}
