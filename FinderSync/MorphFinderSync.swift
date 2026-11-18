import AppKit
import FinderSync
import Foundation
import MorphCore

final class MorphFinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    private let registry = EngineRegistry.discoverFinderSync()

    override init() {
        super.init()
        controller.directoryURLs = monitoredDirectories
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let selection = currentSelection()
        let formats = uniqueOutputs(for: selection)
        guard !selection.isEmpty, !formats.isEmpty else { return nil }

        let formatMenu = NSMenu(title: "Convert with Morph")
        formatMenu.autoenablesItems = false
        for format in formats {
            let title = "\(sourceDescription(for: selection)) → \(format.displayName) (.\(format.fileExtension))"
            let item = NSMenuItem(title: title, action: #selector(convertSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format.fileExtension
            item.isEnabled = true
            formatMenu.addItem(item)
        }

        let morphItem = NSMenuItem(title: "Convert with Morph", action: nil, keyEquivalent: "")
        morphItem.submenu = formatMenu
        morphItem.isEnabled = true

        let menu = NSMenu(title: "Convert To")
        menu.autoenablesItems = false
        let convertToItem = NSMenuItem(title: "Convert To", action: nil, keyEquivalent: "")
        let morphMenu = NSMenu(title: "Convert To")
        morphMenu.autoenablesItems = false
        morphMenu.addItem(morphItem)
        convertToItem.submenu = morphMenu
        convertToItem.isEnabled = true
        menu.addItem(convertToItem)
        return menu
    }

    @objc private func convertSelection(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? String else { return }
        let selection = currentSelection()
        guard !selection.isEmpty else { return }

        let request = FinderConversionRequest(paths: selection.map(\.path), outputExtension: format)
        guard let data = try? JSONEncoder().encode(request) else { return }

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

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open(selection, withApplicationAt: helper, configuration: configuration) { _, error in
            guard error == nil else { return }
            NSWorkspace.shared.open([requestURL], withApplicationAt: helper, configuration: configuration)
        }
    }

    private var monitoredDirectories: Set<URL> {
        let paths = [
            NSHomeDirectory(),
            "/Volumes",
            "/Network",
            "/Users/Shared",
        ]
        return Set(paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL })
    }

    private func currentSelection() -> [URL] {
        if let selection = controller.selectedItemURLs(), !selection.isEmpty {
            return selection
        }
        return controller.targetedURL().map { [$0] } ?? []
    }

    private func uniqueOutputs(for files: [URL]) -> [MorphFormat] {
        let formats = QuickConversionCatalog.availableOutputs(for: files, registry: registry)
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

    private func sourceDescription(for files: [URL]) -> String {
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

private struct FinderConversionRequest: Encodable {
    let paths: [String]
    let outputExtension: String
}
