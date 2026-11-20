import AppKit
import CoreServices
import Darwin
import Foundation
import MorphCore
import os
import Security
import UserNotifications

@main
private enum MorphQuickConvertMain {
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--morph-keychain-self-test") {
            Darwin.exit(EngineExecutableTrust.verifyPersistentKeychainAccess() ? EXIT_SUCCESS : EXIT_FAILURE)
        }
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
    private let inputPreflightQueue = DispatchQueue(label: "com.lakshaychawla.Morph.FinderInputPreflight", qos: .userInitiated)
    private var pendingRequests: [QuickConversionRequest] = []
    private var inputPreflightAttempts: [String: UUID] = [:]
    private var timedOutInputPreflightAttempts: Set<UUID> = []
    private var finderRequestLedger = FinderRequestIDLedger()
    private var finderRequestLedgerIsUsable = true
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

    private var menuBarImage: NSImage? {
        let imageURL = mainApplicationURL.appendingPathComponent("Contents/Resources/morph-menubar.png")
        guard let image = NSImage(contentsOf: imageURL) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        loadFinderRequestLedger()
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
        guard let senderTokenDescriptor = event.attributeDescriptor(forKeyword: keySenderAuditTokenAttr),
              senderTokenDescriptor.descriptorType == typeAuditToken,
              let senderAuditToken = senderTokenDescriptor.data as Data?,
              senderAuditToken.count == MemoryLayout<audit_token_t>.size,
              isFinderSyncSender(auditToken: senderAuditToken) else {
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
        logger.info("Started file-access checks for \(requestCount, privacy: .public) Finder conversion requests.")
    }

    private func isFinderSyncSender(auditToken: Data) -> Bool {
        guard let senderCode = codeIdentity(forAuditToken: auditToken),
              let installedCode = codeIdentity(at: finderSyncExtensionURL) else { return false }
        return senderCode.identifier == "com.lakshaychawla.Morph.FinderSync"
            && senderCode.uniqueCodeHash == installedCode.uniqueCodeHash
    }

    private func codeIdentity(forAuditToken auditToken: Data) -> (identifier: String, uniqueCodeHash: Data)? {
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        var processCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(rawValue: 0), &processCode) == errSecSuccess,
              let processCode,
              SecCodeCheckValidity(processCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(processCode, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return codeIdentity(for: staticCode)
    }

    private func codeIdentity(at bundleURL: URL) -> (identifier: String, uniqueCodeHash: Data)? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            return nil
        }
        return codeIdentity(for: staticCode)
    }

    private func codeIdentity(for staticCode: SecStaticCode) -> (identifier: String, uniqueCodeHash: Data)? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let uniqueCodeHash = values[kSecCodeInfoUnique as String] as? Data else { return nil }
        return (identifier, uniqueCodeHash)
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
                  UUID(uuidString: payload.requestID) != nil,
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
        var checkingCount = 0
        for request in requests {
            if finderRequestLedger.contains(request.requestID) {
                logger.debug("Ignored duplicate Finder request \(request.requestID, privacy: .public).")
                continue
            }
            let requestID = UUID(uuidString: request.requestID)!.uuidString.lowercased()
            guard inputPreflightAttempts[requestID] == nil,
                  inputPreflightAttempts.count < 16 else {
                logger.info("Deferred a Finder request because the input-access queue is full.")
                continue
            }
            let attemptID = UUID()
            inputPreflightAttempts[requestID] = attemptID
            checkingCount += 1

            inputPreflightQueue.async { [weak self] in
                let result: Result<[URL], FinderInputPreflightError>
                do {
                    result = .success(try FinderInputPreflight.validate(paths: request.paths))
                } catch let error as FinderInputPreflightError {
                    result = .failure(error)
                } catch {
                    result = .failure(.invalidPath)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.completeInputPreflight(request, requestID: requestID, attemptID: attemptID, result: result)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, self.inputPreflightAttempts[requestID] == attemptID else { return }
                self.timedOutInputPreflightAttempts.insert(attemptID)
                self.statusMessageItem?.title = "Waiting for macOS file access. Check Files & Folders permissions if no prompt appears."
                self.statusItem?.button?.title = "…"
                self.logger.info("Finder input access is still pending after the permission wait interval.")
            }
        }
        if checkingCount > 0 {
            statusMessageItem?.title = "Checking selected files. macOS may ask for Files & Folders permission."
            statusItem?.button?.title = "…"
        }
        return checkingCount
    }

    private func completeInputPreflight(
        _ request: FinderConversionRequest,
        requestID: String,
        attemptID: UUID,
        result: Result<[URL], FinderInputPreflightError>
    ) {
        guard inputPreflightAttempts[requestID] == attemptID else { return }
        inputPreflightAttempts.removeValue(forKey: requestID)
        let timedOut = timedOutInputPreflightAttempts.remove(attemptID) != nil
        guard !timedOut else {
            updateInputPreflightStatus()
            if inputPreflightAttempts.isEmpty, !isConverting, pendingRequests.isEmpty {
                statusMessageItem?.title = "File access timed out. Retry the conversion from Finder."
                statusItem?.button?.title = "!"
            }
            return
        }

        let inputs: [URL]
        switch result {
        case .success(let validatedInputs):
            inputs = validatedInputs
        case .failure(.symbolicLink):
            logger.error("Rejected a symbolic-link Finder input.")
            statusMessageItem?.title = "Morph converts regular files, not folders or symbolic links."
            statusItem?.button?.title = "!"
            updateInputPreflightStatus(preserveMessage: inputPreflightAttempts.isEmpty)
            return
        case .failure(.notRegularFile):
            logger.error("Rejected a non-regular Finder input.")
            statusMessageItem?.title = "Morph converts regular files, not folders or special files."
            statusItem?.button?.title = "!"
            updateInputPreflightStatus(preserveMessage: inputPreflightAttempts.isEmpty)
            return
        case .failure(.openFailed(let code)):
            let detail = NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
            logger.error("Couldn't open a Finder-selected input (\(detail, privacy: .private)).")
            statusMessageItem?.title = "Morph couldn't access the selected file. Check Files & Folders permissions."
            statusItem?.button?.title = "!"
            updateInputPreflightStatus(preserveMessage: inputPreflightAttempts.isEmpty)
            return
        case .failure(.invalidPath):
            logger.error("Rejected an invalid Finder-selected input path.")
            statusMessageItem?.title = "Morph couldn't verify the selected file. Try selecting it again in Finder."
            statusItem?.button?.title = "!"
            updateInputPreflightStatus(preserveMessage: inputPreflightAttempts.isEmpty)
            return
        }

        logger.info("Validated \(inputs.count, privacy: .public) Finder-selected paths; output .\(request.outputExtension, privacy: .public).")
        guard registerFinderRequestID(request.requestID) else {
            statusMessageItem?.title = finderRequestLedgerIsUsable
                ? "Morph couldn't save this Finder request. Check storage and permissions, then try again."
                : "Morph couldn't read its saved Finder retry history. Remove finder-request-ids.json from Application Support/Morph, then relaunch."
            statusItem?.button?.title = "!"
            updateInputPreflightStatus(preserveMessage: inputPreflightAttempts.isEmpty)
            return
        }
        pendingRequests.append(QuickConversionRequest(inputs: inputs, outputExtension: request.outputExtension))
        startNextRequestIfReady()
        updateInputPreflightStatus()
    }

    private func updateInputPreflightStatus(preserveMessage: Bool = false) {
        guard !isConverting, pendingRequests.isEmpty, !preserveMessage else { return }
        if inputPreflightAttempts.isEmpty {
            statusMessageItem?.title = "Ready for Finder conversions"
            statusItem?.button?.title = ""
        } else if timedOutInputPreflightAttempts.isEmpty {
            statusMessageItem?.title = "Checking selected files. macOS may ask for Files & Folders permission."
            statusItem?.button?.title = "…"
        }
    }

    private var finderRequestLedgerURL: URL {
        supportDirectory.appendingPathComponent("finder-request-ids.json")
    }

    private func loadFinderRequestLedger() {
        guard FileManager.default.fileExists(atPath: finderRequestLedgerURL.path) else { return }
        let descriptor = finderRequestLedgerURL.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            finderRequestLedgerIsUsable = false
            logger.error("Could not open the persisted Finder request ledger safely.")
            return
        }
        defer { close(descriptor) }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              fileInfo.st_mode & S_IFMT == S_IFREG,
              fileInfo.st_size >= 0,
              fileInfo.st_size <= 128 * 1024 else {
            finderRequestLedgerIsUsable = false
            logger.error("The persisted Finder request ledger is not a bounded regular file.")
            return
        }
        var data = Data(count: Int(fileInfo.st_size))
        var bytesRead = 0
        while bytesRead < data.count {
            let count = data.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress!.advanced(by: bytesRead), bytes.count - bytesRead)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                finderRequestLedgerIsUsable = false
                logger.error("The persisted Finder request ledger ended unexpectedly.")
                return
            }
            bytesRead += count
        }
        guard let decoded = try? JSONDecoder().decode(FinderRequestIDLedger.self, from: data) else {
            finderRequestLedgerIsUsable = false
            logger.error("The persisted Finder request ledger is malformed.")
            return
        }
        finderRequestLedger = decoded
    }

    private func registerFinderRequestID(_ identifier: String) -> Bool {
        guard finderRequestLedgerIsUsable else { return false }
        var updated = finderRequestLedger
        guard updated.register(identifier) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(updated)
            try data.write(to: finderRequestLedgerURL, options: .atomic)
            if chmod(finderRequestLedgerURL.path, mode_t(0o600)) != 0 {
                logger.error("Could not restrict Finder request ledger permissions to the current user.")
            }
            finderRequestLedger = updated
            return true
        } catch {
            logger.error("Could not persist a Finder conversion request ID (\(error.localizedDescription, privacy: .private)).")
            return false
        }
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
                self.finishConversion(results: [], failureCount: 0, cancelled: true, total: request.inputs.count)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self, !token.isCancelled else {
                    DispatchQueue.main.async { [weak self] in
                        self?.finishConversion(results: [], failureCount: 0, cancelled: true, total: request.inputs.count)
                    }
                    return
                }
                let registry = self.conversionRegistry(cancellation: token)
                guard !token.isCancelled else {
                    DispatchQueue.main.async { [weak self] in
                        self?.finishConversion(results: [], failureCount: 0, cancelled: true, total: request.inputs.count)
                    }
                    return
                }
                let available = QuickConversionCatalog.availableOutputs(for: request.inputs, registry: registry)
                guard let format = available.first(where: { $0.fileExtension == request.outputExtension }) else {
                    DispatchQueue.main.async {
                        self.finishConversion(
                            results: [],
                            failureCount: 1,
                            cancelled: false,
                            total: request.inputs.count
                        )
                    }
                    return
                }

                let settings = self.conversionSettings()
                let outputFallbackMessage = self.outputFallbackMessage(for: request.inputs, settings: settings)
                let service = ConversionService(registry: registry)
                var results: [ConversionResult] = []
                var failureCount = 0

                for (index, input) in request.inputs.enumerated() {
                    if token.isCancelled { break }
                    DispatchQueue.main.async { [weak self] in
                        self?.updateProgress(index: index + 1, total: request.inputs.count, fileName: input.lastPathComponent)
                    }
                    do {
                        let conversion = ConversionRequest(
                            inputURL: input,
                            outputFormat: format,
                            outputDirectory: self.outputDirectory(
                                for: input,
                                defaultDirectory: input.deletingLastPathComponent(),
                                settings: settings
                            ),
                            imageQuality: settings.imageQuality,
                            stripLocationMetadata: settings.stripLocationMetadata
                        )
                        results.append(try service.convert(conversion, cancellation: token))
                    } catch {
                        if !token.isCancelled {
                            failureCount += 1
                            self.logger.error(
                                "Conversion failed for \(input.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)"
                            )
                        }
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    self?.finishConversion(
                        results: results,
                        failureCount: failureCount,
                        cancelled: token.isCancelled,
                        total: request.inputs.count,
                        outputFallbackMessage: outputFallbackMessage
                    )
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
                self.logger.error("Couldn't keep Morph running in the background for Finder access (\(error.localizedDescription, privacy: .private)).")
            } else {
                self.logger.info("Started the Morph app in hidden background mode for Finder conversion access.")
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func conversionRegistry(cancellation: CancellationToken) -> EngineRegistry {
        // Preferences may contain stale executable URLs. Rediscover installed engines
        // from Morph's fixed search roots immediately before a Finder conversion.
        EngineRegistry.discover(cancellation: cancellation)
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
        let fallback = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Morph Output", isDirectory: true)
        let candidate: URL
        switch settings.outputMode {
        case "Morph Output folder":
            candidate = fallback
        case "Choose a folder":
            if let path = settings.customOutputPath, !path.isEmpty {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                candidate = EngineExecutableTrust.protectedOutputDirectoryMatches(directory) ? directory : fallback
            } else {
                candidate = fallback
            }
        default:
            candidate = defaultDirectory
        }
        try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        guard OutputDirectoryPolicy.canSafelyStage(in: candidate) else {
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        }
        return candidate
    }

    private func outputFallbackMessage(for inputs: [URL], settings: QuickConversionSettings) -> String? {
        let fallback = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Morph Output", isDirectory: true)
        if settings.outputMode == "Choose a folder" {
            guard let path = settings.customOutputPath, !path.isEmpty,
                  EngineExecutableTrust.protectedOutputDirectoryMatches(URL(fileURLWithPath: path, isDirectory: true)) else {
                return "The saved custom folder could not be verified; Morph used Documents/Morph Output for completed conversions. Choose the folder again in Settings."
            }
        }
        let unsafeSelection = inputs.contains { input in
            let directory: URL
            switch settings.outputMode {
            case "Morph Output folder": directory = fallback
            case "Choose a folder":
                guard let path = settings.customOutputPath else { return false }
                directory = URL(fileURLWithPath: path, isDirectory: true)
            default: directory = input.deletingLastPathComponent()
            }
            return directory.standardizedFileURL.path != fallback.standardizedFileURL.path
                && !OutputDirectoryPolicy.canSafelyStage(in: directory)
        }
        guard unsafeSelection else { return nil }
        return "Morph could not safely use the selected output folder, so completed conversions were saved to Documents/Morph Output."
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarImage ?? NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Morph"
        )
        item.button?.imagePosition = .imageLeading
        item.button?.title = ""
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
        statusItem?.button?.title = "\(min(index, total))/\(total)"
        statusItem?.button?.toolTip = message
        statusMessageItem?.title = message
    }

    @objc private func openMorph(_ sender: NSMenuItem) {
        guard let url = URL(string: "morph://show") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: mainApplicationURL, configuration: configuration) { _, error in
            if let error {
                self.logger.error("Couldn't open the Morph app from the menu bar (\(error.localizedDescription, privacy: .private)).")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.quitRequested, self.isConverting else { return }
            self.logger.error("A conversion did not stop within the quit grace period; terminating the Finder helper.")
            Darwin.exit(EXIT_SUCCESS)
        }
    }

    @objc private func cancelConversion(_ sender: NSMenuItem) {
        cancellation?.cancel()
        statusMessageItem?.title = "Cancelling conversion…"
    }

    private func terminateBackgroundMainApplicationIfRunning() {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.lakshaychawla.Morph" &&
                !$0.isTerminated &&
                $0.bundleURL?.standardizedFileURL == mainApplicationURL.standardizedFileURL
        }) else { return }
        if !application.terminate() {
            logger.error("Couldn't request a graceful shutdown of Morph's background host.")
        }
    }

    private func finishConversion(
        results: [ConversionResult],
        failureCount: Int,
        cancelled: Bool,
        total: Int,
        outputFallbackMessage: String? = nil
    ) {
        saveHistory(results)
        isConverting = false
        cancellation = nil

        let summary: String
        if cancelled {
            summary = results.isEmpty ? "Conversion cancelled" : "Cancelled after converting \(results.count) of \(total) files"
        } else if failureCount == 0 {
            summary = "Converted \(results.count) of \(total) files"
        } else if results.isEmpty {
            summary = "Conversion failed. See Morph's logs for details."
        } else {
            summary = "Converted \(results.count); \(failureCount) failed. See Morph's logs for details."
        }
        let finalSummary = outputFallbackMessage.map { "\(summary). \($0)" } ?? summary
        logger.info("Conversion finished: \(results.count, privacy: .public) succeeded, \(failureCount, privacy: .public) failed, cancelled: \(cancelled, privacy: .public).")

        statusMessageItem?.title = finalSummary
        statusItem?.button?.title = cancelled ? "—" : (failureCount == 0 ? "✓" : "!")
        cancelMenuItem?.isHidden = true
        deliverCompletionNotification(summary: finalSummary)
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
            self.statusItem?.button?.title = ""
            self.statusItem?.button?.toolTip = "Morph is ready for Finder conversions"
        }
    }

    private func saveHistory(_ results: [ConversionResult]) {
        guard !results.isEmpty else { return }
        let historyURL = supportDirectory.appendingPathComponent("history.json")
        let entries = results.map {
            ConversionHistoryEntry(inputName: $0.inputURL.lastPathComponent, outputPath: $0.outputURL.path, engineName: $0.engine.displayName, date: $0.completedAt)
        }
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            _ = try ConversionHistoryStore.merge(entries, into: historyURL)
        } catch {
            logger.error("Couldn't safely merge conversion history (\(error.localizedDescription, privacy: .private)).")
        }
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
    let requestID: String
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
    var stripLocationMetadata = true

    private enum CodingKeys: String, CodingKey {
        case outputMode, customOutputPath, imageQuality, stripLocationMetadata
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputMode = try values.decodeIfPresent(String.self, forKey: .outputMode) ?? "Beside each original"
        customOutputPath = try values.decodeIfPresent(String.self, forKey: .customOutputPath)
        imageQuality = try values.decodeIfPresent(Double.self, forKey: .imageQuality) ?? 0.85
        stripLocationMetadata = try values.decodeIfPresent(Bool.self, forKey: .stripLocationMetadata) ?? true
    }
}
