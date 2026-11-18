import AppKit
import Darwin
import FinderSync
import Foundation
import MorphCore
import os

final class MorphFinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    private let logger = Logger(subsystem: "com.lakshaychawla.Morph", category: "FinderSync")
    private lazy var fallbackRegistry = EngineRegistry.discoverFinderSync()
    private var nextRequestTag = 1
    private var pendingRequestsByTag: [Int: FinderConversionRequest] = [:]
    private var menuOwnerLockDescriptor: Int32 = -1

    override init() {
        super.init()
        controller.directoryURLs = monitoredDirectories
        let userHome = monitoredHomeDirectory
        let sandboxHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        logger.info("Finder Sync started; monitoring \(self.monitoredDirectories.count, privacy: .public) directories; home is sandbox container: \(userHome == sandboxHome, privacy: .public); saved route snapshot: \(self.preferencesSnapshot() != nil, privacy: .public).")
    }

    override func beginObservingDirectory(at url: URL) {
        let homePath = monitoredHomeDirectory.path
        let isWithinHome = url.standardizedFileURL.path == homePath || url.standardizedFileURL.path.hasPrefix(homePath + "/")
        logger.info("Finder began browsing a monitored directory; inside user home: \(isWithinHome, privacy: .public).")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else {
            logger.debug("Ignoring Finder menu kind \(String(describing: menuKind), privacy: .public).")
            return nil
        }
        guard claimMenuOwnership() else { return nil }
        pendingRequestsByTag.removeAll(keepingCapacity: true)
        let selection = currentSelection()
        guard !selection.isEmpty,
              selection.count <= 100,
              selection.allSatisfy({ $0.path.utf8.count <= 4_096 }) else {
            logger.error("Ignoring an empty or oversized Finder selection.")
            return nil
        }
        let registry = currentRegistry()
        let hiddenOutputs = preferencesSnapshot()?.hiddenOutputExtensions ?? []
        let formats = uniqueOutputs(for: selection, registry: registry, hiddenOutputs: hiddenOutputs)
        logger.info("Finder selection has \(selection.count, privacy: .public) items and \(formats.count, privacy: .public) available output formats.")
        guard !formats.isEmpty else { return nil }

        let formatMenu = NSMenu(title: "Conversion formats")
        formatMenu.autoenablesItems = false
        for format in formats {
            let title = "\(sourceDescription(for: selection, registry: registry)) → \(format.displayName) (.\(format.fileExtension))"
            let item = NSMenuItem(title: title, action: #selector(convertSelection(_:)), keyEquivalent: "")
            item.target = self
            let request = FinderConversionRequest(
                requestID: UUID().uuidString,
                paths: selection.map(\.path),
                outputExtension: format.fileExtension
            )
            let requestTag = nextRequestTag
            nextRequestTag &+= 1
            pendingRequestsByTag[requestTag] = request
            item.tag = requestTag
            item.isEnabled = true
            formatMenu.addItem(item)
        }

        let morphItem = NSMenuItem(title: "Convert with Morph", action: nil, keyEquivalent: "")
        morphItem.submenu = formatMenu
        morphItem.isEnabled = true

        let convertToMenu = NSMenu(title: "Convert To")
        convertToMenu.autoenablesItems = false
        convertToMenu.addItem(morphItem)

        let convertToItem = NSMenuItem(title: "Convert To", action: nil, keyEquivalent: "")
        convertToItem.submenu = convertToMenu
        convertToItem.isEnabled = true

        let menu = NSMenu(title: "Morph")
        menu.autoenablesItems = false
        menu.addItem(convertToItem)
        return menu
    }

    private func claimMenuOwnership() -> Bool {
        if menuOwnerLockDescriptor >= 0 { return true }

        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Morph/FinderSync", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        } catch {
            logger.error("Couldn't create the Finder menu coordination directory (\(error.localizedDescription, privacy: .public)).")
            return true
        }

        let lockURL = supportDirectory.appendingPathComponent("menu-owner.lock", isDirectory: false)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            logger.error("Couldn't open the Finder menu coordination lock.")
            return true
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            logger.debug("Skipping a duplicate Finder menu from a secondary extension process.")
            return false
        }

        menuOwnerLockDescriptor = descriptor
        logger.info("This Finder Sync process owns the single Morph contextual menu.")
        return true
    }

    deinit {
        if menuOwnerLockDescriptor >= 0 {
            flock(menuOwnerLockDescriptor, LOCK_UN)
            Darwin.close(menuOwnerLockDescriptor)
        }
    }

    @objc private func convertSelection(_ sender: NSMenuItem) {
        let savedRequest = pendingRequestsByTag.removeValue(forKey: sender.tag)
        let request = savedRequest ?? requestFromMenuItemTitle(sender.title)
        guard let request, !request.paths.isEmpty else {
            logger.error("Finder conversion action had no saved selection (tag \(sender.tag, privacy: .public), selected items \(self.currentSelection().count, privacy: .public)).")
            return
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(request)
        } catch {
            logger.error("Finder conversion request could not be encoded.")
            return
        }
        guard data.count <= 512_000 else {
            logger.error("Finder conversion request exceeds the helper's size limit.")
            return
        }
        logger.info("Launching Finder conversion for \(request.paths.count, privacy: .public) files to .\(request.outputExtension, privacy: .public).")

        var components = URLComponents()
        components.scheme = "morphquick"
        components.host = "convert"
        components.queryItems = [URLQueryItem(name: "request", value: data.base64EncodedString())]
        guard let requestURL = components.url else { return }

        let containingApp = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helper = containingApp.appendingPathComponent("Contents/Helpers/MorphQuickConvert.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: helper.path) else { return }

        let mainApp = containingApp
        let backgroundConfiguration = NSWorkspace.OpenConfiguration()
        backgroundConfiguration.activates = false
        backgroundConfiguration.addsToRecentItems = false
        backgroundConfiguration.arguments = ["--morph-background"]

        NSWorkspace.shared.openApplication(at: mainApp, configuration: backgroundConfiguration) { _, backgroundError in
            if let backgroundError {
                self.logger.error("Morph couldn't start its hidden background host (\(backgroundError._domain, privacy: .public), code \(backgroundError._code, privacy: .public)).")
            }

            let helperIsRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == "com.lakshaychawla.Morph.QuickConvert" && !$0.isTerminated
            }
            if helperIsRunning {
                self.send(requestURL, to: helper)
                return
            }

            // Start the helper without untrusted request data in its arguments,
            // then send the request URL. Retry while the new process registers
            // its Apple Event handler; the request ID makes deliveries idempotent.
            let helperConfiguration = NSWorkspace.OpenConfiguration()
            helperConfiguration.activates = false
            helperConfiguration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: helper, configuration: helperConfiguration) { _, launchError in
                if let launchError {
                    self.logger.error("Morph couldn't start its Finder helper (\(launchError._domain, privacy: .public), code \(launchError._code, privacy: .public)).")
                    return
                }
                self.send(requestURL, to: helper)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.send(requestURL, to: helper)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.send(requestURL, to: helper)
                }
            }
        }
    }

    private func send(_ requestURL: URL, to helper: URL) {
        let requestConfiguration = NSWorkspace.OpenConfiguration()
        requestConfiguration.activates = false
        requestConfiguration.addsToRecentItems = false
        NSWorkspace.shared.open([requestURL], withApplicationAt: helper, configuration: requestConfiguration) { _, requestError in
            if let requestError {
                self.logger.error("Morph couldn't send the conversion request (\(requestError._domain, privacy: .public), code \(requestError._code, privacy: .public)).")
            } else {
                self.logger.info("Finder conversion helper received the selection paths and output format.")
            }
        }
    }

    private func requestFromMenuItemTitle(_ title: String) -> FinderConversionRequest? {
        guard let suffixStart = title.range(of: " (.", options: .backwards),
              title.hasSuffix(")") else { return nil }
        let extensionStart = suffixStart.upperBound
        let extensionEnd = title.index(before: title.endIndex)
        let outputExtension = String(title[extensionStart..<extensionEnd]).lowercased()
        guard outputExtension.range(of: #"^[a-z0-9.]{1,16}$"#, options: .regularExpression) != nil else { return nil }
        let selection = currentSelection()
        guard !selection.isEmpty else { return nil }
        return FinderConversionRequest(
            requestID: UUID().uuidString,
            paths: selection.map(\.path),
            outputExtension: outputExtension
        )
    }

    private var monitoredDirectories: Set<URL> {
        let paths = [
            monitoredHomeDirectory.path,
            "/Volumes",
            "/Network",
            "/Users/Shared",
        ]
        return Set(paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL })
    }

    private var monitoredHomeDirectory: URL {
        let extensionContainer = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        let accountPath = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
        let candidate = preferencesSnapshot()?.homeDirectoryPath ?? accountPath ?? extensionContainer.path
        let home = URL(fileURLWithPath: candidate, isDirectory: true).standardizedFileURL
        guard home != extensionContainer,
              FileManager.default.fileExists(atPath: home.path) else { return extensionContainer }
        return home
    }

    private func preferencesSnapshot() -> FinderSyncPreferencesSnapshot? {
        EngineRegistry.loadFinderSyncPreferencesSnapshot()
    }

    private func currentSelection() -> [URL] {
        if let selection = controller.selectedItemURLs(), !selection.isEmpty {
            return selection
        }
        return controller.targetedURL().map { [$0] } ?? []
    }

    private func currentRegistry() -> EngineRegistry {
        preferencesSnapshot()?.registry ?? fallbackRegistry
    }

    private func uniqueOutputs(for files: [URL], registry: EngineRegistry, hiddenOutputs: Set<String>) -> [MorphFormat] {
        let formats = QuickConversionCatalog.availableOutputs(
            for: files,
            registry: registry,
            hiddenOutputExtensions: hiddenOutputs
        )
        var byName: [String: MorphFormat] = [:]
        for format in formats {
            let key = "\(format.category.rawValue)|\(format.displayName)"
            if let existing = byName[key] {
                if preferredExtensionRank(format.fileExtension) < preferredExtensionRank(existing.fileExtension) {
                    byName[key] = format
                }
            } else {
                byName[key] = format
            }
        }
        return byName.values.sorted {
            if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.fileExtension < $1.fileExtension
        }
    }

    private func preferredExtensionRank(_ fileExtension: String) -> Int {
        ["jpg", "tiff", "heic", "yaml", "tar.gz"].firstIndex(of: fileExtension) ?? 10
    }

    private func sourceDescription(for files: [URL], registry: EngineRegistry) -> String {
        let knownExtensions = Set(registry.routes.map(\.inputExtension))
        let sources = Set(files.compactMap { inputExtension(for: $0, knownExtensions: knownExtensions) })
            .sorted()
            .map { $0.uppercased() }
        guard !sources.isEmpty else { return "Selected files" }
        return sources.joined(separator: " + ")
    }

    private func inputExtension(for url: URL, knownExtensions: Set<String>) -> String? {
        let filename = url.lastPathComponent.lowercased()
        return knownExtensions
            .sorted { $0.count > $1.count }
            .first { filename.hasSuffix(".\($0)") }
    }
}

private struct FinderConversionRequest: Codable {
    let requestID: String
    let paths: [String]
    let outputExtension: String
}
