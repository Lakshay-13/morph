import AppKit
import Foundation
import MorphCore
import UserNotifications

@main
private enum MorphQuickConvertMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = QuickConvertAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

private final class QuickConvertAppDelegate: NSObject, NSApplicationDelegate {
    private let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Morph", isDirectory: true)
    private var pendingRequests: [QuickConversionRequest] = []
    private var pendingConversionRequests: [FinderConversionRequest] = []
    private var pendingFileSelections: [[URL]] = []
    private var isConverting = false
    private var cancellation: CancellationToken?
    private var statusItem: NSStatusItem?
    private var statusMessageItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let openedFiles = urls.filter(\.isFileURL)
        if !openedFiles.isEmpty {
            enqueueOpenedFiles(openedFiles.map(\.path))
        }
        enqueueConversionRequests(in: urls)
        matchPendingRequests()
        startNextRequestIfReady()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        enqueueOpenedFiles(filenames)
        matchPendingRequests()
        startNextRequestIfReady()
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        enqueueOpenedFiles([filename])
        matchPendingRequests()
        startNextRequestIfReady()
        return true
    }

    private func enqueueOpenedFiles(_ filenames: [String]) {
        guard !filenames.isEmpty else { return }
        let inputs = filenames.map { URL(fileURLWithPath: $0).standardizedFileURL }
        pendingFileSelections.append(inputs)
        let paths = inputs.map(\.path).sorted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            self.pendingFileSelections.removeAll { $0.map(\.path).sorted() == paths }
            self.terminateIfIdle()
        }
    }

    private func conversionRequests(in urls: [URL]) -> [FinderConversionRequest] {
        var requests: [FinderConversionRequest] = []
        for url in urls {
            guard url.scheme == "morphquick", url.host == "convert",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let encoded = components.queryItems?.first(where: { $0.name == "request" })?.value,
                  let data = Data(base64Encoded: encoded),
                  let payload = try? JSONDecoder().decode(FinderConversionRequest.self, from: data),
                  !payload.paths.isEmpty,
                  payload.outputExtension.range(of: #"^[a-z0-9.]{1,16}$"#, options: .regularExpression) != nil else {
                continue
            }
            requests.append(payload)
        }
        return requests
    }

    private func enqueueConversionRequests(in urls: [URL]) {
        let requests = conversionRequests(in: urls)
        pendingConversionRequests.append(contentsOf: requests)
        for request in requests {
            let paths = request.paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.sorted()
            let outputExtension = request.outputExtension
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self else { return }
                self.pendingConversionRequests.removeAll {
                    $0.outputExtension == outputExtension &&
                    $0.paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.sorted() == paths
                }
                self.terminateIfIdle()
            }
        }
    }

    private func matchPendingRequests() {
        while let requestIndex = pendingConversionRequests.firstIndex(where: { request in
            let requestedPaths = request.paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.sorted()
            return pendingFileSelections.contains { $0.map(\.path).sorted() == requestedPaths }
        }) {
            let request = pendingConversionRequests.remove(at: requestIndex)
            let requestedPaths = request.paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.sorted()
            guard let selectionIndex = pendingFileSelections.firstIndex(where: { $0.map(\.path).sorted() == requestedPaths }) else { continue }
            let inputs = pendingFileSelections.remove(at: selectionIndex)
            guard inputs.allSatisfy({ (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) else {
                continue
            }
            pendingRequests.append(QuickConversionRequest(inputs: inputs, outputExtension: request.outputExtension))
        }
    }

    private func startNextRequestIfReady() {
        guard !isConverting else { return }
        guard !pendingRequests.isEmpty else {
            terminateIfIdle()
            return
        }

        let request = pendingRequests.removeFirst()
        let token = CancellationToken()
        cancellation = token
        isConverting = true
        installProgressStatusItem(total: request.inputs.count)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let registry = EngineRegistry.discoverFinderSync()
            let available = QuickConversionCatalog.availableOutputs(for: request.inputs, registry: registry)
            guard let format = available.first(where: { $0.fileExtension == request.outputExtension }) else {
                DispatchQueue.main.async {
                    self?.finishConversion(
                        results: [],
                        failures: [(request.inputs.first?.lastPathComponent ?? "Selection", "This conversion is no longer available for the selected files or installed engines.")],
                        cancelled: false,
                        total: request.inputs.count
                    )
                }
                return
            }

            let settings = self?.conversionSettings() ?? QuickConversionSettings()
            let service = ConversionService(registry: registry)
            var results: [ConversionResult] = []
            var failures: [(String, String)] = []

            for (index, input) in request.inputs.enumerated() {
                if token.isCancelled { break }
                DispatchQueue.main.async {
                    self?.updateProgress(index: index + 1, total: request.inputs.count, fileName: input.lastPathComponent)
                }
                do {
                    let conversion = ConversionRequest(
                        inputURL: input,
                        outputFormat: format,
                    outputDirectory: self?.outputDirectory(
                            for: input,
                            defaultDirectory: input.deletingLastPathComponent(),
                            settings: settings
                        ) ?? input.deletingLastPathComponent(),
                        imageQuality: settings.imageQuality
                    )
                    results.append(try service.convert(conversion, cancellation: token))
                } catch {
                    if !token.isCancelled { failures.append((input.lastPathComponent, error.localizedDescription)) }
                }
            }

            DispatchQueue.main.async {
                self?.finishConversion(results: results, failures: failures, cancelled: token.isCancelled, total: request.inputs.count)
            }
        }
    }

    private func terminateIfIdle() {
        guard !isConverting,
              pendingRequests.isEmpty,
              pendingConversionRequests.isEmpty,
              pendingFileSelections.isEmpty else { return }
        NSApp.terminate(nil)
    }

    private func conversionSettings() -> QuickConversionSettings {
        let domain = UserDefaults.standard.persistentDomain(forName: "com.lakshaychawla.Morph")
        guard let data = domain?["com.lakshaychawla.Morph.settings"] as? Data,
              let settings = try? JSONDecoder().decode(QuickConversionSettings.self, from: data) else {
            return QuickConversionSettings()
        }
        return settings
    }

    private func outputDirectory(for input: URL, defaultDirectory: URL, settings: QuickConversionSettings) -> URL {
        switch settings.outputMode {
        case "Morph Output folder":
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Morph Output", isDirectory: true)
        case "Choose a folder":
            if let path = settings.customOutputPath, !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return input.deletingLastPathComponent()
        default:
            return defaultDirectory
        }
    }

    private func installProgressStatusItem(total: Int) {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Morph …"
        item.button?.toolTip = "Morph is preparing the selected conversion"
        let menu = NSMenu()
        let message = NSMenuItem(title: "Checking installed conversion support…", action: nil, keyEquivalent: "")
        message.isEnabled = false
        menu.addItem(message)
        menu.addItem(.separator())
        let cancel = NSMenuItem(title: "Cancel Conversion", action: #selector(cancelConversion(_:)), keyEquivalent: "")
        cancel.target = self
        menu.addItem(cancel)
        item.menu = menu
        statusItem = item
        statusMessageItem = message
        updateProgress(index: 0, total: total, fileName: nil)
    }

    private func updateProgress(index: Int, total: Int, fileName: String?) {
        let message = fileName.map { "Converting \(index) of \(total): \($0)" } ?? "Preparing conversion…"
        statusItem?.button?.title = "Morph \(min(index, total))/\(total)"
        statusItem?.button?.toolTip = message
        statusMessageItem?.title = message
    }

    @objc private func cancelConversion(_ sender: NSMenuItem) {
        cancellation?.cancel()
        statusMessageItem?.title = "Cancelling conversion…"
    }

    private func finishConversion(
        results: [ConversionResult],
        failures: [(String, String)],
        cancelled: Bool,
        total: Int
    ) {
        saveHistory(results)
        isConverting = false
        cancellation = nil

        let summary: String
        if cancelled {
            summary = results.isEmpty ? "Conversion cancelled" : "Cancelled after converting \(results.count) of \(total) files"
        } else if failures.isEmpty {
            summary = "Converted \(results.count) of \(total) files"
        } else if results.isEmpty {
            summary = failures.first?.1 ?? "Conversion failed"
        } else {
            summary = "Converted \(results.count); \(failures.count) failed"
        }

        statusMessageItem?.title = summary
        statusItem?.button?.title = cancelled ? "Morph —" : (failures.isEmpty ? "Morph ✓" : "Morph !")
        deliverCompletionNotification(summary: summary)

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if let statusItem = self.statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            self.statusItem = nil
            self.statusMessageItem = nil
            self.startNextRequestIfReady()
        }
    }

    private func saveHistory(_ results: [ConversionResult]) {
        guard !results.isEmpty else { return }
        let historyURL = supportDirectory.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        var history = (try? Data(contentsOf: historyURL)).flatMap { try? JSONDecoder().decode([QuickHistoryItem].self, from: $0) } ?? []
        history.insert(contentsOf: results.map {
            QuickHistoryItem(id: UUID(), inputName: $0.inputURL.lastPathComponent, outputPath: $0.outputURL.path, engineName: $0.engine.displayName, date: $0.completedAt)
        }, at: 0)
        history = Array(history.prefix(200))
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: historyURL, options: .atomic) }
    }

    private func deliverCompletionNotification(summary: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Morph"
            content.body = summary
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}

private struct FinderConversionRequest: Decodable {
    let paths: [String]
    let outputExtension: String
}

private struct QuickConversionRequest {
    let inputs: [URL]
    let outputExtension: String
}

private struct QuickConversionSettings: Decodable {
    var outputMode = "Beside each original"
    var customOutputPath: String?
    var imageQuality = 0.85

    private enum CodingKeys: String, CodingKey {
        case outputMode, customOutputPath, imageQuality
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputMode = try values.decodeIfPresent(String.self, forKey: .outputMode) ?? "Beside each original"
        customOutputPath = try values.decodeIfPresent(String.self, forKey: .customOutputPath)
        imageQuality = try values.decodeIfPresent(Double.self, forKey: .imageQuality) ?? 0.85
    }
}

private struct QuickHistoryItem: Codable {
    let id: UUID
    let inputName: String
    let outputPath: String
    let engineName: String
    let date: Date
}
