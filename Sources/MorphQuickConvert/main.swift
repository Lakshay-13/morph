import AppKit
import CoreServices
import Foundation
import MorphCore
import os
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
    private let logger = Logger(subsystem: "com.lakshaychawla.Morph", category: "QuickConvert")
    private let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Morph", isDirectory: true)
    private var pendingRequests: [QuickConversionRequest] = []
    private var receivedFinderRequestIDs: Set<String> = []
    private var isConverting = false
    private var cancellation: CancellationToken?
    private var statusItem: NSStatusItem?
    private var statusMessageItem: NSMenuItem?
    private var cancelMenuItem: NSMenuItem?
    private var quitMenuItem: NSMenuItem?
    private var quitRequested = false
    private var mainApplicationURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
    private var finderSyncExtensionURL: URL {
        mainApplicationURL
            .appendingPathComponent("Contents/PlugIns/MorphFinderSync.appex", isDirectory: true)
            .standardizedFileURL
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItemIfNeeded()
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor) {
        let senderPID = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        guard let senderPID, isFinderSyncSender(pid: pid_t(senderPID)) else {
            logger.error("Rejected a Morph conversion URL from an untrusted Apple Event sender.")
            return
        }
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "morphquick" else {
            logger.error("Rejected a malformed Finder conversion URL.")
            return
        }
        guard !quitRequested else {
            logger.info("Ignoring a Finder request while Morph is quitting.")
            return
        }
        let requestCount = enqueueConversionRequests(in: [url])
        logger.info("Accepted a conversion URL from Finder Sync and queued \(requestCount, privacy: .public) requests.")
        startNextRequestIfReady()
    }

    private func isFinderSyncSender(pid: pid_t) -> Bool {
        guard let sender = NSRunningApplication(processIdentifier: pid),
              sender.bundleIdentifier == "com.lakshaychawla.Morph.FinderSync",
              let senderBundleURL = sender.bundleURL?.standardizedFileURL else {
            return false
        }
        return senderBundleURL == finderSyncExtensionURL
    }

    private func conversionRequests(in urls: [URL]) -> [FinderConversionRequest] {
        var requests: [FinderConversionRequest] = []
        for url in urls {
            guard url.scheme == "morphquick", url.host == "convert",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let encoded = components.queryItems?.first(where: { $0.name == "request" })?.value,
                  encoded.utf8.count <= 700_000,
                  let data = Data(base64Encoded: encoded),
                  let payload = try? JSONDecoder().decode(FinderConversionRequest.self, from: data),
                  (1...100).contains(payload.paths.count),
                  payload.paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4_096 && !$0.utf8.contains(0) }),
                  payload.requestID == nil || UUID(uuidString: payload.requestID ?? "") != nil,
                  payload.outputExtension.range(of: #"^[a-z0-9.]{1,16}$"#, options: .regularExpression) != nil else {
                continue
            }
            requests.append(payload)
        }
        return requests
    }

    @discardableResult
    private func enqueueConversionRequests(in urls: [URL]) -> Int {
        let requests = conversionRequests(in: urls)
        var queuedCount = 0
        for request in requests {
            if let requestID = request.requestID, receivedFinderRequestIDs.contains(requestID) {
                logger.debug("Ignored duplicate Finder request \(requestID, privacy: .public).")
                continue
            }
            let inputs = request.paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            var inputValidationMessage: String?
            for input in inputs {
                do {
                    guard let isRegularFile = try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile else {
                        inputValidationMessage = "Morph couldn't verify access to the selected file. Check Files & Folders permissions."
                        break
                    }
                    guard isRegularFile else {
                        inputValidationMessage = "Morph can convert files, not folders."
                        break
                    }
                } catch {
                    logger.error("Couldn't access a Finder-selected input (\(error.localizedDescription, privacy: .public)).")
                    inputValidationMessage = "Morph couldn't access the selected file. Check Files & Folders permissions."
                    break
                }
            }
            if let inputValidationMessage {
                statusMessageItem?.title = inputValidationMessage
                statusItem?.button?.title = "Morph !"
                continue
            }
            logger.info("Validated \(inputs.count, privacy: .public) Finder-selected paths; output .\(request.outputExtension, privacy: .public).")
            if let requestID = request.requestID {
                if receivedFinderRequestIDs.count >= 512 { receivedFinderRequestIDs.removeAll(keepingCapacity: true) }
                receivedFinderRequestIDs.insert(requestID)
            }
            pendingRequests.append(QuickConversionRequest(inputs: inputs, outputExtension: request.outputExtension))
            queuedCount += 1
        }
        return queuedCount
    }

    private func startNextRequestIfReady() {
        guard !isConverting, !quitRequested else { return }
        guard !pendingRequests.isEmpty else { return }

        let request = pendingRequests.removeFirst()
        let token = CancellationToken()
        cancellation = token
        isConverting = true
        logger.info("Starting conversion of \(request.inputs.count, privacy: .public) files to .\(request.outputExtension, privacy: .public).")
        installProgressStatusItem(total: request.inputs.count)

        ensureMainApplicationIsRunningInBackground { [weak self] in
            guard let self else { return }
            guard !token.isCancelled else {
                self.finishConversion(results: [], failures: [], cancelled: true, total: request.inputs.count)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let registry = self?.conversionRegistry() ?? EngineRegistry.discoverFinderSync()
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
    }

    private func ensureMainApplicationIsRunningInBackground(completion: @escaping () -> Void) {
        let mainBundleID = "com.lakshaychawla.Morph"
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == mainBundleID && !$0.isTerminated
        }) {
            completion()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--morph-background"]
        NSWorkspace.shared.openApplication(at: mainApplicationURL, configuration: configuration) { _, error in
            if let error {
                self.logger.error("Couldn't keep Morph running in the background for Finder access (\(error.localizedDescription, privacy: .public)).")
            } else {
                self.logger.info("Started the Morph app in hidden background mode for Finder conversion access.")
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func conversionRegistry() -> EngineRegistry {
        if let snapshot = EngineRegistry.loadFinderSyncPreferencesSnapshot() {
            logger.info("Using saved Finder conversion registry with \(snapshot.registry.routes.count, privacy: .public) routes.")
            return snapshot.registry
        }
        logger.info("No saved Finder conversion registry; discovering native Finder routes only.")
        return EngineRegistry.discoverFinderSync()
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

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Morph"
        item.button?.toolTip = "Morph is ready for Finder conversions"
        let menu = NSMenu()
        let message = NSMenuItem(title: "Ready for Finder conversions", action: nil, keyEquivalent: "")
        message.isEnabled = false
        menu.addItem(message)
        menu.addItem(.separator())
        let cancel = NSMenuItem(title: "Cancel Conversion", action: #selector(cancelConversion(_:)), keyEquivalent: "")
        cancel.target = self
        cancel.isHidden = true
        menu.addItem(cancel)
        menu.addItem(.separator())
        let openMorph = NSMenuItem(title: "Open Morph…", action: #selector(openMorph(_:)), keyEquivalent: "")
        openMorph.target = self
        menu.addItem(openMorph)
        let quitMorph = NSMenuItem(title: "Quit Morph", action: #selector(quitMorph(_:)), keyEquivalent: "")
        quitMorph.target = self
        menu.addItem(quitMorph)
        item.menu = menu
        statusItem = item
        statusMessageItem = message
        cancelMenuItem = cancel
        quitMenuItem = quitMorph
    }

    private func installProgressStatusItem(total: Int) {
        installStatusItemIfNeeded()
        cancelMenuItem?.isHidden = false
        updateProgress(index: 0, total: total, fileName: nil)
    }

    private func updateProgress(index: Int, total: Int, fileName: String?) {
        let message = fileName.map { "Converting \(index) of \(total): \($0)" } ?? "Preparing conversion…"
        statusItem?.button?.title = "Morph \(min(index, total))/\(total)"
        statusItem?.button?.toolTip = message
        statusMessageItem?.title = message
    }

    @objc private func openMorph(_ sender: NSMenuItem) {
        guard let url = URL(string: "morph://show") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: mainApplicationURL, configuration: configuration) { _, error in
            if let error {
                self.logger.error("Couldn't open the Morph app from the menu bar (\(error.localizedDescription, privacy: .public)).")
            }
        }
    }

    @objc private func quitMorph(_ sender: NSMenuItem) {
        guard isConverting else {
            pendingRequests.removeAll()
            terminateBackgroundMainApplicationIfRunning()
            NSApp.terminate(nil)
            return
        }
        quitRequested = true
        pendingRequests.removeAll()
        quitMenuItem?.title = "Quitting Morph…"
        quitMenuItem?.isEnabled = false
        cancelMenuItem?.isHidden = true
        statusMessageItem?.title = "Cancelling conversion before quitting…"
        cancellation?.cancel()
    }

    @objc private func cancelConversion(_ sender: NSMenuItem) {
        cancellation?.cancel()
        statusMessageItem?.title = "Cancelling conversion…"
    }

    private func terminateBackgroundMainApplicationIfRunning() {
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.lakshaychawla.Morph" && !$0.isTerminated
        }), let url = URL(string: "morph://quit") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([url], withApplicationAt: mainApplicationURL, configuration: configuration) { _, error in
            if let error {
                self.logger.error("Couldn't stop Morph's background host during quit (\(error.localizedDescription, privacy: .public)).")
            }
        }
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
        logger.info("Conversion finished: \(results.count, privacy: .public) succeeded, \(failures.count, privacy: .public) failed, cancelled: \(cancelled, privacy: .public).")

        statusMessageItem?.title = summary
        statusItem?.button?.title = cancelled ? "Morph —" : (failures.isEmpty ? "Morph ✓" : "Morph !")
        cancelMenuItem?.isHidden = true
        deliverCompletionNotification(summary: summary)
        if quitRequested {
            terminateBackgroundMainApplicationIfRunning()
            NSApp.terminate(nil)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard !self.isConverting else { return }
            self.startNextRequestIfReady()
            guard !self.isConverting else { return }
            self.statusMessageItem?.title = "Ready for Finder conversions"
            self.statusItem?.button?.title = "Morph"
            self.statusItem?.button?.toolTip = "Morph is ready for Finder conversions"
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
    let requestID: String?
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
