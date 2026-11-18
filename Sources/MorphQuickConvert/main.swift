import AppKit
import Foundation
import MorphCore
import SwiftUI
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

private final class QuickConvertAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Morph", isDirectory: true)
    private var pendingSelections: [[URL]] = []
    private var currentSelection: [URL] = []
    private var currentRegistry: EngineRegistry?
    private var isPresentingMenu = false
    private var isConverting = false
    private var isOpeningMorph = false
    private var cancellation: CancellationToken?
    private var statusItem: NSStatusItem?
    private var statusMessageItem: NSMenuItem?
    private var formatPopover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let selection = loadSelection(from: url), !selection.isEmpty else { continue }
            pendingSelections.append(selection)
        }
        // Let Finder finish closing the Quick Actions menu before showing our native popup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.presentNextMenuIfReady()
        }
    }

    private func loadSelection(from url: URL) -> [URL]? {
        guard url.scheme == "morphquick", url.host == "convert",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "manifest" })?.value,
              let uuid = UUID(uuidString: token) else { return nil }

        let directory = supportDirectory.appendingPathComponent("QuickActions", isDirectory: true).standardizedFileURL
        let manifestURL = directory.appendingPathComponent("\(uuid.uuidString.lowercased()).plist").standardizedFileURL
        guard manifestURL.deletingLastPathComponent() == directory,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let paths = manifest["paths"] as? [String], !paths.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: manifestURL)
        return paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
    }

    private func presentNextMenuIfReady() {
        guard !isPresentingMenu, !isConverting else { return }
        guard !pendingSelections.isEmpty else {
            NSApp.terminate(nil)
            return
        }

        currentSelection = pendingSelections.removeFirst()
        guard !currentSelection.isEmpty else {
            presentNextMenuIfReady()
            return
        }
        let registry = EngineRegistry.discover()
        currentRegistry = registry
        let formats = QuickConversionCatalog.availableOutputs(for: currentSelection, registry: registry)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Morph"
        item.button?.toolTip = "Choose an output format for the selected files"
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: QuickFormatPopoverContent(
            title: selectionDescription(currentSelection),
            formats: formats,
            onSelectFormat: { [weak self] format in self?.convertSelection(format) },
            onOpenMorph: { [weak self] in self?.openMorphWithSelection() }
        ))
        formatPopover = popover

        isPresentingMenu = true
        NSApp.activate(ignoringOtherApps: true)
        if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else {
            finishPopoverWithoutSelection()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        isPresentingMenu = false
        formatPopover = nil
        guard !isConverting && !isOpeningMorph else { return }
        finishPopoverWithoutSelection()
    }

    private func finishPopoverWithoutSelection() {
        isPresentingMenu = false
        formatPopover = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        currentSelection = []
        currentRegistry = nil
        if pendingSelections.isEmpty {
            NSApp.terminate(nil)
        } else {
            DispatchQueue.main.async { self.presentNextMenuIfReady() }
        }
    }

    private func selectionDescription(_ urls: [URL]) -> String {
        guard let first = urls.first else { return "Convert with Morph" }
        let extensions = Set(urls.map { $0.pathExtension.lowercased() }.filter { !$0.isEmpty })
        let source = extensions.count == 1 ? (first.pathExtension.uppercased()) : "files"
        return urls.count == 1 ? "Convert \(source) to…" : "Convert \(urls.count) \(source) to…"
    }

    private func convertSelection(_ format: MorphFormat) {
        guard let registry = currentRegistry,
              !currentSelection.isEmpty,
              !isConverting else { return }

        let inputs = currentSelection
        let settings = conversionSettings()
        let token = CancellationToken()
        cancellation = token
        isConverting = true
        formatPopover?.performClose(nil)
        formatPopover = nil
        installProgressStatusItem(total: inputs.count)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let service = ConversionService(registry: registry)
            var results: [ConversionResult] = []
            var failures: [(String, String)] = []

            for (index, input) in inputs.enumerated() {
                if token.isCancelled { break }
                DispatchQueue.main.async { self?.updateProgress(index: index + 1, total: inputs.count, fileName: input.lastPathComponent) }
                do {
                    let request = ConversionRequest(
                        inputURL: input,
                        outputFormat: format,
                        outputDirectory: self?.outputDirectory(for: input, settings: settings) ?? input.deletingLastPathComponent(),
                        imageQuality: settings.imageQuality
                    )
                    results.append(try service.convert(request, cancellation: token))
                } catch {
                    if !token.isCancelled { failures.append((input.lastPathComponent, error.localizedDescription)) }
                }
            }

            DispatchQueue.main.async {
                self?.finishConversion(results: results, failures: failures, cancelled: token.isCancelled, total: inputs.count)
            }
        }
    }

    private func conversionSettings() -> QuickConversionSettings {
        let domain = UserDefaults.standard.persistentDomain(forName: "com.lakshaychawla.Morph")
        guard let data = domain?["com.lakshaychawla.Morph.settings"] as? Data,
              let settings = try? JSONDecoder().decode(QuickConversionSettings.self, from: data) else {
            return QuickConversionSettings()
        }
        return settings
    }

    private func outputDirectory(for input: URL, settings: QuickConversionSettings) -> URL {
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
            return input.deletingLastPathComponent()
        }
    }

    private func installProgressStatusItem(total: Int) {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Morph"
        item.button?.toolTip = "Morph is converting the selected files"
        let menu = NSMenu()
        let message = NSMenuItem(title: "Preparing conversion…", action: nil, keyEquivalent: "")
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
        } else {
            summary = "Converted \(results.count); \(failures.count) failed"
        }
        statusMessageItem?.title = summary
        statusItem?.button?.title = "Morph ✓"
        deliverCompletionNotification(summary: summary)

        currentSelection = []
        currentRegistry = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if let statusItem = self.statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            self.statusItem = nil
            self.statusMessageItem = nil
            if self.pendingSelections.isEmpty {
                NSApp.terminate(nil)
            } else {
                self.presentNextMenuIfReady()
            }
        }
    }

    private func saveHistory(_ results: [ConversionResult]) {
        guard !results.isEmpty else { return }
        let directory = supportDirectory
        let historyURL = directory.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    private func openMorphWithSelection() {
        guard !currentSelection.isEmpty else { return }
        isOpeningMorph = true
        formatPopover?.performClose(nil)
        formatPopover = nil
        let directory = supportDirectory.appendingPathComponent("QuickActions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = UUID().uuidString.lowercased()
        let manifestURL = directory.appendingPathComponent("\(token).plist")
        let manifest: [String: Any] = ["paths": currentSelection.map(\.path)]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0) else { return }
        do { try data.write(to: manifestURL, options: .atomic) } catch { return }
        var components = URLComponents()
        components.scheme = "morph"
        components.host = "convert"
        components.queryItems = [URLQueryItem(name: "manifest", value: token)]
        if let url = components.url { NSWorkspace.shared.open(url) }
        NSApp.terminate(nil)
    }
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

private struct QuickFormatPopoverContent: View {
    let title: String
    let formats: [MorphFormat]
    let onSelectFormat: (MorphFormat) -> Void
    let onOpenMorph: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .lineLimit(2)

            if formats.isEmpty {
                Text("No installed conversion engine supports this selection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(formats, id: \.fileExtension) { format in
                            Button {
                                onSelectFormat(format)
                            } label: {
                                HStack {
                                    Text(format.displayName)
                                    Spacer(minLength: 12)
                                    Text(".\(format.fileExtension)")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 9)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("morph.quickconvert.\(format.fileExtension)")
                        }
                    }
                }
                .frame(maxHeight: 420)
            }

            Divider()

            Button("Open Morph with These Files…", action: onOpenMorph)
                .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }
}
